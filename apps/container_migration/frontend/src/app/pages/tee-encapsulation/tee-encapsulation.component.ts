import { Component, OnDestroy, OnInit } from '@angular/core';
import { MessageService, SelectItem } from 'primeng/api';
import { TeeOperationResponse } from '../../model/tee-operation.model';
import { catchError, interval, of, startWith, Subject, switchMap, takeUntil, tap } from 'rxjs';
import { TeeEncapsulationService, PodmanContainer, PodmanContainersResponse } from '../../service/tee-encapsulation.service';

@Component({
  selector: 'app-tee-encapsulation',
  templateUrl: './tee-encapsulation.component.html',
  styleUrl: './tee-encapsulation.component.scss'
})
export class TeeEncapsulationComponent implements OnInit, OnDestroy {
  
  public normalContainers: PodmanContainer[] = [];
  public sevsnpContainers: PodmanContainer[] = [];
  private destroy$ = new Subject<void>();

  // Control panel state
  public selectedApp: string = '';
  public selectedOperation: string = '';
  public loading = false;
  public encapsulationTypes: SelectItem[] = [
    { label: 'Encapsulate (Normal → SEV-SNP)', value: 'encapsulate' },
    { label: 'Decapsulate (SEV-SNP → Normal)', value: 'decapsulate' }
  ];

  constructor(
    private teeService: TeeEncapsulationService,
    private messageService: MessageService,
  ) {}

  ngOnInit(): void {
    // Poll for container status updates every 5 seconds
    interval(5000).pipe(
      startWith(0),
      switchMap(() => this.teeService.getPodmanContainers()),
      takeUntil(this.destroy$)
    ).subscribe({
      next: (response: PodmanContainersResponse) => {
        this.normalContainers = response.normal_containers;
        this.sevsnpContainers = response.sevsnp_containers;

        if (this.normalContainers.length === 0 && this.sevsnpContainers.length === 0) {
          this.messageService.add({
            key: 'tst',
            severity: 'info',
            summary: 'No Containers',
            detail: 'No podman containers found in either environment'
          });
        }
      },
      error: (error: any) => {
        console.error('Error fetching podman containers:', error);
        this.messageService.add({
          key: 'tst',
          severity: 'error',
          summary: 'Error',
          detail: 'Failed to load podman containers. Check console for details.'
        });
      }
    });
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  public reset(): void {
    this.selectedApp = '';
    this.selectedOperation = '';
  }

  public isOperationValid(): boolean {
    if (!this.selectedApp || !this.selectedOperation) return false;

    const inNormalEnv = this.normalContainers.some(c => c.containerName === this.selectedApp);
    const inSevSnpEnv = this.sevsnpContainers.some(c => c.containerName === this.selectedApp);

    if (this.selectedOperation === 'encapsulate') {
      return inNormalEnv && !inSevSnpEnv;
    } else if (this.selectedOperation === 'decapsulate') {
      return !inNormalEnv && inSevSnpEnv;
    }
    
    return false;
  }

  public getOperationTooltip(): string {
    if (!this.selectedApp) return 'Please select an application first';

    const inNormalEnv = this.normalContainers.some(c => c.containerName === this.selectedApp);
    const inSevSnpEnv = this.sevsnpContainers.some(c => c.containerName === this.selectedApp);

    if (inNormalEnv && !inSevSnpEnv) {
      return this.selectedOperation === 'decapsulate' ? 
        'Container must be in SEV-SNP environment to decapsulate' : '';
    } else if (!inNormalEnv && inSevSnpEnv) {
      return this.selectedOperation === 'encapsulate' ? 
        'Container must be in normal environment to encapsulate' : '';
    }

    return 'Container not found in either environment';
  }

  public encapsulateTEE(): void {
    if (!this.selectedApp || !this.selectedOperation || !this.isOperationValid()) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Validation Error',
        detail: 'Please select a valid application and operation combination'
      });
      return;
    }

    // Show confirmation dialog
    this.messageService.clear();
    this.messageService.add({
      key: 'confirm',
      sticky: true,
      severity: 'warn',
      summary: 'Confirm Operation',
      detail: `Are you sure you want to ${this.selectedOperation} container "${this.selectedApp}"?`,
    });
  }

  public currentOperationLog: string | null = null;
  
  public confirmOperation(): void {
    this.messageService.clear('confirm');
    this.loading = true;
    this.currentOperationLog = 'Starting TEE operation...';

    this.teeService.performTeeOperation(this.selectedApp, this.selectedOperation).pipe(
      tap((response: TeeOperationResponse) => {
        if (response.success) {
          this.messageService.add({
            key: 'tst',
            severity: 'success',
            summary: 'Success',
            detail: `Container ${this.selectedOperation} operation started successfully`
          });
          // Format and display the operation log
          let logContent = `TEE Operation Log\n`;
          logContent += `============================\n`;
          logContent += `Operation: ${this.selectedOperation}\n`;
          logContent += `Container: ${this.selectedApp}\n`;
          logContent += `Status: Success\n\n`;
          logContent += `Details:\n${response.details || 'No additional details'}\n`;
          this.currentOperationLog = logContent;
        } else {
          throw new Error(response.message);
        }
        this.reset();
      }),
      catchError((error: any) => {
        console.error('TEE operation error:', error);
        this.messageService.add({
          key: 'tst',
          severity: 'error',
          summary: 'Error',
          detail: error.message || 'Failed to perform TEE operation'
        });
        // Format and display error log
        let logContent = `TEE Operation Log\n`;
        logContent += `============================\n`;
        logContent += `Operation: ${this.selectedOperation}\n`;
        logContent += `Container: ${this.selectedApp}\n`;
        logContent += `Status: Failed\n\n`;
        logContent += `Error Details:\n${error.details || error.message || 'Unknown error'}\n`;
        this.currentOperationLog = logContent;
        return of(error);
      })
    ).subscribe(() => {
      this.loading = false;
    });
  }

  public cancelOperation(): void {
    this.messageService.clear('confirm');
  }
}
