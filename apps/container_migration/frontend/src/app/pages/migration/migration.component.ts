import { Component, effect, OnDestroy, OnInit, signal, WritableSignal } from '@angular/core';
import { MessageService, SelectItem } from 'primeng/api';
import { K8sService } from '../../service/k8s.service';
import { catchError, filter, finalize, interval, map, of, Subject, Subscription, switchMap, take, takeUntil, tap } from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { MigrationRequest } from '../../model/migration-request.model';
import { MigrationHistoryApiItem, MigrationHistoryItem, MigrationRuntimeStatus, MigrationStage, MigrationStatusResponse } from '../../model/migration-status.model';

@Component({
  selector: 'app-migration',
  templateUrl: './migration.component.html',
  styleUrl: './migration.component.scss'
})
export class MigrationComponent implements OnInit, OnDestroy{
  private readonly defaultPublicRegistry = '160.85.255.146:5000';
  private readonly pnetWireguardRegistry = '10.10.10.1:5000';

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
  skipCpuCompatCheck = true;
  cleanupIncompatibleMounts = false;
  /** Track whether the user has manually overridden the auto-default for cleanupIncompatibleMounts. */
  cleanupIncompatibleMountsTouched = false;
  loading = false;
  registryAddress = this.defaultPublicRegistry;
  istioRoutingContext = 'cluster1';
  routingDemoTrafficSubset = '';
  routingDemoTrafficSubsetAvailable = true;
  trafficToggleLoading = false;
  faultClearLoading = false;
  replicaScaleLoading = false;
  /** Kube context for VirtualService <code>routing-demo</code> (separate from migration source — use after migration). */
  trafficSwitchCluster = '';
  probeUrl = 'http://10.0.0.18:32366/whoami';
  probeIntervalMs = 1000;
  probeConnectTimeoutS = 2;
  probeMaxTimeS = 10;
  probeRunning = false;
  probeInFlight = false;
  probeStatusMessage = '';
  probeLastOutput = '';
  probeSamples: Array<{
    seq: number;
    timestamp: Date;
    totalMs: number;
    httpCode: number;
    ok: boolean;
    counter: number | null;
    stderr?: string;
  }> = [];
  /** Oldest probe bars are dropped from the chart once there are more than this many samples (metrics still use the full buffer). */
  readonly probeChartMaxBars = 72;
  probeDowntimeWindows: Array<{
    start: Date;
    end?: Date;
    beforeCounter: number | null;
    afterCounter: number | null;
    stateNotSame: boolean;
  }> = [];
  activeMigrationStatus: MigrationRuntimeStatus = 'not_started';
  statusDetail = '';
  statusLogPath = '';
  statusTargetNode = '';
  statusUpdatedAt?: Date;
  liveLogLines: string[] = [];
  statusK8sEvents: string[] = [];
  stageStatuses: MigrationStage[] = [];
  /** Source stopped → restore pod running (from API when logs are timestamped). */
  downtimeMs: number | null = null;
  /** Bumps once per second while a stage is running so elapsed time refreshes in the template. */
  timerUiTick = 0;
  migrationHistory: MigrationHistoryItem[] = [];
  selectedRecentLogPath: string | null = null;
  historyPageSize = 5;
  historyPage = 0;
  hasMoreHistory = false;
  private destroy$ = new Subject<void>();
  private pollingStop$ = new Subject<void>();
  private isPolling = false;
  /** Wall-clock start when we first see a stage as `running` (fallback when API has no duration_ms yet). */
  private stageRunStartedAt: Record<string, number> = {};
  /** Approximate duration when a stage completes without server-reported duration_ms. */
  private stageClientDurationMs: Record<string, number> = {};
  private probeIntervalSub?: Subscription;
  private probeSeq = 0;

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

    interval(1000)
      .pipe(
        takeUntil(this.destroy$),
        filter(() => this.activeMigrationStatus === 'running' || this.activeMigrationStatus === 'started'),
        filter(() => this.stageStatuses.some((s) => s.status === 'running'))
      )
      .subscribe(() => {
        this.timerUiTick++;
      });
  }

  ngOnDestroy(): void {
    this.stopHttpProbe();
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
      this.registryAddress = this.getRegistryForTarget(this.selectedTarget);
      this.applyTargetClusterDefaults();
      const defaultRoutingContext = this.getDefaultIstioRoutingContext(options);
      if (!this.istioRoutingContext || !options.some((opt) => opt.value === this.istioRoutingContext)) {
        this.istioRoutingContext = defaultRoutingContext;
      }
      this.trafficSwitchCluster = defaultRoutingContext;
      this.getPodsForSource();
      this.loadRoutingDemoTrafficSubset();
    });
  }

  public onSourceClusterChange(): void {
    this.selectedPod = {} as Pod;
    if (this.selectedSource === this.selectedTarget) {
      this.selectedTarget = '';
      this.registryAddress = this.getRegistryForTarget(this.selectedTarget);
    }
    this.getPodsForSource();
    this.loadRoutingDemoTrafficSubset();
  }

  public onTargetClusterChange(): void {
    this.registryAddress = this.getRegistryForTarget(this.selectedTarget);
    this.applyTargetClusterDefaults();
  }

  private getRegistryForTarget(targetCluster: string): string {
    const normalizedTarget = (targetCluster || '').trim().toLowerCase();
    if (normalizedTarget === 'pnet' || normalizedTarget === 'cluster-pnet') {
      return this.pnetWireguardRegistry;
    }
    return this.defaultPublicRegistry;
  }

  private getDefaultIstioRoutingContext(options: SelectItem[] = this.sourceCluster): string {
    const cluster1 = options.find((opt) => String(opt.value) === 'cluster1');
    if (cluster1) {
      return String(cluster1.value);
    }
    return options.length > 0 ? String(options[0].value) : 'cluster1';
  }

  /** PNET / SEV-SNP destinations lack the powercap mount paths CRIU restores need; default cleanup ON for them. */
  public isHeterogeneousTarget(targetCluster: string): boolean {
    const normalized = (targetCluster || '').trim().toLowerCase();
    return (
      normalized === 'pnet' ||
      normalized === 'cluster-pnet' ||
      normalized === 'sev-snp' ||
      normalized === 'cluster-sev-snp'
    );
  }

  private applyTargetClusterDefaults(): void {
    if (!this.cleanupIncompatibleMountsTouched) {
      this.cleanupIncompatibleMounts = this.isHeterogeneousTarget(this.selectedTarget);
    }
  }

  public onCleanupIncompatibleMountsChange(): void {
    this.cleanupIncompatibleMountsTouched = true;
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
      this.routingDemoTrafficSubsetAvailable = false;
      return;
    }
    this.k8sService.getRoutingDemoTrafficSubset(cluster).pipe(
      take(1),
      catchError(() => of({ subset: '' }))
    ).subscribe((r) => {
      const subset = (r.subset || '').trim();
      if (subset === 'v1' || subset === 'v2') {
        this.routingDemoTrafficSubset = subset;
        this.routingDemoTrafficSubsetAvailable = true;
      } else {
        this.routingDemoTrafficSubset = 'not available';
        this.routingDemoTrafficSubsetAvailable = false;
      }
    });
  }

  public canToggleRoutingDemoTraffic(): boolean {
    return this.routingDemoTrafficSubsetAvailable && (this.routingDemoTrafficSubset === 'v1' || this.routingDemoTrafficSubset === 'v2');
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

  public clearRoutingDemoFault(): void {
    const cluster = this.trafficSwitchCluster;
    if (!cluster) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Traffic', detail: 'No cluster available.' });
      return;
    }
    this.faultClearLoading = true;
    this.k8sService.clearRoutingDemoFault(cluster).pipe(
      take(1),
      finalize(() => {
        this.faultClearLoading = false;
      })
    ).subscribe({
      next: (r) => {
        this.messageService.add({
          key: 'tst',
          severity: r.removed ? 'success' : 'info',
          summary: 'VirtualService fault',
          detail: r.message || (r.removed ? 'Fault filter removed.' : 'No fault was active.')
        });
      },
      error: (err) => {
        const detail = err?.error?.detail ?? err?.message ?? 'Clear fault failed';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'VirtualService fault', detail: String(detail) });
      }
    });
  }

  public scaleRoutingDemoToOne(): void {
    this.scaleRoutingDemoTo(1);
  }

  public scaleRoutingDemoToZero(): void {
    this.scaleRoutingDemoTo(0);
  }

  private scaleRoutingDemoTo(replicas: number): void {
    const cluster = this.trafficSwitchCluster;
    if (!cluster) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Scale', detail: 'No cluster selected.' });
      return;
    }
    this.replicaScaleLoading = true;
    this.k8sService.scaleRoutingDemo(cluster, replicas).pipe(
      take(1),
      finalize(() => {
        this.replicaScaleLoading = false;
      })
    ).subscribe({
      next: (r) => {
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'Deployment scale',
          detail: r.message || `routing-demo scaled to replicas=${replicas}`
        });
      },
      error: (err) => {
        const detail = err?.error?.detail ?? err?.message ?? 'Scale failed';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Deployment scale', detail: String(detail) });
      }
    });
  }

  public startHttpProbe(): void {
    if (this.probeRunning || !this.probeUrl) {
      return;
    }
    const safeIntervalMs = Math.max(200, Number(this.probeIntervalMs) || 1000);
    this.probeIntervalMs = safeIntervalMs;
    this.probeRunning = true;
    this.probeStatusMessage = 'HTTP probe is running';
    this.probeIntervalSub = interval(safeIntervalMs)
      .pipe(takeUntil(this.destroy$))
      .subscribe(() => this.runSingleHttpProbe());
    this.runSingleHttpProbe();
  }

  public stopHttpProbe(): void {
    this.probeRunning = false;
    this.probeIntervalSub?.unsubscribe();
    this.probeIntervalSub = undefined;
    if (!this.probeInFlight) {
      this.probeStatusMessage = 'HTTP probe stopped';
    }
  }

  public clearHttpProbeHistory(): void {
    this.probeSamples = [];
    this.probeDowntimeWindows = [];
    this.probeLastOutput = '';
    this.probeStatusMessage = '';
    this.probeSeq = 0;
  }

  private runSingleHttpProbe(): void {
    if (this.probeInFlight || !this.probeUrl) {
      return;
    }
    this.probeInFlight = true;
    this.k8sService.runHttpProbe(this.probeUrl, this.probeConnectTimeoutS, this.probeMaxTimeS).pipe(
      take(1),
      finalize(() => {
        this.probeInFlight = false;
      })
    ).subscribe({
      next: (res) => {
        const sample = {
          seq: ++this.probeSeq,
          timestamp: new Date(res.timestamp),
          totalMs: res.total_ms ?? 0,
          httpCode: res.http_code ?? 0,
          ok: !!res.ok,
          counter: this.resolveCounterValue(res.counter, res.stdout_json),
          stderr: res.stderr || ''
        };
        this.probeSamples = [...this.probeSamples.slice(-199), sample];
        this.probeLastOutput = [res.stdout || '(empty body)', res.stderr ? `stderr: ${res.stderr}` : '']
          .filter((x) => !!x)
          .join('\n');
        this.probeStatusMessage = `${res.http_code} in ${Math.round(sample.totalMs)} ms`;
        this.updateProbeDowntime(sample.ok, sample.timestamp, sample.counter);
      },
      error: (err) => {
        const now = new Date();
        const detail = err?.error?.detail ?? err?.message ?? 'Probe failed';
        this.probeSamples = [...this.probeSamples.slice(-199), {
          seq: ++this.probeSeq,
          timestamp: now,
          totalMs: 0,
          httpCode: 0,
          ok: false,
          counter: null,
          stderr: String(detail)
        }];
        this.probeLastOutput = `error: ${detail}`;
        this.probeStatusMessage = `Probe error: ${detail}`;
        this.updateProbeDowntime(false, now, null);
      }
    });
  }

  private updateProbeDowntime(ok: boolean, timestamp: Date, counter: number | null): void {
    const last = this.probeDowntimeWindows[this.probeDowntimeWindows.length - 1];
    if (!ok) {
      if (!last || last.end) {
        this.probeDowntimeWindows = [
          ...this.probeDowntimeWindows,
          {
            start: timestamp,
            beforeCounter: this.getLatestSuccessfulCounter(),
            afterCounter: null,
            stateNotSame: false
          }
        ];
      }
      return;
    }
    if (last && !last.end) {
      last.end = timestamp;
      last.afterCounter = counter;
      if (last.beforeCounter != null && last.afterCounter != null) {
        last.stateNotSame = last.afterCounter !== (last.beforeCounter + 1);
      } else {
        last.stateNotSame = true;
      }
      this.probeDowntimeWindows = [...this.probeDowntimeWindows];
    }
  }

  private getLatestSuccessfulCounter(): number | null {
    for (let i = this.probeSamples.length - 1; i >= 0; i--) {
      const s = this.probeSamples[i];
      if (s.ok && s.counter != null) {
        return s.counter;
      }
    }
    return null;
  }

  public getLatestStateCheck(): {
    beforeCounter: number | null;
    afterCounter: number | null;
    stateNotSame: boolean;
    hasWindow: boolean;
  } {
    if (!this.probeDowntimeWindows.length) {
      return { beforeCounter: null, afterCounter: null, stateNotSame: false, hasWindow: false };
    }
    const w = this.probeDowntimeWindows[this.probeDowntimeWindows.length - 1];
    return {
      beforeCounter: w.beforeCounter,
      afterCounter: w.afterCounter,
      stateNotSame: w.stateNotSame,
      hasWindow: true
    };
  }

  public getProbeMaxMs(): number {
    const max = this.probeSamples.reduce((acc, s) => Math.max(acc, s.totalMs || 0), 0);
    return max > 0 ? max : 1;
  }

  public getProbeSamplesForChart(): typeof this.probeSamples {
    const cap = this.probeChartMaxBars;
    return this.probeSamples.length <= cap ? this.probeSamples : this.probeSamples.slice(-cap);
  }

  public getProbeChartMaxMs(): number {
    const visible = this.getProbeSamplesForChart();
    const max = visible.reduce((acc, s) => Math.max(acc, s.totalMs || 0), 0);
    return max > 0 ? max : 1;
  }

  public getProbeChartMidMs(): number {
    return this.getProbeChartMaxMs() / 2;
  }

  public getProbeBarHeightForChart(totalMs: number): number {
    const max = this.getProbeChartMaxMs();
    return Math.max(4, Math.round((Math.max(totalMs, 0) / max) * 100));
  }

  public getProbeAvgMs(): number {
    if (!this.probeSamples.length) {
      return 0;
    }
    const sum = this.probeSamples.reduce((acc, s) => acc + (s.totalMs || 0), 0);
    return sum / this.probeSamples.length;
  }

  public getProbeLatestSample(): { seq: number; timestamp: Date; totalMs: number; httpCode: number; ok: boolean; counter: number | null; stderr?: string } | null {
    return this.probeSamples.length ? this.probeSamples[this.probeSamples.length - 1] : null;
  }

  public getProbeCurrentCounter(): string {
    const latest = this.getProbeLatestSample();
    if (!latest) {
      return '-';
    }
    return latest.counter == null ? 'n/a' : String(latest.counter);
  }

  private resolveCounterValue(counter: number | null | undefined, stdoutJson: Record<string, unknown> | null | undefined): number | null {
    if (typeof counter === 'number' && Number.isFinite(counter)) {
      return counter;
    }
    const fallback = stdoutJson?.['counter'];
    if (typeof fallback === 'number' && Number.isFinite(fallback)) {
      return fallback;
    }
    return null;
  }

  public formatProbeTimestamp(ts: Date): string {
    return ts.toLocaleTimeString();
  }

  public roundMs(value: number): number {
    return Math.round(value);
  }

  public reset(): void {
    console.log(this.selectedNamespace())
    this.selectedSource = '';
    this.selectedTarget = '';
    this.registryAddress = this.getRegistryForTarget(this.selectedTarget);
    this.selectedNamespace.set('');
    this.selectedPod = {} as Pod;
    this.isGeneratingFA = false;
    this.isGeneratingAISuggestion = false;
    this.disableIstioSidecar = false;
    this.skipCpuCompatCheck = true;
    this.cleanupIncompatibleMountsTouched = false;
    this.cleanupIncompatibleMounts = this.isHeterogeneousTarget(this.selectedTarget);
    this.istioRoutingContext = this.getDefaultIstioRoutingContext();
    this.trafficSwitchCluster = this.getDefaultIstioRoutingContext();
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
      registryAddress: (this.registryAddress || '').trim() || this.defaultPublicRegistry,
      istioRoutingContext: this.istioRoutingContext || this.getDefaultIstioRoutingContext(),
      forensicAnalysis: this.isGeneratingFA,
      AISuggestion: this.isGeneratingAISuggestion,
      disableIstioSidecar: this.disableIstioSidecar,
      skipCpuCompatCheck: this.skipCpuCompatCheck,
      cleanupIncompatibleMounts: this.cleanupIncompatibleMounts
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
        this.resetStageTimingState();
        this.downtimeMs = null;
        const initialStages = this.defaultStages('pipeline_check', 'running');
        this.stageStatuses = initialStages;
        this.updateStageRunTiming([], initialStages);
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
          downtimeMs: null,
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

  /**
   * @param _tick Dependency from template so the view refreshes every second while stages run.
   */
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
    for (const st of next) {
      if (st.duration_ms != null && st.duration_ms >= 0) {
        delete this.stageClientDurationMs[st.key];
        delete this.stageRunStartedAt[st.key];
      }
    }
    for (const st of next) {
      const p = prev.find((x) => x.key === st.key);
      if (st.status === 'running' && p?.status !== 'running') {
        this.stageRunStartedAt[st.key] = Date.now();
      }
      if ((st.status === 'completed' || st.status === 'failed') && p?.status === 'running') {
        const started = this.stageRunStartedAt[st.key];
        if (started != null && (st.duration_ms == null || st.duration_ms < 0)) {
          this.stageClientDurationMs[st.key] = Date.now() - started;
        }
        delete this.stageRunStartedAt[st.key];
      }
    }
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
    const prevStages = this.stageStatuses;
    this.activeMigrationStatus = mappedStatus;
    this.statusUpdatedAt = new Date();
    this.statusLogPath = statusResponse.log_path || this.statusLogPath;
    this.statusTargetNode = statusResponse.target_node || this.statusTargetNode;
    this.statusDetail = this.buildStatusMessage(statusResponse);
    this.liveLogLines = statusResponse.log_lines || statusResponse.recent_log_lines || this.liveLogLines;
    this.statusK8sEvents = statusResponse.recent_k8s_events || this.statusK8sEvents;
    const nextStages = statusResponse.stage_statuses || this.stageStatuses;
    this.stageStatuses = nextStages;
    this.updateStageRunTiming(prevStages, nextStages);
    if (statusResponse.downtime_ms != null) {
      this.downtimeMs = statusResponse.downtime_ms;
    }

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
      if (statusResponse.downtime_ms != null) {
        activeItem.downtimeMs = statusResponse.downtime_ms;
      }
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
      {
        key: 'dest_prep',
        label: 'Destination prep (pre-checkpoint)',
        status: runningKey === 'dest_prep' ? runningState : 'pending'
      },
      { key: 'checkpoint', label: 'Checkpoint creation', status: runningKey === 'checkpoint' ? runningState : 'pending' },
      {
        key: 'source_stop_post_checkpoint',
        label: 'Source scaled down (post-checkpoint)',
        status: runningKey === 'source_stop_post_checkpoint' ? runningState : 'pending'
      },
      {
        key: 'checkpoint_normalization',
        label: 'Checkpoint normalization',
        status: runningKey === 'checkpoint_normalization' ? runningState : 'pending'
      },
      { key: 'image', label: 'Image conversion and push', status: runningKey === 'image' ? runningState : 'pending' },
      {
        key: 'checkpoint_prepull',
        label: 'Checkpoint image pre-pull (optional)',
        status: runningKey === 'checkpoint_prepull' ? runningState : 'pending'
      },
      { key: 'restore', label: 'Restore pod startup', status: runningKey === 'restore' ? runningState : 'pending' },
      { key: 'traffic', label: 'Traffic switch', status: runningKey === 'traffic' ? runningState : 'pending' },
      { key: 'cleanup', label: 'Migration finalize', status: runningKey === 'cleanup' ? runningState : 'pending' }
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
        downtimeMs: item.downtime_ms ?? null,
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
          this.downtimeMs = latest.downtimeMs ?? null;
          this.resetStageTimingState();
          if (latest.status === 'running') {
            this.startPollingStatus(latest.podName);
          }
        }
      }
    });
  }
}
