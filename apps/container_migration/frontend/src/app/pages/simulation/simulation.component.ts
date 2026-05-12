import { Component, OnDestroy, OnInit } from '@angular/core';
import { K8sService } from '../../service/k8s.service';
import { MessageService, SelectItem } from 'primeng/api';
import { catchError, finalize, forkJoin, interval, map, of, Subject, switchMap, take, takeUntil, tap } from 'rxjs';
import { PodsResponse } from '../../model/k8s.model';
import { SimulationService } from '../../service/simulation.service';
import { SimulationRule } from '../../model/simulation-rule.model';
import { MigrationRuntimeStatus, MigrationStage, MigrationStatusResponse } from '../../model/migration-status.model';

@Component({
  selector: 'app-simulation',
  templateUrl: './simulation.component.html',
  styleUrl: './simulation.component.scss'
})
export class SimulationComponent implements OnInit, OnDestroy {

  targetPod: SelectItem[] = [];
  attackType: SelectItem[] = [];
  attackScenarioSelection: SelectItem[] = [];
  clusterSelection: SelectItem[] = [];
  targetClusterSelection: SelectItem[] = [];
  simulationRules: SimulationRule[] = [];
  selectedApp = '';
  selectedAttack = '';
  selectedScaleCluster = '';
  loading = false;
  rulesLoading = false;
  scaleLoading = false;
  isRuleDialogVisible = false;
  editingRuleIndex: number | null = null;

  activeMigrationStatus: MigrationRuntimeStatus = 'not_started';
  statusDetail = '';
  statusLogPath = '';
  statusTargetNode = '';
  downtimeMs: number | null = null;
  statusUpdatedAt?: Date;
  liveLogLines: string[] = [];
  statusK8sEvents: string[] = [];
  stageStatuses: MigrationStage[] = [];
  timerUiTick = 0;
  private destroy$ = new Subject<void>();
  private pollingStop$ = new Subject<void>();
  private isPolling = false;
  private stageRunStartedAt: Record<string, number> = {};
  private stageClientDurationMs: Record<string, number> = {};

  newRuleName = '';
  newRulePattern = 'vuln-spring*';
  newRuleEnabled = true;
  newRuleSourceCluster = '';
  newRuleTargetCluster = '';
  newRuleNamespace = 'default';
  newRuleAttackTypes: string[] = [];
  newRuleRegistryAddress = '';
  newRuleForensicAnalysis = false;
  newRuleAISuggestion = false;
  newRuleDisableIstioSidecar = false;
  newRuleSkipCpuCompatCheck = true;
  newRuleCleanupIncompatibleMounts = false;

  constructor(
    private k8sService: K8sService,
    private simulationService: SimulationService,
    private messageService: MessageService
  ) {}

  ngOnInit(): void {
    this.attackType = [
      { label: 'Reverse shell', value: 'reverse_shell' },
      { label: 'Data destruction', value: 'data_destruction' },
      { label: 'Log file removal', value: 'log_removal' }
    ];
    this.attackScenarioSelection = [...this.attackType];
    this.stageStatuses = this.defaultStages();
    this.getPodsCluster1();
    this.loadClusters();
    this.loadSimulationRules();
    this.loadLatestMigrationFromHistory();

    interval(1000)
      .pipe(takeUntil(this.destroy$))
      .subscribe(() => {
        if (this.activeMigrationStatus === 'running' || this.activeMigrationStatus === 'started') {
          this.timerUiTick++;
        }
      });
  }

  ngOnDestroy(): void {
    this.pollingStop$.next();
    this.pollingStop$.complete();
    this.destroy$.next();
    this.destroy$.complete();
  }

  private getPodsCluster1() {
    const namespaces = ['default', 'istio-enabled'];
    forkJoin(
      namespaces.map((namespace) =>
        this.k8sService.getPods('cluster1', namespace).pipe(
          map((podResponse: PodsResponse) => podResponse.pods),
          catchError(() => of([]))
        )
      )
    ).pipe(
      map((podLists) => podLists.flat()),
      map((pods) => {
        const appNames = pods
          .filter((pod) => pod.status === 'Running' && !!pod.appName)
          .map((pod) => pod.appName as string);

        return [...new Set(appNames)]
          .sort((a, b) => a.localeCompare(b))
          .map((appName) => ({ label: appName, value: appName } as SelectItem));
      }),
      catchError(() => of([] as SelectItem[]))
    ).subscribe((pods: SelectItem[]) => {
      this.targetPod = pods;
    });
  }

  public reset(): void {
    this.selectedApp = '';
    this.selectedAttack = '';
  }

  public simulateAttack(): void {
    if (!this.selectedApp.startsWith('vuln-spring')) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Unsupported app',
        detail: `Attack simulation currently supports only vuln-spring apps. Use Migration tab for ${this.selectedApp}.`
      });
      return;
    }

    this.loading = true;
    this.simulationService.triggerSimulation(this.selectedApp, this.selectedAttack).pipe(
      take(1),
      tap((response) => {
        this.loading = false;
        const migrationTriggered = !!response?.autoMigration && (response.autoMigration as Record<string, unknown>)['migration'];
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'Success',
          detail: migrationTriggered
            ? `${this.selectedAttack} triggered and migration started for ${this.selectedApp}`
            : `${this.selectedAttack} triggered successfully on ${this.selectedApp}`
        });
        if (migrationTriggered) {
          const autoMigration = (response.autoMigration || {}) as Record<string, unknown>;
          const podName = String(autoMigration['pod_name'] || '');
          if (podName) {
            this.activeMigrationStatus = 'started';
            this.statusDetail = 'Migration started. Monitoring progress...';
            this.statusUpdatedAt = new Date();
            const initialStages = this.defaultStages('pipeline_check', 'running');
            this.stageStatuses = initialStages;
            this.resetStageTimingState();
            this.updateStageRunTiming([], initialStages);
            this.startPollingStatus(podName);
          }
        }
        this.reset();
      }),
      catchError((error: any) => {
        this.loading = false;
        const detail = error?.error?.detail || `Failed to trigger attack on ${this.selectedApp}`;
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail });
        return of(error);
      })
    ).subscribe();
  }

  private loadClusters(): void {
    this.k8sService.getClusters().pipe(
      take(1),
      catchError(() => of({ clusters: [] as string[] }))
    ).subscribe((response) => {
      this.clusterSelection = (response.clusters || []).map((cluster) => ({
        label: cluster,
        value: cluster
      } as SelectItem));
      if (!this.selectedScaleCluster && this.clusterSelection.length > 0) {
        this.selectedScaleCluster = String(this.clusterSelection[0].value);
      }
      this.updateTargetClusterSelection();
    });
  }

  private updateTargetClusterSelection(): void {
    this.targetClusterSelection = this.clusterSelection.filter(
      (cluster) => cluster.value !== this.newRuleSourceCluster
    );
    if (this.newRuleTargetCluster === this.newRuleSourceCluster) {
      this.newRuleTargetCluster = '';
    }
  }

  public onNewRuleSourceClusterChange(): void {
    this.updateTargetClusterSelection();
  }

  public loadSimulationRules(): void {
    this.rulesLoading = true;
    this.simulationService.getSimulationRules().pipe(
      take(1),
      catchError(() => of([] as SimulationRule[])),
      tap(() => {
        this.rulesLoading = false;
      })
    ).subscribe((rules) => {
      this.simulationRules = rules;
    });
  }

  public get ruleDialogHeader(): string {
    return this.editingRuleIndex !== null ? 'Edit simulation rule' : 'New simulation rule';
  }

  public get saveRuleButtonLabel(): string {
    return this.editingRuleIndex !== null ? 'Update' : 'Save';
  }

  public showRuleDialog(): void {
    this.editingRuleIndex = null;
    this.resetNewRuleForm();
    this.isRuleDialogVisible = true;
  }

  public editRuleAt(index: number): void {
    const rule = this.simulationRules[index];
    if (!rule) {
      return;
    }
    this.editingRuleIndex = index;
    this.newRuleName = rule.name || '';
    this.newRulePattern = (rule.appNamePattern || '*').trim() || '*';
    this.newRuleEnabled = rule.enabled !== false;
    this.newRuleSourceCluster = rule.sourceCluster || '';
    this.newRuleTargetCluster = rule.targetCluster || '';
    this.newRuleNamespace = (rule.namespace || 'default').trim() || 'default';
    this.newRuleAttackTypes = [...(rule.attackTypes || [])];
    this.newRuleRegistryAddress = (rule.registryAddress ?? '') as string;
    this.newRuleForensicAnalysis = !!rule.forensicAnalysis;
    this.newRuleAISuggestion = !!rule.AISuggestion;
    this.newRuleDisableIstioSidecar = !!rule.disableIstioSidecar;
    this.newRuleSkipCpuCompatCheck = rule.skipCpuCompatCheck !== false;
    this.newRuleCleanupIncompatibleMounts = !!rule.cleanupIncompatibleMounts;
    this.updateTargetClusterSelection();
    this.isRuleDialogVisible = true;
  }

  public cancelRuleDialog(): void {
    this.isRuleDialogVisible = false;
    this.editingRuleIndex = null;
    this.resetNewRuleForm();
  }

  public saveNewRule(): void {
    if (!this.newRuleName || !this.newRuleSourceCluster || !this.newRuleTargetCluster) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Missing fields',
        detail: 'Please provide rule name, source cluster and target cluster.'
      });
      return;
    }
    const normalizedPattern = (this.newRulePattern || '*').trim() || '*';
    const normalizedNamespace = (this.newRuleNamespace || 'default').trim() || 'default';
    const selectedAttacks = this.newRuleAttackTypes.map((x) => x.trim()).filter((x) => !!x);
    const duplicate = this.simulationRules.some((existing, idx) => {
      if (this.editingRuleIndex !== null && idx === this.editingRuleIndex) {
        return false;
      }
      const sameScope =
        (existing.appNamePattern || '*').trim() === normalizedPattern &&
        existing.sourceCluster === this.newRuleSourceCluster &&
        existing.targetCluster === this.newRuleTargetCluster &&
        (existing.namespace || 'default').trim() === normalizedNamespace;
      if (!sameScope) {
        return false;
      }
      const existingAttacks = (existing.attackTypes || []).map((x) => x.trim()).filter((x) => !!x);
      if (existingAttacks.length === 0 || selectedAttacks.length === 0) {
        return true;
      }
      return selectedAttacks.some((attack) => existingAttacks.includes(attack));
    });
    if (duplicate) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Duplicate target',
        detail: 'A rule with the same target scope and overlapping attack scenarios already exists.'
      });
      return;
    }

    const rule: SimulationRule = {
      name: this.newRuleName.trim(),
      enabled: this.newRuleEnabled,
      appNamePattern: normalizedPattern,
      attackTypes: selectedAttacks,
      sourceCluster: this.newRuleSourceCluster,
      targetCluster: this.newRuleTargetCluster,
      namespace: normalizedNamespace,
      registryAddress: (this.newRuleRegistryAddress || '').trim() || null,
      forensicAnalysis: this.newRuleForensicAnalysis,
      AISuggestion: this.newRuleAISuggestion,
      disableIstioSidecar: this.newRuleDisableIstioSidecar,
      skipCpuCompatCheck: this.newRuleSkipCpuCompatCheck,
      cleanupIncompatibleMounts: this.newRuleCleanupIncompatibleMounts
    };

    const save$ =
      this.editingRuleIndex !== null
        ? this.simulationService.updateSimulationRule(this.editingRuleIndex, rule)
        : this.simulationService.addSimulationRule(rule);

    save$.pipe(take(1)).subscribe({
      next: () => {
        const isEdit = this.editingRuleIndex !== null;
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: isEdit ? 'Rule updated' : 'Rule added',
          detail: isEdit ? 'Simulation rule updated.' : 'Simulation rule saved.'
        });
        this.isRuleDialogVisible = false;
        this.editingRuleIndex = null;
        this.resetNewRuleForm();
        this.loadSimulationRules();
      },
      error: (error) => {
        const detail =
          error?.error?.detail ||
          (this.editingRuleIndex !== null ? 'Failed to update simulation rule' : 'Failed to add simulation rule');
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail });
      }
    });
  }

  public deleteSimulationRule(index: number): void {
    this.simulationService.deleteSimulationRule(index).pipe(take(1)).subscribe({
      next: () => {
        this.messageService.add({ key: 'tst', severity: 'success', summary: 'Rule deleted', detail: 'Simulation rule removed.' });
        this.loadSimulationRules();
      },
      error: (error) => {
        const detail = error?.error?.detail || 'Failed to delete simulation rule';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail });
      }
    });
  }

  public scaleVulnSpring(replicas: number): void {
    if (!this.selectedScaleCluster) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Scale', detail: 'Please select a cluster first.' });
      return;
    }
    this.scaleLoading = true;
    this.k8sService.scaleVulnSpring(this.selectedScaleCluster, replicas).pipe(
      take(1),
      finalize(() => {
        this.scaleLoading = false;
      })
    ).subscribe({
      next: (response) => {
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'Scale',
          detail: response.message || `Scaled vuln-spring to replicas=${replicas}`
        });
      },
      error: (error) => {
        const detail = error?.error?.detail || 'Failed to scale vuln-spring';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Scale', detail });
      }
    });
  }

  private loadLatestMigrationFromHistory(): void {
    this.k8sService.getMigrationHistory(1, 0).pipe(
      take(1),
      catchError(() => of({ items: [] as any[] }))
    ).subscribe((response) => {
      const latest = response.items?.[0];
      if (!latest) {
        return;
      }
      const mappedStatus = this.mapStatus(latest.status);
      this.activeMigrationStatus = mappedStatus;
      this.statusDetail = latest.summary || '';
      this.statusLogPath = latest.log_path || '';
      this.statusUpdatedAt = latest.created_at ? new Date(latest.created_at) : undefined;
      this.liveLogLines = latest.log_lines || [];
      this.stageStatuses = latest.stage_statuses || this.defaultStages();
      this.downtimeMs = latest.downtime_ms ?? null;
      this.updateStageRunTiming([], this.stageStatuses);
      if (mappedStatus === 'running') {
        this.startPollingStatus(latest.pod_name);
      }
    });
  }

  private startPollingStatus(podName: string): void {
    if (this.isPolling || !podName) {
      return;
    }
    this.isPolling = true;
    this.pollingStop$.next();
    this.pollingStop$ = new Subject<void>();

    interval(2500).pipe(
      switchMap(() =>
        this.k8sService.getMigrationStatus(podName).pipe(
          catchError((error) => of({
            status: 'error',
            error: error?.message || 'Failed to fetch migration status'
          } as MigrationStatusResponse))
        )
      ),
      takeUntil(this.pollingStop$),
      takeUntil(this.destroy$),
      tap((statusResponse) => this.applyStatus(statusResponse))
    ).subscribe();
  }

  private applyStatus(statusResponse: MigrationStatusResponse): void {
    const mappedStatus = this.mapStatus(statusResponse.status);
    const prevStages = this.stageStatuses;
    this.activeMigrationStatus = mappedStatus;
    this.statusUpdatedAt = new Date();
    this.statusLogPath = statusResponse.log_path || this.statusLogPath;
    this.statusTargetNode = statusResponse.target_node || this.statusTargetNode;
    this.statusDetail = this.buildStatusMessage(statusResponse);
    this.liveLogLines = statusResponse.log_lines || statusResponse.recent_log_lines || this.liveLogLines;
    this.statusK8sEvents = statusResponse.recent_k8s_events || this.statusK8sEvents;
    this.stageStatuses = statusResponse.stage_statuses || this.stageStatuses;
    if (statusResponse.downtime_ms != null) {
      this.downtimeMs = statusResponse.downtime_ms;
    }
    this.updateStageRunTiming(prevStages, this.stageStatuses);

    if (mappedStatus === 'completed' || mappedStatus === 'error') {
      this.isPolling = false;
      this.pollingStop$.next();
    } else {
      this.activeMigrationStatus = 'running';
    }
  }

  public getStatusLabel(): string {
    if (this.activeMigrationStatus === 'not_started') {
      return 'No active migration';
    }
    return this.activeMigrationStatus;
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
    if (statusResponse.status === 'error') {
      return statusResponse.error || statusResponse.message || 'Migration failed';
    }
    if (statusResponse.status === 'completed') {
      return 'Migration completed successfully';
    }
    return statusResponse.message || 'Migration in progress';
  }

  public formatDuration(ms: number | null | undefined): string {
    if (ms == null || ms < 0 || !Number.isFinite(ms)) {
      return '—';
    }
    if (ms < 1000) {
      return `${Math.round(ms)} ms`;
    }
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    if (m > 0) {
      return `${m}m ${s}s`;
    }
    return `${s}s`;
  }

  public formatStageTiming(stage: MigrationStage, _tick: number): string {
    void _tick;
    if (stage.duration_ms != null && stage.duration_ms >= 0) {
      return this.formatDuration(stage.duration_ms);
    }
    const clientDone = this.stageClientDurationMs[stage.key];
    if (clientDone != null) {
      return this.formatDuration(clientDone);
    }
    const started = this.stageRunStartedAt[stage.key];
    if (stage.status === 'running' && started != null) {
      return this.formatDuration(Date.now() - started);
    }
    return '—';
  }

  private resetStageTimingState(): void {
    this.stageRunStartedAt = {};
    this.stageClientDurationMs = {};
    this.timerUiTick = 0;
  }

  private updateStageRunTiming(prev: MigrationStage[], next: MigrationStage[]): void {
    for (const stage of next) {
      if (stage.duration_ms != null && stage.duration_ms >= 0) {
        delete this.stageClientDurationMs[stage.key];
        delete this.stageRunStartedAt[stage.key];
      }
    }
    for (const stage of next) {
      const previous = prev.find((x) => x.key === stage.key);
      if (stage.status === 'running' && previous?.status !== 'running') {
        this.stageRunStartedAt[stage.key] = Date.now();
      }
      if ((stage.status === 'completed' || stage.status === 'failed') && previous?.status === 'running') {
        const started = this.stageRunStartedAt[stage.key];
        if (started != null && (stage.duration_ms == null || stage.duration_ms < 0)) {
          this.stageClientDurationMs[stage.key] = Date.now() - started;
        }
        delete this.stageRunStartedAt[stage.key];
      }
    }
  }

  private defaultStages(runningKey?: string, runningState: 'running' | 'pending' = 'pending'): MigrationStage[] {
    return [
      { key: 'pipeline_check', label: 'Pipeline checks', status: runningKey === 'pipeline_check' ? runningState : 'pending' },
      { key: 'dest_prep', label: 'Destination prep (pre-checkpoint)', status: runningKey === 'dest_prep' ? runningState : 'pending' },
      { key: 'checkpoint', label: 'Checkpoint creation', status: runningKey === 'checkpoint' ? runningState : 'pending' },
      { key: 'source_stop_post_checkpoint', label: 'Source scaled down (post-checkpoint)', status: runningKey === 'source_stop_post_checkpoint' ? runningState : 'pending' },
      { key: 'image', label: 'Image conversion and push', status: runningKey === 'image' ? runningState : 'pending' },
      { key: 'checkpoint_prepull', label: 'Checkpoint image pre-pull (optional)', status: runningKey === 'checkpoint_prepull' ? runningState : 'pending' },
      { key: 'restore', label: 'Restore pod startup', status: runningKey === 'restore' ? runningState : 'pending' },
      { key: 'traffic', label: 'Traffic switch', status: runningKey === 'traffic' ? runningState : 'pending' },
      { key: 'cleanup', label: 'Migration finalize', status: runningKey === 'cleanup' ? runningState : 'pending' }
    ];
  }

  private resetNewRuleForm(): void {
    this.editingRuleIndex = null;
    this.newRuleName = '';
    this.newRulePattern = 'vuln-spring*';
    this.newRuleEnabled = true;
    this.newRuleSourceCluster = '';
    this.newRuleTargetCluster = '';
    this.newRuleNamespace = 'default';
    this.newRuleAttackTypes = [];
    this.newRuleRegistryAddress = '';
    this.newRuleForensicAnalysis = false;
    this.newRuleAISuggestion = false;
    this.newRuleDisableIstioSidecar = false;
    this.newRuleSkipCpuCompatCheck = true;
    this.newRuleCleanupIncompatibleMounts = false;
  }
}
