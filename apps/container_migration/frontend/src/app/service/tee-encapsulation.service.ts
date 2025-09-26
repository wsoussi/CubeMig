import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { TeeOperationResponse } from '../model/tee-operation.model';

export interface PodmanContainer {
  containerName: string;
  containerID: string;
  image: string;
  status: string;
  environment: string;
}

export interface PodmanContainersResponse {
  normal_containers: PodmanContainer[];
  sevsnp_containers: PodmanContainer[];
  error?: string;
}

@Injectable({
  providedIn: 'root'
})
export class TeeEncapsulationService {
  
  private apiUrl = 'http://160.85.255.146:8000'; // Use the same URL as simulation service

  constructor(private http: HttpClient) { }

  getPodmanContainers(): Observable<PodmanContainersResponse> {
    const url = `${this.apiUrl}/tee-operation/containers`;
    console.log('Fetching podman containers from:', url);
    return this.http.get<PodmanContainersResponse>(url);
  }

  performTeeOperation(containerName: string, operation: string): Observable<TeeOperationResponse> {
    const url = `${this.apiUrl}/tee-operation`;
    const body = {
      containerName: containerName,
      operation: operation
    };
    console.log('Sending TEE operation request:', body);
    return this.http.post<TeeOperationResponse>(url, body);
  }
  
  getOperationHistory(): Observable<any> {
    const url = `${this.apiUrl}/tee-operation/operations`;
    console.log('Fetching TEE operation history from:', url);
    return this.http.get(url);
  }
}
