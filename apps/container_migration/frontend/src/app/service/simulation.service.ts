import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { SimulationRequest } from '../model/simulation-request.model';

export interface AttackRuleMapping {
    attackType: string;
    falcoRule: string;
}

export interface SimulationResponse {
    message: string;
    appName: string;
    attackType: string;
    falcoRule: string;
    cluster?: string | null;
    namespace?: string | null;
    podName?: string | null;
    targetUrl?: string;
    targetSource?: string;
    detail: string;
}

@Injectable({
  providedIn: 'root'
})
export class SimulationService {
    private apiUrl = 'http://160.85.255.146:8000';

    constructor(private http: HttpClient) {}

    triggerSimulation(
        appName: string,
        attackType: string,
        cluster?: string,
        namespace?: string
    ): Observable<SimulationResponse> {
        const url = `${this.apiUrl}/simulate`;
        const body: SimulationRequest = {
            "appName": appName,
            "attackType": attackType,
            "cluster": cluster,
            "namespace": namespace
        };
        return this.http.post<SimulationResponse>(url, body);
    }

    getAttackRuleMapping(): Observable<AttackRuleMapping[]> {
        const url = `${this.apiUrl}/simulate/attack-mapping`;
        return this.http.get<{ mapping: AttackRuleMapping[] }>(url).pipe(
            map((response) => response.mapping || [])
        );
    }
}
