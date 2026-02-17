import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { map, Observable } from 'rxjs';
import { PodsResponse } from '../model/k8s.model';
import { MigrationRequest } from '../model/migration-request.model';
import { TreeNode } from 'primeng/api';

@Injectable({
  providedIn: 'root'
})
export class K8sService {

  private apiUrl = 'http://160.85.255.146:8000'; // Change this to your FastAPI server URL

  constructor(private http: HttpClient) {}

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

  migratePod(request: MigrationRequest): Observable<void> {
    const url = `${this.apiUrl}/migrate`;
    return this.http.post<void>(url, request);
  }

}