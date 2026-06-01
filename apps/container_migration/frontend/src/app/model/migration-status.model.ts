export type MigrationRuntimeStatus = 'not_started' | 'started' | 'running' | 'completed' | 'error' | 'not_found';
export type MigrationStageStatus = 'pending' | 'running' | 'completed' | 'failed';

export interface MigrationStage {
  key: string;
  label: string;
  status: MigrationStageStatus;
  /** Wall-clock span for this stage when log lines include UTC timestamps (newer runs). */
  duration_ms?: number | null;
}

export interface MigrationStatusResponse {
  status: 'running' | 'completed' | 'error' | 'not_found';
  message?: string;
  result?: string;
  error?: string;
  log_path?: string;
  return_code?: number;
  source_cluster?: string;
  target_cluster?: string;
  namespace?: string;
  target_pod_name?: string;
  target_node?: string;
  recent_k8s_events?: string[];
  recent_log_lines?: string[];
  log_lines?: string[];
  stage_statuses?: MigrationStage[];
  /** Source workload stopped → restore pod running (requires timestamped migration logs). */
  downtime_ms?: number | null;
}

export interface MigrationHistoryItem {
  podName: string;
  sourceCluster: string;
  targetCluster: string;
  namespace: string;
  targetPodName?: string;
  logLines?: string[];
  stageStatuses?: MigrationStage[];
  downtimeMs?: number | null;
  startedAt: Date;
  finishedAt?: Date;
  status: MigrationRuntimeStatus;
  logPath?: string;
  summary?: string;
}

export interface MigrationHistoryApiItem {
  pod_name: string;
  app_name: string;
  source_cluster?: string;
  target_cluster?: string;
  namespace?: string;
  target_pod_name?: string;
  log_lines?: string[];
  stage_statuses?: MigrationStage[];
  downtime_ms?: number | null;
  status: 'running' | 'completed' | 'error';
  summary: string;
  log_path: string;
  return_code?: number | null;
  created_at: string;
}

export interface MigrationHistoryApiResponse {
  items: MigrationHistoryApiItem[];
  limit: number;
  offset: number;
  total: number;
  has_more: boolean;
}
