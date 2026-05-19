import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { MigrationStage } from '../model/migration-status.model';

export interface EvaluationRunRow {
  run_id: string;
  source: string;
  dest: string;
  namespace: string;
  workload: string;
  pod: string;
  load_rps: string;
  concurrency: string;
  trigger: string;
  start_time_utc: string;
  end_time_utc: string;
  exit_code: string;
  run_dir: string;
  checkpoint_file: string;
  date: string | null;
}

export interface EvaluationRunsResponse {
  out_root: string;
  runs: EvaluationRunRow[];
  error: string | null;
}

export interface EvaluationArtifact {
  name: string;
  size_bytes: number | null;
}

export interface EvaluationRunDetail {
  run_dir: string;
  metadata: Record<string, unknown> | null;
  artifacts: EvaluationArtifact[];
}

export interface EvaluationFileResponse {
  name: string;
  size_bytes: number;
  truncated: boolean;
  content: string;
}

export interface EvaluationStartRequest {
  run_id?: string;
  source: string;
  dest: string;
  namespace: string;
  workload: string;
  pod: string;
  load_rps: number;
  concurrency: number;
  trigger: string;
  registry_address?: string;
  skip_cpu_compat_check?: boolean;
  cleanup_incompatible_mounts?: boolean | null;
  disable_istio_sidecar?: boolean;
  forensic_analysis?: boolean;
  ai_suggestion?: boolean;
}

export interface EvaluationStartResponse {
  message: string;
  run_id: string;
  date: string;
  run_dir: string;
  out_root: string;
}

export interface EvaluationRunStatus {
  status: 'running' | 'completed' | 'failed' | 'unknown';
  run_id: string;
  date: string;
  run_dir: string;
  exit_code?: number;
  started_at?: string;
  error?: string;
  metadata?: Record<string, unknown>;
  recent_log_lines?: string[];
  log_lines?: string[];
  log_path?: string;
  message?: string;
  source_cluster?: string;
  target_cluster?: string;
  namespace?: string;
  target_pod_name?: string;
  target_node?: string;
  recent_k8s_events?: string[];
  stage_statuses?: MigrationStage[];
  downtime_ms?: number | null;
}

@Injectable({ providedIn: 'root' })
export class EvaluationService {
  private apiUrl = 'http://160.85.255.146:8000';

  constructor(private http: HttpClient) {}

  listRuns(): Observable<EvaluationRunsResponse> {
    return this.http.get<EvaluationRunsResponse>(`${this.apiUrl}/evaluation/runs`);
  }

  startRun(body: EvaluationStartRequest): Observable<EvaluationStartResponse> {
    return this.http.post<EvaluationStartResponse>(`${this.apiUrl}/evaluation/start`, body);
  }

  getRunStatus(date: string, runId: string): Observable<EvaluationRunStatus> {
    const url = `${this.apiUrl}/evaluation/runs/${encodeURIComponent(date)}/${encodeURIComponent(runId)}/status`;
    return this.http.get<EvaluationRunStatus>(url);
  }

  getRun(date: string, runId: string): Observable<EvaluationRunDetail> {
    const url = `${this.apiUrl}/evaluation/runs/${encodeURIComponent(date)}/${encodeURIComponent(runId)}`;
    return this.http.get<EvaluationRunDetail>(url);
  }

  getFile(date: string, runId: string, name: string): Observable<EvaluationFileResponse> {
    const url = `${this.apiUrl}/evaluation/runs/${encodeURIComponent(date)}/${encodeURIComponent(runId)}/file`;
    return this.http.get<EvaluationFileResponse>(url, { params: { name } });
  }
}
