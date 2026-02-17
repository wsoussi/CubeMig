import { Component, OnDestroy, OnInit } from '@angular/core';
import { K8sService } from '../../service/k8s.service';
import { catchError, interval, map, Observable, of, startWith, Subject, switchMap, take, takeUntil, tap } from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { MessageService, SelectItem } from 'primeng/api';

@Component({
  selector: 'app-overview',
  templateUrl: './overview.component.html',
  styleUrl: './overview.component.scss'
})
export class OverviewComponent implements OnInit, OnDestroy{
  
  public podsClusterLeft!: Pod[];
  public podsClusterRight!: Pod[];
  private destroy$ = new Subject<void>();

  clusterListLeft: SelectItem[] = []
  clusterListRight: SelectItem[] = []
  namespaceList: SelectItem[] = []
  selectedClusterLeft: string = ''
  selectedClusterRight: string = ''
  selectedNamespace: string = ''


  constructor(private k8sService: K8sService, private messageService: MessageService) {}

  public ngOnInit(): void {
    this.namespaceList = [
       { label: 'default', value: 'default' },
       { label: 'istio-enabled', value: 'istio-enabled' }
    ]
    this.clusterListLeft = [
      { label: 'Cluster 1', value: 'cluster1' },
      { label: 'Cluster 2', value: 'cluster2' },
      { label: 'Cluster SEV-SNP', value: 'cluster-sev-snp' },
    ]
    this.clusterListRight = this.clusterListLeft
    this.selectedClusterLeft = 'cluster1'
    this.selectedClusterRight = 'cluster-sev-snp'
    this.selectedNamespace = 'default'
    this.getPodsLeft()
    this.getPodsRight()
  }

  public ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }


  public getPodsLeft() {
    interval(3000)
      .pipe(
        startWith(0), // Start immediately
        switchMap(() =>
          this.k8sService.getPods(this.selectedClusterLeft, this.selectedNamespace).pipe(
            map((podResponse: PodsResponse) => {
              return podResponse.pods;
            }),
            catchError(() => {
              return of([] as Pod[]);
            })
          )
        ),
        takeUntil(this.destroy$)
      )
      .subscribe((pods: Pod[]) => {
        this.podsClusterLeft = pods;
      });
  }

  public getPodsRight() {
    interval(3000)
      .pipe(
        startWith(0), // Start immediately
        switchMap(() =>
          this.k8sService.getPods(this.selectedClusterRight, this.selectedNamespace).pipe(
            map((podResponse: PodsResponse) => {
              return podResponse.pods;
            }),
            catchError(() => {
              return of([] as Pod[]);
            })
          )
        ),
        takeUntil(this.destroy$)
      )
      .subscribe((pods: Pod[]) => {
        this.podsClusterRight = pods;
      });
  }

  public deletePod(cluster: string, podName: string): void {
    this.k8sService.deletePod(cluster, this.selectedNamespace, podName).pipe(
      take(1), // Ensures only one emission is taken
      tap(() => {
        this.messageService.add({key: 'tst', severity: 'success', summary: 'Success', detail: `Pod ${podName} deleted successfully.` });
        if(cluster === this.selectedClusterLeft) {
          this.getPodsLeft();
        } else if (cluster === this.selectedClusterRight) {
          this.getPodsRight();
        }
      }),
      catchError((error: any) => {
        this.messageService.add({key: 'tst', severity: 'error', summary: 'Error', detail: `Failed to delete pod ${podName}`});
        return of(error);
      })
    ).subscribe();
  }
}
