import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { SimulationRequest } from '../model/simulation-request.model';
import { SimulationRule, SimulationRulesResponse } from '../model/simulation-rule.model';

@Injectable({
  providedIn: 'root'
})
export class SimulationService {
    private apiUrl = 'http://160.85.255.146:8000'; // Replace with your actual API URL

    constructor(private http: HttpClient) {}

    triggerSimulation(appName: string, attackType: string): Observable<{
        message: string;
        autoMigration?: Record<string, unknown>;
    }> {
        const url = `${this.apiUrl}/simulate`;
        const body: SimulationRequest = {
            "appName": appName, 
            "attackType": attackType
        };
        return this.http.post<{ message: string; autoMigration?: Record<string, unknown> }>(url, body);
    }

    getSimulationRules(): Observable<SimulationRule[]> {
        const url = `${this.apiUrl}/simulate/rules`;
        return this.http.get<SimulationRulesResponse>(url).pipe(
            map((response) => response.rules || [])
        );
    }

    addSimulationRule(rule: SimulationRule): Observable<{ message: string }> {
        const url = `${this.apiUrl}/simulate/rules`;
        return this.http.post<{ message: string }>(url, rule);
    }

    updateSimulationRule(index: number, rule: SimulationRule): Observable<{ message: string }> {
        const url = `${this.apiUrl}/simulate/rules/${index}`;
        return this.http.put<{ message: string }>(url, rule);
    }

    deleteSimulationRule(index: number): Observable<{ message: string }> {
        const url = `${this.apiUrl}/simulate/rules/${index}`;
        return this.http.delete<{ message: string }>(url);
    }
}