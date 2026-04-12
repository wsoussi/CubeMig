import { Component, effect, OnDestroy, OnInit, signal, WritableSignal } from '@angular/core';
import { MessageService, SelectItem } from 'primeng/api';
import { K8sService } from '../../service/k8s.service';
import { catchError, finalize, interval, map, of, Subject, switchMap, take, takeUntil, tap } from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { MigrationRequest } from '../../model/migration-request.model';
import { MigrationHistoryApiItem, MigrationHistoryItem, MigrationRuntimeStatus, MigrationStage, MigrationStatusResponse } from '../../model/migration-status.model';

@Component({
  selector: 'app-migration',
  templateUrl: './migration.component.html',
  styleUrl: './migration.component.scss'
})
export class MigrationComponent implements OnInit, OnDestroy{
  
  sourceCluster: SelectItem[] = [];
  targetCluster: SelectItem[] = [];
  podsCluster1: SelectItem[] = [];
  namespaceList: SelectItem[] = [];
  selectedSource: string = '';
  selectedTarget: string = '';
  selectedPod: Pod = {} as Pod;
  selectedNamespace: WritableSignal<string> = signal('');
  isGeneratingFA = false;
  isGeneratingAISuggestion = false;
  disableIstioSidecar = false;
  loading = false;
  routingDemoTrafficSubset = '';
  trafficToggleLoading = false;
  /** Kube context for VirtualService <code>routing-demo</code> (separate from migration source — use after migration). */
  trafficSwitchCluster = '';
  activeMigrationStatus: MigrationRuntimeStatus = 'not_started';
  statusDetail = '';
  statusLogPath = '';
  statusTargetNode = '';
  statusUpdatedAt?: Date;
  liveLogLines: string[] = [];
  statusK8sEvents: string[] = [];
  stageStatuses: MigrationStage[] = [];
  migrationHistory: MigrationHistoryItem[] = [];
  selectedRecentLogPath: string | null = null;
  historyPageSize = 5;
  historyPage = 0;
  hasMoreHistory = false;
  private destroy$ = new Subject<void>();
  private pollingStop$ = new Subject<void>();
  private isPolling = false;

  constructor(private k8sService: K8sService, private messageService: MessageService) {
    effect(() => {
      const ns = this.selectedNamespace(); 
      this.selectedPod = {} as Pod;
      this.getPodsForSource();
    });
  }
  ngOnInit(): void {
    this.loadClusters();
    this.namespaceList = [
      { label: 'default', value: 'default' },
      { label: 'istio-enabled', value: 'istio-enabled' }
    ];
    this.stageStatuses = this.defaultStages();
    this.loadRecentMigrations(0);
  }

  ngOnDestroy(): void {
    this.pollingStop$.next();
    this.pollingStop$.complete();
    this.destroy$.next();
    this.destroy$.complete();
  }

  private loadClusters(): void {
    this.k8sService.getClusters().pipe(
      take(1),
      catchError(() => of({ clusters: [] as string[] }))
    ).subscribe((response) => {
      const options = (response.clusters || []).map((cluster) => ({
        label: cluster,
        value: cluster
      } as SelectItem));
      this.sourceCluster = options;
      this.targetCluster = options;

      if (!this.selectedSource && options.length > 0) {
        this.selectedSource = String(options[0].value);
      }
      if (!this.selectedTarget) {
        const fallbackTarget = options.find((opt) => opt.value !== this.selectedSource);
        this.selectedTarget = fallbackTarget ? String(fallbackTarget.value) : '';
      }
      this.trafficSwitchCluster = this.selectedSource || (options[0] ? String(options[0].value) : '');
      this.getPodsForSource();
      this.loadRoutingDemoTrafficSubset();
    });
  }

  public onSourceClusterChange(): void {
    this.selectedPod = {} as Pod;
    if (this.selectedSource === this.selectedTarget) {
      this.selectedTarget = '';
    }
    this.trafficSwitchCluster = this.selectedSource;
    this.getPodsForSource();
    this.loadRoutingDemoTrafficSubset();
  }

  public onTrafficSwitchClusterChange(): void {
    this.loadRoutingDemoTrafficSubset();
  }

  private getPodsForSource() {
    if (!this.selectedSource || !this.selectedNamespace()) {
      this.podsCluster1 = [];
      return;
    }

    this.k8sService.getPods(this.selectedSource, this.selectedNamespace()).pipe(
      take(1),
      map((podResponse: PodsResponse) => {
        return podResponse.pods
          .filter(pod => pod.status === 'Running')
          .map(pod => ({ label: pod.podName, value: {"podName": pod.podName, "appName": pod.appName} } as SelectItem));
      }),
      catchError(() => {
        return of([] as SelectItem[]);
      })
    ).subscribe((pods: SelectItem[]) => {
      this.podsCluster1 = pods;
    });
  }

  private loadRoutingDemoTrafficSubset(): void {
    const cluster = this.trafficSwitchCluster;
    if (!cluster) {
      this.routingDemoTrafficSubset = '';
      return;
    }
    this.k8sService.getRoutingDemoTrafficSubset(cluster).pipe(
      take(1),
      catchError(() => of({ subset: '' }))
    ).subscribe((r) => {
      this.routingDemoTrafficSubset = r.subset || '';
    });
  }

  public toggleRoutingDemoTraffic(): void {
    const cluster = this.trafficSwitchCluster;
    if (!cluster) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Traffic', detail: 'No cluster available.' });
      return;
    }
    this.trafficToggleLoading = true;
    this.k8sService.toggleRoutingDemoTraffic(cluster).pipe(
      take(1),
      finalize(() => {
        this.trafficToggleLoading = false;
      })
    ).subscribe({
      next: (r) => {
        this.routingDemoTrafficSubset = r.subset;
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'VirtualService',
          detail: r.message || `Primary route is now ${r.subset}`
        });
      },
      error: (err) => {
        const detail = err?.error?.detail ?? err?.message ?? 'Toggle failed';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'VirtualService', detail: String(detail) });
      }
    });
  }

  public reset(): void {
    console.log(this.selectedNamespace())
    this.selectedSource = '';
    this.selectedTarget = '';
    this.selectedNamespace.set('');
    this.selectedPod = {} as Pod;
    this.isGeneratingFA = false;
    this.isGeneratingAISuggestion = false;
    this.disableIstioSidecar = false;
    this.trafficSwitchCluster = this.sourceCluster.length ? String(this.sourceCluster[0].value) : '';
    this.loadRoutingDemoTrafficSubset();
  }

  public areDropdownsFilled(): boolean {
    return this.selectedSource !== '' && this.selectedTarget !== '' && this.selectedNamespace() !== '';
  }

  public migratePod(): void {
    if (!this.selectedPod?.podName) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Warning', detail: 'Please select a pod to migrate' });
      return;
    }
    if (this.selectedSource === this.selectedTarget) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Warning', detail: 'Source and target cluster must be different' });
      return;
    }

    this.loading = true;
    const migrationRequest: MigrationRequest = {
      sourceCluster: this.selectedSource,
      targetCluster: this.selectedTarget,
      namespace: this.selectedNamespace(),
      podName: this.selectedPod.podName!,
      appName: this.selectedPod.appName!,
      forensicAnalysis: this.isGeneratingFA,
      AISuggestion: this.isGeneratingAISuggestion,
      disableIstioSidecar: this.disableIstioSidecar
    };
    this.k8sService.migratePod(migrationRequest).pipe(
      take(1), // Ensures only one emission is taken
      tap((response) => {
        this.loading = false;
        this.activeMigrationStatus = 'started';
        this.statusDetail = response.message || 'Migration started';
        this.statusUpdatedAt = new Date();
        this.liveLogLines = ['Migration task has been started'];
        this.statusK8sEvents = [];
        this.statusTargetNode = '';
        this.stageStatuses = this.defaultStages('pipeline_check', 'running');
        this.startPollingStatus(migrationRequest.podName);
        this.messageService.add({ key: 'tst', severity: 'info', summary: 'Started', detail: 'Migration started. Monitoring progress...' });
        this.pushOrUpdateHistory({
          podName: migrationRequest.podName,
          sourceCluster: migrationRequest.sourceCluster,
          targetCluster: migrationRequest.targetCluster,
          namespace: migrationRequest.namespace,
          targetPodName: 'pending',
          logLines: ['Migration task has been started'],
          stageStatuses: this.defaultStages('pipeline_check', 'running'),
          startedAt: new Date(),
          status: 'started',
          logPath: response.log_path,
          summary: response.message
        });
        this.reset();
      }),
      catchError((error: any) => {
        this.loading = false;
        this.activeMigrationStatus = 'error';
        this.statusDetail = error?.error?.detail || error?.message || 'Failed to start migration';
        this.statusUpdatedAt = new Date();
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail: this.statusDetail });
        return of(error);
      })
    ).subscribe();
  }

  public getStatusLabel(): string {
    if (this.activeMigrationStatus === 'not_started') {
      return 'No active migration';
    }
    return this.activeMigrationStatus;
  }

  private startPollingStatus(podName: string): void {
    if (this.isPolling) {
      return;
    }
    this.isPolling = true;
    this.pollingStop$.next();
    this.pollingStop$ = new Subject<void>();

    interval(2500).pipe(
      switchMap(() => this.k8sService.getMigrationStatus(podName).pipe(
        catchError((error) => of({
          status: 'error',
          error: error?.message || 'Failed to fetch migration status'
        } as MigrationStatusResponse))
      )),
      takeUntil(this.pollingStop$),
      takeUntil(this.destroy$),
      tap((statusResponse) => this.applyStatus(statusResponse))
    ).subscribe();
  }

  private applyStatus(statusResponse: MigrationStatusResponse): void {
    const mappedStatus = this.mapStatus(statusResponse.status);
    this.activeMigrationStatus = mappedStatus;
    this.statusUpdatedAt = new Date();
    this.statusLogPath = statusResponse.log_path || this.statusLogPath;
    this.statusTargetNode = statusResponse.target_node || this.statusTargetNode;
    this.statusDetail = this.buildStatusMessage(statusResponse);
    this.liveLogLines = statusResponse.log_lines || statusResponse.recent_log_lines || this.liveLogLines;
    this.statusK8sEvents = statusResponse.recent_k8s_events || this.statusK8sEvents;
    this.stageStatuses = statusResponse.stage_statuses || this.stageStatuses;

    const activeItem = this.migrationHistory[0];
    if (activeItem) {
      activeItem.status = mappedStatus;
      activeItem.logPath = statusResponse.log_path || activeItem.logPath;
      activeItem.summary = this.statusDetail;
      activeItem.sourceCluster = statusResponse.source_cluster || activeItem.sourceCluster;
      activeItem.targetCluster = statusResponse.target_cluster || activeItem.targetCluster;
      activeItem.namespace = statusResponse.namespace || activeItem.namespace;
      activeItem.targetPodName = statusResponse.target_pod_name || activeItem.targetPodName;
      activeItem.logLines = statusResponse.log_lines || activeItem.logLines;
      activeItem.stageStatuses = statusResponse.stage_statuses || activeItem.stageStatuses;
      if (mappedStatus === 'completed' || mappedStatus === 'error') {
        activeItem.finishedAt = new Date();
      }
    }

    if (mappedStatus === 'completed') {
      this.isPolling = false;
      this.messageService.add({ key: 'tst', severity: 'success', summary: 'Completed', detail: 'Migration completed successfully' });
      this.pollingStop$.next();
    } else if (mappedStatus === 'error') {
      this.isPolling = false;
      this.messageService.add({ key: 'tst', severity: 'error', summary: 'Migration failed', detail: this.statusDetail });
      this.pollingStop$.next();
    } else {
      this.activeMigrationStatus = 'running';
    }
  }

  private mapStatus(status: MigrationStatusResponse['status']): MigrationRuntimeStatus {
    if (status === 'completed') {
      return 'completed';
    }
    if (status === 'error') {
      return 'error';
    }
    if (status === 'not_found') {
      return 'not_found';
    }
    return 'running';
  }

  private buildStatusMessage(statusResponse: MigrationStatusResponse): string {
    const eventText = (statusResponse.recent_k8s_events || []).join('\n');
    if (statusResponse.status === 'error') {
      const source = `${statusResponse.error || statusResponse.message || 'Migration failed'}\n${eventText}`;
      if (source.includes('Failed to redirect mirrored traffic')) {
        return 'Traffic switch failed. Check VirtualService mirror path and destination subset.';
      }
      if (source.includes('ImagePullBackOff') || source.includes('ErrImagePull')) {
        return 'Image pull failed on target cluster. Check registry availability and pull secrets.';
      }
      if (source.includes('http: server gave HTTP response to HTTPS client')) {
        return 'Registry TLS mismatch. Configure destination node runtime for insecure HTTP registry or use TLS registry.';
      }
      if (source.includes('image not known')) {
        return 'Restore failed because required base image is not known on the destination node. Ensure base image pre-pull succeeded.';
      }
      if (source.includes('CreateContainerError') || source.includes('RunContainerError') || source.includes('failed to restore container')) {
        return 'Container restore failed on destination node (CRIU runtime issue). Check node CRI-O logs and restore.log.';
      }
      if (source.includes('Failed to switch context')) {
        return 'Kubernetes context switch failed. Verify kubeconfig and context names.';
      }
      return source.split('\n')[0];
    }
    if (statusResponse.status === 'completed') {
      return 'Migration completed successfully';
    }
    return statusResponse.message || 'Migration in progress';
  }

  private pushOrUpdateHistory(item: MigrationHistoryItem): void {
    this.migrationHistory.unshift(item);
    this.migrationHistory = this.migrationHistory.slice(0, 10);
  }

  private defaultStages(runningKey?: string, runningState: 'running' | 'pending' = 'pending'): MigrationStage[] {
    return [
      { key: 'pipeline_check', label: 'Pipeline checks', status: runningKey === 'pipeline_check' ? runningState : 'pending' },
      { key: 'checkpoint', label: 'Checkpoint creation', status: runningKey === 'checkpoint' ? runningState : 'pending' },
      { key: 'image', label: 'Image conversion and push', status: runningKey === 'image' ? runningState : 'pending' },
      { key: 'prepull', label: 'Base image pre-pull', status: runningKey === 'prepull' ? runningState : 'pending' },
      { key: 'restore', label: 'Restore pod startup', status: runningKey === 'restore' ? runningState : 'pending' },
      { key: 'traffic', label: 'Traffic switch', status: runningKey === 'traffic' ? runningState : 'pending' },
      { key: 'cleanup', label: 'Source cleanup', status: runningKey === 'cleanup' ? runningState : 'pending' }
    ];
  }

  public nextHistoryPage(): void {
    if (!this.hasMoreHistory) {
      return;
    }
    this.loadRecentMigrations(this.historyPage + 1);
  }

  public prevHistoryPage(): void {
    if (this.historyPage === 0) {
      return;
    }
    this.loadRecentMigrations(this.historyPage - 1);
  }

  public toggleRecentLog(logPath?: string): void {
    if (!logPath) {
      return;
    }
    this.selectedRecentLogPath = this.selectedRecentLogPath === logPath ? null : logPath;
  }

  private loadRecentMigrations(page: number = 0): void {
    const offset = page * this.historyPageSize;
    this.k8sService.getMigrationHistory(this.historyPageSize, offset).pipe(
      take(1),
      catchError(() => of({ items: [], limit: this.historyPageSize, offset, total: 0, has_more: false }))
    ).subscribe((response) => {
      this.historyPage = Math.floor((response.offset || 0) / this.historyPageSize);
      this.hasMoreHistory = !!response.has_more;
      this.selectedRecentLogPath = null;
      this.migrationHistory = response.items.map((item: MigrationHistoryApiItem) => ({
        podName: item.pod_name,
        sourceCluster: item.source_cluster || 'unknown',
        targetCluster: item.target_cluster || 'unknown',
        namespace: item.namespace || 'unknown',
        targetPodName: item.target_pod_name || 'unknown',
        logLines: item.log_lines || [],
        stageStatuses: item.stage_statuses || this.defaultStages(),
        startedAt: new Date(item.created_at),
        status: this.mapStatus(item.status),
        logPath: item.log_path,
        summary: item.summary
      }));

      if (this.migrationHistory.length > 0) {
        const latest = this.migrationHistory[0];
        if (this.historyPage === 0) {
          this.activeMigrationStatus = latest.status;
          this.statusDetail = latest.summary || '';
          this.statusLogPath = latest.logPath || '';
          this.statusTargetNode = '';
          this.statusUpdatedAt = latest.startedAt;
          this.liveLogLines = latest.logLines || [];
          this.statusK8sEvents = [];
          this.stageStatuses = latest.stageStatuses || this.defaultStages();
          if (latest.status === 'running') {
            this.startPollingStatus(latest.podName);
          }
        }
      }
    });
  }
}
