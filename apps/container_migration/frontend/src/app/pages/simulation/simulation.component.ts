import { Component, OnInit } from '@angular/core';
import { K8sService } from '../../service/k8s.service';
import { MessageService, SelectItem } from 'primeng/api';
import { catchError, map, of, take, tap } from 'rxjs';
import { PodsResponse } from '../../model/k8s.model';
import { SimulationService } from '../../service/simulation.service';

@Component({
  selector: 'app-simulation',
  templateUrl: './simulation.component.html',
  styleUrl: './simulation.component.scss'
})
export class SimulationComponent implements OnInit{
  
  targetPod: SelectItem[] = [];
  attackType: SelectItem[] = [];
  selectedApp: string = '';
  selectedAttack: string = '';
  loading = false;

  constructor(
    private k8sService: K8sService, 
    private simulationService: SimulationService,
    private messageService: MessageService
  ) {}

  ngOnInit(): void {
    this.attackType = [
      { label: 'Reverse shell', value: 'reverse_shell' },
      { label: 'Data destruction', value: 'data_destruction' },
      { label: 'Log file removal', value: 'log_removal' }
    ];

    this.getPodsCluster1();
  }

  private getPodsCluster1() {
      this.k8sService.getPods('cluster1', 'default').pipe(
        map((podResponse: PodsResponse) => {
            return podResponse.pods
            .filter(pod => pod.status === 'Running' && pod.podName!.startsWith('vuln-spring'))
            .map(pod => ({ label: pod.appName, value: pod.appName } as SelectItem));
        }),
        catchError(() => {
          return of([] as SelectItem[]);
        })
      ).subscribe((pods: SelectItem[]) => {
        this.targetPod = pods;
      });
    }

  public reset(): void {
    this.selectedApp = '';
    this.selectedAttack = '';
  }

  public simulateAttack(): void {
    this.loading = true;
    console.log("Simulating attack: " + this.selectedAttack + " on pod: " + this.selectedApp);
    this.simulationService.triggerSimulation(this.selectedApp, this.selectedAttack).pipe(
      take(1), 
      tap(() => {
        this.loading = false;
        this.messageService.add({key: 'tst', severity: 'success', summary: 'Success', detail: `${this.selectedAttack} triggered successfully on ${this.selectedApp}` });
        this.reset();
      }),
      catchError((error: any) => {
        this.messageService.add({key: 'tst', severity: 'error', summary: 'Error', detail: `Failed to trigger attack on ${this.selectedApp}`});
        return of(error);
      })
    ).subscribe();
  }
}
