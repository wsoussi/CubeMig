import { Component, effect, OnInit, signal, WritableSignal } from '@angular/core';
import { MessageService, SelectItem } from 'primeng/api';
import { K8sService } from '../../service/k8s.service';
import { catchError, map, of, take, tap } from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { MigrationRequest } from '../../model/migration-request.model';
import { ForwardRefHandling } from '@angular/compiler';

@Component({
  selector: 'app-migration',
  templateUrl: './migration.component.html',
  styleUrl: './migration.component.scss'
})
export class MigrationComponent implements OnInit{
  
  sourceCluster: SelectItem[] = [];
  targetCluster: SelectItem[] = [];
  podsCluster1: SelectItem[] = [];
  namespaceList: SelectItem[] = [];
  selectedSource: string = '';
  selectedTarget: string = '';
  selectedPod: Pod = {} as Pod;
  selectedNamespace: WritableSignal<string> = signal('');
  isGeneratingFA = false;
  isGeneratingAISuggestion = false;
  loading = false;

  constructor(private k8sService: K8sService, private messageService: MessageService) {
    effect(() => {
      const ns = this.selectedNamespace(); 
      this.selectedPod = {} as Pod;
      this.getPodsCluster1();
    });
  }
  ngOnInit(): void {
    
    this.sourceCluster = [
      { label: 'Cluster 1', value: 'cluster1' }
    ];

    this.targetCluster = [
      { label: 'Cluster 2', value: 'cluster2' },
      { label: 'Cluster SEV-SNP', value: 'cluster-sev-snp' }
    ];

    this.namespaceList = [
      { label: 'default', value: 'default' },
      { label: 'istio-enabled', value: 'istio-enabled' }
    ]
  }

  private getPodsCluster1() {
    this.k8sService.getPods('cluster1', this.selectedNamespace()).pipe(
      take(1),
      map((podResponse: PodsResponse) => {
        return podResponse.pods
          .filter(pod => pod.status === 'Running')
          .map(pod => ({ label: pod.podName, value: {"podName": pod.podName, "appName": pod.appName} } as SelectItem));
      }),
      catchError(() => {
        return of([] as SelectItem[]);
      })
    ).subscribe((pods: SelectItem[]) => {
      this.podsCluster1 = pods;
    });
  }

  public reset(): void {
    console.log(this.selectedNamespace())
    this.selectedSource = '';
    this.selectedTarget = '';
    this.selectedNamespace.set('');
    this.selectedPod = {} as Pod;
    this.isGeneratingFA = false;
    this.isGeneratingAISuggestion = false;
  }

  public areDropdownsFilled(): boolean {
    return this.selectedSource !== '' && this.selectedTarget !== '' && this.selectedNamespace() !== '';
  }

  public migratePod(): void {
    this.loading = true;
    const migrationRequest: MigrationRequest = {
      sourceCluster: this.selectedSource,
      targetCluster: this.selectedTarget,
      namespace: this.selectedNamespace(),
      podName: this.selectedPod.podName!,
      appName: this.selectedPod.appName!,
      forensicAnalysis: this.isGeneratingFA,
      AISuggestion: this.isGeneratingAISuggestion
    };
    this.k8sService.migratePod(migrationRequest).pipe(
      take(1), // Ensures only one emission is taken
      tap((response: any) => {
        this.loading = false;
        this.messageService.add({ key: 'tst', severity: 'success', summary: 'Success', detail: 'Migration started successfully' });
        this.reset();
      }),
      catchError((error: any) => {
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail: error.detail });
        return of(error);
      })
    ).subscribe();
  }
}
