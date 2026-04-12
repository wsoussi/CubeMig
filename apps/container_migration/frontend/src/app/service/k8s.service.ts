import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';
import { PodsResponse } from '../model/k8s.model';
import { MigrationRequest } from '../model/migration-request.model';
import { MigrationHistoryApiResponse, MigrationStatusResponse } from '../model/migration-status.model';

@Injectable({
  providedIn: 'root'
})
export class K8sService {

  private apiUrl = 'http://160.85.255.146:8000'; // Change this to your FastAPI server URL

  constructor(private http: HttpClient) {}

  getClusters(): Observable<{ clusters: string[] }> {
    const url = `${this.apiUrl}/k8s/clusters`;
    return this.http.get<{ clusters: string[] }>(url);
  }

  /**
   * Get a list of pods and their statuses from the specified cluster.
   * @param cluster The name of the cluster (e.g., 'cluster1' or 'cluster2')
   * @returns Observable containing the pods data as PodsResponse.
   */
  getPods(cluster: string, namespace: string): Observable<PodsResponse> {
    const url = `${this.apiUrl}/k8s/pods/${cluster}/${namespace}`;
    return this.http.get<PodsResponse>(url);
  }

    /**
   * Delete a pod with the specified name from the specified cluster.
   * @param cluster The name of the cluster (e.g., 'cluster1' or 'cluster2')
   * @param podName The name of the pod (e.g., 'cpu-restore')
   * @returns Observable containing the pods data as PodsResponse.
   */
  deletePod(cluster: string, namespace: string, podName: string): Observable<void> {
    const url = `${this.apiUrl}/k8s/pods/${cluster}/${namespace}/${podName}`;
    return this.http.delete<void>(url);
  }

  migratePod(request: MigrationRequest): Observable<{ message: string; log_path?: string }> {
    const url = `${this.apiUrl}/migrate`;
    return this.http.post<{ message: string; log_path?: string }>(url, request);
  }

  getMigrationStatus(podName: string): Observable<MigrationStatusResponse> {
    const url = `${this.apiUrl}/migration-status/${podName}`;
    return this.http.get<MigrationStatusResponse>(url);
  }

  getMigrationHistory(limit = 10, offset = 0): Observable<MigrationHistoryApiResponse> {
    const url = `${this.apiUrl}/migration-history?limit=${limit}&offset=${offset}`;
    return this.http.get<MigrationHistoryApiResponse>(url);
  }

  getRoutingDemoTrafficSubset(cluster: string): Observable<{ cluster: string; subset: string }> {
    const url = `${this.apiUrl}/k8s/routing-demo/traffic-subset/${encodeURIComponent(cluster)}`;
    return this.http.get<{ cluster: string; subset: string }>(url);
  }

  toggleRoutingDemoTraffic(cluster: string): Observable<{
    cluster: string;
    previous_subset: string;
    subset: string;
    message: string;
  }> {
    const url = `${this.apiUrl}/k8s/routing-demo/toggle-traffic`;
    return this.http.post<{ cluster: string; previous_subset: string; subset: string; message: string }>(url, {
      cluster
    });
  }

}