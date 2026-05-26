import { MigrationStage, MigrationStageStatus } from '../model/migration-status.model';

/** Default pipeline stages aligned with single-migration.sh log markers. */
export function createDefaultMigrationStages(
  runningKey?: string,
  runningState: MigrationStageStatus = 'pending'
): MigrationStage[] {
  const statusFor = (key: string): MigrationStageStatus =>
    runningKey === key ? runningState : 'pending';

  return [
    { key: 'pipeline_check', label: 'Pipeline checks', status: statusFor('pipeline_check') },
    { key: 'dest_prep', label: 'Destination prep (pre-checkpoint)', status: statusFor('dest_prep') },
    { key: 'checkpoint', label: 'Checkpoint creation', status: statusFor('checkpoint') },
    {
      key: 'source_stop_post_checkpoint',
      label: 'Source scaled down (post-checkpoint)',
      status: statusFor('source_stop_post_checkpoint')
    },
    { key: 'checkpoint_normalization', label: 'Checkpoint normalization', status: statusFor('checkpoint_normalization') },
    { key: 'image', label: 'Image conversion and push', status: statusFor('image') },
    {
      key: 'checkpoint_prepull',
      label: 'Checkpoint image pre-pull (optional)',
      status: statusFor('checkpoint_prepull')
    },
    { key: 'restore', label: 'Restore pod startup', status: statusFor('restore') },
    { key: 'traffic', label: 'Traffic switch', status: statusFor('traffic') },
    { key: 'cleanup', label: 'Migration finalize', status: statusFor('cleanup') }
  ];
}

export function formatMigrationDuration(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  if (m > 0) {
    return `${m}m ${s}s`;
  }
  return `${s}s`;
}
