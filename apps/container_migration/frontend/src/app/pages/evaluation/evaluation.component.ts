import { Component, OnDestroy, OnInit } from '@angular/core';
import { MessageService, SelectItem } from 'primeng/api';
import {
  catchError,
  finalize,
  interval,
  of,
  Subject,
  switchMap,
  take,
  takeUntil,
  tap
} from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { K8sService } from '../../service/k8s.service';
import { MigrationStage } from '../../model/migration-status.model';
import { createDefaultMigrationStages } from '../../shared/migration-pipeline.util';
import {
  EvaluationArtifact,
  EvaluationFileResponse,
  EvaluationRunDetail,
  EvaluationRunRow,
  EvaluationRunStatus,
  EvaluationService,
  EvaluationStartRequest
} from '../../service/evaluation.service';

@Component({
  selector: 'app-evaluation',
  templateUrl: './evaluation.component.html',
  styleUrl: './evaluation.component.scss'
})
export class EvaluationComponent implements OnInit, OnDestroy {
  private readonly defaultPublicRegistry = '160.85.255.146:5000';
  private readonly pnetWireguardRegistry = '10.10.10.1:5000';

  outRoot = '';
  runs: EvaluationRunRow[] = [];
  loadingRuns = false;
  loadError = '';

  clusterOptions: SelectItem[] = [];
  namespaceOptions: SelectItem[] = [
    { label: 'istio-enabled', value: 'istio-enabled' },
    { label: 'default', value: 'default' }
  ];
  workloadOptions: SelectItem[] = [
    { label: 'routing-demo', value: 'routing-demo' },
    { label: 'mmt-probe', value: 'mmt-probe' },
    { label: 'vuln-spring', value: 'vuln-spring' }
  ];
  triggerOptions: SelectItem[] = [
    { label: 'manual', value: 'manual' },
    { label: 'falco', value: 'falco' },
    { label: 'simulate', value: 'simulate' }
  ];
  podOptions: SelectItem[] = [];

  formSource = '';
  formDest = '';
  formNamespace = 'istio-enabled';
  formWorkload = 'routing-demo';
  formPod = '';
  formLoadRps = 1;
  formConcurrency = 1;
  formTrigger = 'manual';
  formRunId = '';
  formRegistry = this.defaultPublicRegistry;
  formSkipCpuCompatCheck = true;
  formCleanupIncompatibleMounts: boolean | null = null;
  cleanupTouched = false;
  formDisableIstioSidecar = false;

  startingRun = false;
  activeRunDate: string | null = null;
  activeRunId: string | null = null;
  activeRunStatus = '';
  activeRunExitCode: number | null = null;
  activeLogLines: string[] = [];
  activeStageStatuses: MigrationStage[] = createDefaultMigrationStages();
  activeDowntimeMs: number | null = null;
  activeStatusLogPath = '';
  activeStatusTargetNode = '';
  activeStatusK8sEvents: string[] = [];
  activeStatusDetail = '';
  activeStatusUpdatedAt?: Date;

  selectedRun: EvaluationRunRow | null = null;
  selectedStageStatuses: MigrationStage[] = createDefaultMigrationStages();
  selectedDowntimeMs: number | null = null;
  selectedStatusLogPath = '';
  selectedStatusTargetNode = '';
  selectedStatusK8sEvents: string[] = [];
  selectedLogLines: string[] = [];
  selectedStatusDetail = '';
  selectedStatusUpdatedAt?: Date;
  selectedRunStatusLabel = '';
  selectedDetail: EvaluationRunDetail | null = null;
  loadingDetail = false;

  selectedArtifactName: string | null = null;
  selectedArtifactContent: string | null = null;
  selectedArtifactTruncated = false;
  selectedArtifactSize: number | null = null;
  loadingFile = false;

  private artifactPriority: Record<string, number> = {
    'metadata.json': 0,
    'migration.log': 1,
    'failure_diagnostics.txt': 2,
    'host_metrics.csv': 3,
    'k8s_before.txt': 4,
    'k8s_after.txt': 5,
    'istio_before.yaml': 6,
    'istio_after.yaml': 7,
    'wg_before.txt': 8,
    'wg_after.txt': 9,
    'artifact_sizes.txt': 10,
    'checkpoint/checkpoint_path.txt': 11,
    'checkpoint/checkpoint_stat.txt': 12,
    'checkpoint/checkpoint_sha256.txt': 13,
    'checkpoint/checkpoint_tar_listing.txt': 14,
    'checkpoint/checkpointctl_show.txt': 15,
    'checkpoint/checkpointctl_inspect.txt': 16
  };

  private destroy$ = new Subject<void>();
  private pollStop$ = new Subject<void>();

  constructor(
    private evaluationService: EvaluationService,
    private k8sService: K8sService,
    private messageService: MessageService
  ) {}

  ngOnInit(): void {
    this.loadClusters();
    this.refreshRuns();
    this.applyDestDefaults();
  }

  ngOnDestroy(): void {
    this.stopPolling();
    this.destroy$.next();
    this.destroy$.complete();
  }

  private loadClusters(): void {
    this.k8sService.getClusters().pipe(
      take(1),
      catchError(() => of({ clusters: [] as string[] }))
    ).subscribe((response) => {
      this.clusterOptions = (response.clusters || []).map((c) => ({ label: c, value: c } as SelectItem));
      if (!this.formSource && this.clusterOptions.length > 0) {
        this.formSource = String(this.clusterOptions[0].value);
      }
      if (!this.formDest) {
        const other = this.clusterOptions.find((o) => o.value !== this.formSource);
        this.formDest = other ? String(other.value) : '';
      }
      this.applyDestDefaults();
      this.loadPods();
    });
  }

  public onSourceChange(): void {
    if (this.formSource === this.formDest) {
      this.formDest = '';
    }
    this.formPod = '';
    this.loadPods();
  }

  public onDestChange(): void {
    this.applyDestDefaults();
  }

  public onNamespaceChange(): void {
    this.formPod = '';
    this.loadPods();
  }

  public onCleanupChange(): void {
    this.cleanupTouched = true;
  }

  private applyDestDefaults(): void {
    this.formRegistry = this.getRegistryForTarget(this.formDest);
    if (!this.cleanupTouched) {
      this.formCleanupIncompatibleMounts = this.isHeterogeneousTarget(this.formDest);
    }
  }

  private getRegistryForTarget(target: string): string {
    const n = (target || '').trim().toLowerCase();
    if (n === 'pnet' || n === 'cluster-pnet') {
      return this.pnetWireguardRegistry;
    }
    return this.defaultPublicRegistry;
  }

  public isHeterogeneousTarget(target: string): boolean {
    const n = (target || '').trim().toLowerCase();
    return n === 'pnet' || n === 'cluster-pnet' || n === 'sev-snp' || n === 'cluster-sev-snp';
  }

  private loadPods(): void {
    if (!this.formSource || !this.formNamespace) {
      this.podOptions = [];
      return;
    }
    this.k8sService.getPods(this.formSource, this.formNamespace).pipe(
      take(1),
      catchError(() => of({ pods: [] as Pod[] }))
    ).subscribe((response: PodsResponse) => {
      const pods = response.pods || [];
      let filtered = pods.filter((p) => p.status === 'Running');
      if (this.formWorkload === 'vuln-spring') {
        filtered = filtered.filter((p) => (p.appName || '').startsWith('vuln-spring'));
      } else if (this.formWorkload === 'routing-demo') {
        filtered = filtered.filter((p) => (p.appName || '').includes('routing-demo'));
      } else if (this.formWorkload === 'mmt-probe') {
        filtered = filtered.filter((p) => (p.appName || '').includes('mmt-probe'));
      }
      this.podOptions = filtered.map((p) => ({
        label: p.podName,
        value: p.podName
      } as SelectItem));
      if (this.formPod && !this.podOptions.some((o) => o.value === this.formPod)) {
        this.formPod = '';
      }
    });
  }

  public onWorkloadChange(): void {
    this.loadPods();
  }

  public suggestRunId(): void {
    if (!this.formSource || !this.formDest || !this.formWorkload) {
      return;
    }
    const ts = new Date().toISOString().slice(11, 19).replace(/:/g, '');
    this.formRunId = `${this.formSource}_to_${this.formDest}_${this.formWorkload}_${this.formLoadRps}rps_${ts}`
      .replace(/[^a-zA-Z0-9._-]+/g, '_')
      .slice(0, 80);
  }

  public canStartRun(): boolean {
    return !!(
      this.formSource &&
      this.formDest &&
      this.formSource !== this.formDest &&
      this.formNamespace &&
      this.formWorkload &&
      this.formPod &&
      !this.startingRun &&
      this.activeRunStatus !== 'running'
    );
  }

  public startEvaluationRun(): void {
    if (!this.canStartRun()) {
      return;
    }
    if (this.formTrigger === 'falco' && this.formSource.toLowerCase().includes('pnet')) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'PNET / Falco',
        detail: 'Falco-triggered PNET runs are only valid if Falco is installed on PNET and forwarding alerts. Otherwise use trigger manual.'
      });
    }

    const body: EvaluationStartRequest = {
      run_id: this.formRunId.trim() || undefined,
      source: this.formSource,
      dest: this.formDest,
      namespace: this.formNamespace,
      workload: this.formWorkload,
      pod: this.formPod,
      load_rps: this.formLoadRps,
      concurrency: this.formConcurrency,
      trigger: this.formTrigger,
      registry_address: (this.formRegistry || '').trim() || undefined,
      skip_cpu_compat_check: this.formSkipCpuCompatCheck,
      cleanup_incompatible_mounts: this.cleanupTouched ? this.formCleanupIncompatibleMounts : null,
      disable_istio_sidecar: this.formDisableIstioSidecar
    };

    this.startingRun = true;
    this.evaluationService.startRun(body).pipe(
      take(1),
      finalize(() => {
        this.startingRun = false;
      })
    ).subscribe({
      next: (res) => {
        this.activeRunDate = res.date;
        this.activeRunId = res.run_id;
        this.activeRunStatus = 'running';
        this.activeRunExitCode = null;
        this.activeLogLines = ['Evaluation wrapper started…'];
        this.resetActiveMonitor();
        this.activeStageStatuses = createDefaultMigrationStages('pipeline_check', 'running');
        this.activeStatusDetail = 'Evaluation run started — migration pipeline initializing…';
        this.messageService.add({
          key: 'tst',
          severity: 'info',
          summary: 'Evaluation started',
          detail: `Run ${res.run_id} — collecting metrics and running migration`
        });
        this.startPollingStatus(res.date, res.run_id);
      },
      error: (err) => {
        const detail = err?.error?.detail || err?.message || 'Failed to start evaluation';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Evaluation', detail: String(detail) });
      }
    });
  }

  private startPollingStatus(date: string, runId: string): void {
    this.stopPolling();
    this.pollStop$ = new Subject<void>();
    interval(2500).pipe(
      takeUntil(this.pollStop$),
      takeUntil(this.destroy$),
      switchMap(() => this.evaluationService.getRunStatus(date, runId).pipe(
        catchError((err) => of({
          status: 'unknown' as const,
          run_id: runId,
          date,
          run_dir: '',
          recent_log_lines: [err?.error?.detail || err?.message || 'Status poll failed']
        }))
      )),
      tap((status) => this.applyRunStatus(status))
    ).subscribe();
  }

  private applyRunStatus(status: EvaluationRunStatus): void {
    this.activeRunStatus = status.status;
    this.applyMonitorFields(status, 'active');
    if (status.exit_code != null) {
      this.activeRunExitCode = status.exit_code;
    }
    if (status.status === 'completed' || status.status === 'failed') {
      this.stopPolling();
      this.messageService.add({
        key: 'tst',
        severity: status.status === 'completed' ? 'success' : 'error',
        summary: 'Evaluation finished',
        detail: `Exit code ${status.exit_code ?? '?'}`
      });
      const finishedDate = this.activeRunDate;
      const finishedId = this.activeRunId;
      this.refreshRuns();
      if (finishedDate && finishedId) {
        setTimeout(() => {
          const row = this.runs.find((r) => r.run_id === finishedId && r.date === finishedDate);
          if (row) {
            this.selectRun(row);
          }
        }, 800);
      }
    }
  }

  private stopPolling(): void {
    this.pollStop$.next();
    this.pollStop$.complete();
    this.pollStop$ = new Subject<void>();
  }

  public refreshRuns(): void {
    this.loadingRuns = true;
    this.loadError = '';
    this.evaluationService.listRuns().pipe(
      take(1),
      takeUntil(this.destroy$),
      finalize(() => {
        this.loadingRuns = false;
      })
    ).subscribe({
      next: (response) => {
        this.outRoot = response.out_root || '';
        this.runs = response.runs || [];
        if (response.error) {
          this.loadError = response.error;
        }
      },
      error: (error) => {
        this.loadError = error?.error?.detail || error?.message || 'Failed to load evaluation runs';
        this.runs = [];
      }
    });
  }

  public activeMonitorStatusLabel(): string {
    if (!this.activeRunId) {
      return '';
    }
    if (this.activeRunStatus === 'running') {
      return 'running';
    }
    if (this.activeRunStatus === 'completed') {
      return 'completed';
    }
    if (this.activeRunStatus === 'failed') {
      return 'error';
    }
    return this.activeRunStatus || 'unknown';
  }

  public selectedMonitorStatusLabel(): string {
    if (!this.selectedRun) {
      return '';
    }
    const code = this.selectedRun.exit_code;
    if (code === '0') {
      return 'completed';
    }
    if (code && code !== '-1') {
      return 'error';
    }
    return 'unknown';
  }

  private resetActiveMonitor(): void {
    this.activeStageStatuses = createDefaultMigrationStages();
    this.activeDowntimeMs = null;
    this.activeStatusLogPath = '';
    this.activeStatusTargetNode = '';
    this.activeStatusK8sEvents = [];
    this.activeStatusDetail = '';
    this.activeStatusUpdatedAt = undefined;
  }

  private applyMonitorFields(status: EvaluationRunStatus, target: 'active' | 'selected'): void {
    const lines = status.log_lines?.length
      ? status.log_lines
      : status.recent_log_lines?.length
        ? status.recent_log_lines
        : null;
    const detail =
      status.message ||
      (status.status === 'completed'
        ? 'Migration completed successfully'
        : status.status === 'failed'
          ? `Evaluation migration failed (exit ${status.exit_code ?? '?'})`
          : 'Migration in progress');

    if (target === 'active') {
      if (lines?.length) {
        this.activeLogLines = lines;
      }
      if (status.stage_statuses?.length) {
        this.activeStageStatuses = status.stage_statuses;
      }
      this.activeDowntimeMs = status.downtime_ms ?? this.activeDowntimeMs;
      this.activeStatusLogPath = status.log_path || status.run_dir || this.activeStatusLogPath;
      this.activeStatusTargetNode = status.target_node || this.activeStatusTargetNode;
      this.activeStatusK8sEvents = status.recent_k8s_events || this.activeStatusK8sEvents;
      this.activeStatusDetail = detail;
      this.activeStatusUpdatedAt = new Date();
      return;
    }

    this.selectedLogLines = lines || this.selectedLogLines;
    if (status.stage_statuses?.length) {
      this.selectedStageStatuses = status.stage_statuses;
    }
    this.selectedDowntimeMs = status.downtime_ms ?? null;
    this.selectedStatusLogPath = status.log_path || status.run_dir || '';
    this.selectedStatusTargetNode = status.target_node || '';
    this.selectedStatusK8sEvents = status.recent_k8s_events || [];
    this.selectedStatusDetail = detail;
    this.selectedStatusUpdatedAt = new Date();
    this.selectedRunStatusLabel = status.status;
  }

  private loadSelectedRunMonitor(run: EvaluationRunRow): void {
    if (!run.date || !run.run_id) {
      return;
    }
    const final =
      run.exit_code === '0' ? 'completed' : run.exit_code && run.exit_code !== '-1' ? 'error' : 'running';
    this.evaluationService.getRunStatus(run.date, run.run_id).pipe(take(1)).subscribe({
      next: (status) => this.applyMonitorFields(status, 'selected'),
      error: () => {
        this.selectedStageStatuses = createDefaultMigrationStages();
        this.selectedStatusDetail = 'Could not load pipeline status for this run.';
      }
    });
  }

  public selectRun(run: EvaluationRunRow): void {
    if (!run.date || !run.run_id) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Evaluation',
        detail: 'Run is missing date or id; cannot open details.'
      });
      return;
    }
    this.selectedRun = run;
    this.selectedDetail = null;
    this.selectedArtifactName = null;
    this.selectedArtifactContent = null;
    this.selectedStageStatuses = createDefaultMigrationStages();
    this.selectedDowntimeMs = null;
    this.selectedStatusLogPath = '';
    this.selectedStatusTargetNode = '';
    this.selectedStatusK8sEvents = [];
    this.selectedLogLines = [];
    this.selectedStatusDetail = 'Loading migration pipeline status…';
    this.loadingDetail = true;
    this.loadSelectedRunMonitor(run);

    this.evaluationService.getRun(run.date, run.run_id).pipe(
      take(1),
      takeUntil(this.destroy$),
      finalize(() => {
        this.loadingDetail = false;
      }),
      tap((detail) => {
        const sortedArtifacts = [...detail.artifacts].sort((a, b) => this.artifactSort(a, b));
        this.selectedDetail = { ...detail, artifacts: sortedArtifacts };
        const preferred = sortedArtifacts.find((a) => a.name === 'migration.log') ?? sortedArtifacts[0];
        if (preferred) {
          this.viewArtifact(preferred.name);
        }
      }),
      catchError((error) => {
        const detail = error?.error?.detail || error?.message || 'Failed to load run details';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Evaluation', detail });
        return of(null);
      })
    ).subscribe();
  }

  public viewArtifact(name: string): void {
    if (!this.selectedRun?.date || !this.selectedRun?.run_id) {
      return;
    }
    this.selectedArtifactName = name;
    this.selectedArtifactContent = null;
    this.loadingFile = true;
    this.evaluationService.getFile(this.selectedRun.date, this.selectedRun.run_id, name).pipe(
      take(1),
      finalize(() => {
        this.loadingFile = false;
      })
    ).subscribe({
      next: (response: EvaluationFileResponse) => {
        this.selectedArtifactContent = response.content;
        this.selectedArtifactTruncated = response.truncated;
        this.selectedArtifactSize = response.size_bytes;
      },
      error: (error) => {
        const detail = error?.error?.detail || error?.message || 'Failed to load artifact';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Evaluation', detail });
      }
    });
  }

  public exitCodeSeverity(code: string): 'success' | 'danger' | 'info' {
    if (code === '0') {
      return 'success';
    }
    if (code === '-1' || !code) {
      return 'info';
    }
    return 'danger';
  }

  public formatBytes(value: number | null | undefined): string {
    if (value == null || !Number.isFinite(value)) {
      return '—';
    }
    if (value < 1024) {
      return `${value} B`;
    }
    if (value < 1024 * 1024) {
      return `${(value / 1024).toFixed(1)} KiB`;
    }
    return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
  }

  public formatMetadataValue(value: unknown): string {
    if (value == null) {
      return 'null';
    }
    if (typeof value === 'string') {
      return value;
    }
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }

  public metadataEntries(): Array<{ key: string; value: string }> {
    const meta = this.selectedDetail?.metadata;
    if (!meta) {
      return [];
    }
    return Object.keys(meta).map((key) => ({ key, value: this.formatMetadataValue(meta[key]) }));
  }

  public wgInvolved(run: EvaluationRunRow): boolean {
    const s = (run.source || '').toLowerCase();
    const d = (run.dest || '').toLowerCase();
    return s.includes('pnet') || d.includes('pnet');
  }

  private artifactSort(a: EvaluationArtifact, b: EvaluationArtifact): number {
    const pa = this.artifactPriority[a.name] ?? 100;
    const pb = this.artifactPriority[b.name] ?? 100;
    if (pa !== pb) {
      return pa - pb;
    }
    return a.name.localeCompare(b.name);
  }
}
