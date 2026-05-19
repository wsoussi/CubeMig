import { Component, Input, OnChanges, OnDestroy, OnInit, SimpleChanges } from '@angular/core';
import { filter, interval, Subject, takeUntil } from 'rxjs';
import { MigrationStage } from '../../model/migration-status.model';
import { createDefaultMigrationStages, formatMigrationDuration } from '../migration-pipeline.util';

@Component({
  selector: 'app-migration-pipeline-monitor',
  templateUrl: './migration-pipeline-monitor.component.html',
  styleUrl: './migration-pipeline-monitor.component.scss'
})
export class MigrationPipelineMonitorComponent implements OnInit, OnChanges, OnDestroy {
  @Input() title = 'Migration monitor';
  @Input() statusLabel = '';
  @Input() statusBadgeClass = '';
  @Input() showSpinner = false;
  @Input() statusDetail = '';
  @Input() statusUpdatedAt?: Date;
  @Input() statusTargetNode = '';
  @Input() downtimeMs: number | null = null;
  @Input() statusLogPath = '';
  @Input() liveLogLines: string[] = [];
  @Input() statusK8sEvents: string[] = [];
  @Input() stageStatuses: MigrationStage[] = createDefaultMigrationStages();
  @Input() timerActive = false;

  timerUiTick = 0;
  private stageRunStartedAt: Record<string, number> = {};
  private stageClientDurationMs: Record<string, number> = {};
  private destroy$ = new Subject<void>();

  ngOnInit(): void {
    interval(1000)
      .pipe(
        takeUntil(this.destroy$),
        filter(() => this.timerActive),
        filter(() => this.stageStatuses.some((s) => s.status === 'running'))
      )
      .subscribe(() => {
        this.timerUiTick++;
      });
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['stageStatuses'] && !changes['stageStatuses'].firstChange) {
      const prev = changes['stageStatuses'].previousValue as MigrationStage[] | undefined;
      this.updateStageRunTiming(prev || [], this.stageStatuses);
    }
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  formatDuration(ms: number): string {
    return formatMigrationDuration(ms);
  }

  formatStageTiming(stage: MigrationStage, _tick: number): string {
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
}
