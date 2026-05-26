import { Component, OnDestroy, OnInit } from '@angular/core';
import { K8sService } from '../../service/k8s.service';
import { MessageService, SelectItem } from 'primeng/api';
import { catchError, finalize, forkJoin, map, of, Subject, take, takeUntil, tap } from 'rxjs';
import { Pod, PodsResponse } from '../../model/k8s.model';
import { AttackRuleMapping, SimulationResponse, SimulationService } from '../../service/simulation.service';
import { ConfigService } from '../../service/config.service';
import { RuleConfig } from '../../model/config.model';

interface VulnAppOption {
  appName: string;
  podName: string;
  namespace: string;
}

@Component({
  selector: 'app-simulation',
  templateUrl: './simulation.component.html',
  styleUrl: './simulation.component.scss'
})
export class SimulationComponent implements OnInit, OnDestroy {

  attackType: SelectItem[] = [];
  clusterSelection: SelectItem[] = [];
  attackClusterSelection: SelectItem[] = [];
  targetPod: SelectItem[] = [];
  configRules: RuleConfig[] = [];
  attackRuleMapping: AttackRuleMapping[] = [];

  selectedAttackCluster = '';
  selectedApp = '';
  selectedAttack = '';
  selectedScaleCluster = '';

  loading = false;
  podsLoading = false;
  rulesLoading = false;
  scaleLoading = false;

  lastTriggeredFalcoRule = '';
  lastTriggeredAt?: Date;
  lastTriggeredDetail = '';
  lastTriggeredTargetUrl = '';
  lastTriggeredCluster = '';
  lastTriggeredPodName = '';

  private appOptions: VulnAppOption[] = [];
  private destroy$ = new Subject<void>();

  constructor(
    private k8sService: K8sService,
    private simulationService: SimulationService,
    private configService: ConfigService,
    private messageService: MessageService
  ) {}

  ngOnInit(): void {
    this.attackType = [
      { label: 'Reverse shell', value: 'reverse_shell' },
      { label: 'Data destruction', value: 'data_destruction' },
      { label: 'Log file removal', value: 'log_removal' }
    ];
    this.loadClusters();
    this.loadAttackRuleMapping();
    this.loadConfigRules();
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  private loadClusters(): void {
    this.k8sService.getClusters().pipe(
      take(1),
      catchError(() => of({ clusters: [] as string[] }))
    ).subscribe((response) => {
      const items = (response.clusters || []).map((cluster) => ({
        label: cluster,
        value: cluster
      } as SelectItem));
      this.clusterSelection = items;
      this.attackClusterSelection = items;

      if (!this.selectedScaleCluster && items.length > 0) {
        this.selectedScaleCluster = String(items[0].value);
      }
      if (!this.selectedAttackCluster) {
        const preferred = items.find((item) => item.value === 'cluster1') ?? items[0];
        if (preferred) {
          this.selectedAttackCluster = String(preferred.value);
          this.loadPodsForAttackCluster();
        }
      }
    });
  }

  public onAttackClusterChange(): void {
    this.selectedApp = '';
    this.targetPod = [];
    this.appOptions = [];
    this.loadPodsForAttackCluster();
  }

  private loadPodsForAttackCluster(): void {
    const cluster = this.selectedAttackCluster;
    if (!cluster) {
      this.targetPod = [];
      this.appOptions = [];
      return;
    }

    this.podsLoading = true;
    const namespaces = ['istio-enabled', 'default'];
    forkJoin(
      namespaces.map((namespace) =>
        this.k8sService.getPods(cluster, namespace).pipe(
          map((podResponse: PodsResponse) => ({ namespace, pods: podResponse.pods || [] })),
          catchError(() => of({ namespace, pods: [] as Pod[] }))
        )
      )
    ).pipe(
      take(1),
      finalize(() => {
        this.podsLoading = false;
      })
    ).subscribe((perNamespace) => {
      const options: VulnAppOption[] = [];
      const seen = new Set<string>();
      for (const { namespace, pods } of perNamespace) {
        for (const pod of pods) {
          const appName = (pod.appName || '').trim();
          if (!(appName.startsWith('vuln-spring') || appName.startsWith('vuln-redis')) || pod.status !== 'Running') {
            continue;
          }
          if (seen.has(appName)) {
            continue;
          }
          seen.add(appName);
          options.push({
            appName,
            podName: pod.podName || '',
            namespace
          });
        }
      }
      options.sort((a, b) => a.appName.localeCompare(b.appName));
      this.appOptions = options;
      this.targetPod = options.map((option) => ({
        label: `${option.appName} (${option.namespace})`,
        value: option.appName
      } as SelectItem));
    });
  }

  public reset(): void {
    this.selectedApp = '';
    this.selectedAttack = '';
  }

  public simulateAttack(): void {
    if (!(this.selectedApp.startsWith('vuln-spring') || this.selectedApp.startsWith('vuln-redis'))) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Unsupported app',
        detail: `Attack simulation currently supports only vuln-spring and vuln-redis apps. Use Migration tab for ${this.selectedApp}.`
      });
      return;
    }
    if (!this.selectedAttackCluster) {
      this.messageService.add({
        key: 'tst',
        severity: 'warn',
        summary: 'Cluster required',
        detail: 'Please select the cluster where the target app runs.'
      });
      return;
    }

    const matchedApp = this.appOptions.find((option) => option.appName === this.selectedApp);
    const namespace = matchedApp?.namespace;

    this.loading = true;
    this.simulationService.triggerSimulation(
      this.selectedApp,
      this.selectedAttack,
      this.selectedAttackCluster,
      namespace
    ).pipe(
      take(1),
      takeUntil(this.destroy$),
      tap((response: SimulationResponse) => {
        this.loading = false;
        this.lastTriggeredFalcoRule = response.falcoRule;
        this.lastTriggeredAt = new Date();
        this.lastTriggeredDetail = response.detail;
        this.lastTriggeredTargetUrl = response.targetUrl || '';
        this.lastTriggeredCluster = response.cluster || this.selectedAttackCluster;
        this.lastTriggeredPodName = response.podName || matchedApp?.podName || '';
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'Attack triggered',
          detail: `${response.message}. Falco should now raise '${response.falcoRule}'.`
        });
        this.reset();
        this.loadConfigRules();
      }),
      catchError((error: any) => {
        this.loading = false;
        const detail = error?.error?.detail || `Failed to trigger attack on ${this.selectedApp}`;
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Error', detail });
        return of(error);
      })
    ).subscribe();
  }

  private loadAttackRuleMapping(): void {
    this.simulationService.getAttackRuleMapping().pipe(
      take(1),
      catchError(() => of([] as AttackRuleMapping[]))
    ).subscribe((mapping) => {
      this.attackRuleMapping = mapping;
    });
  }

  public loadConfigRules(): void {
    this.rulesLoading = true;
    this.configService.getConfig().pipe(
      take(1),
      catchError(() => of([] as RuleConfig[])),
      finalize(() => {
        this.rulesLoading = false;
      })
    ).subscribe((rules) => {
      this.configRules = rules;
    });
  }

  public get expectedFalcoRule(): string {
    if (!this.selectedAttack) {
      return '';
    }
    const found = this.attackRuleMapping.find((entry) => entry.attackType === this.selectedAttack);
    return found?.falcoRule || '';
  }

  public isRuleMatchingSelectedAttack(rule: RuleConfig): boolean {
    const expected = this.expectedFalcoRule;
    if (!expected || rule.rule !== expected) {
      return false;
    }
    if (this.selectedAttackCluster && rule.cluster) {
      return rule.cluster === this.selectedAttackCluster;
    }
    return true;
  }

  public scaleVulnSpring(replicas: number): void {
    if (!this.selectedScaleCluster) {
      this.messageService.add({ key: 'tst', severity: 'warn', summary: 'Scale', detail: 'Please select a cluster first.' });
      return;
    }
    this.scaleLoading = true;
    this.k8sService.scaleVulnSpring(this.selectedScaleCluster, replicas).pipe(
      take(1),
      finalize(() => {
        this.scaleLoading = false;
      })
    ).subscribe({
      next: (response) => {
        this.messageService.add({
          key: 'tst',
          severity: 'success',
          summary: 'Scale',
          detail: response.message || `Scaled vuln-spring to replicas=${replicas}`
        });
      },
      error: (error) => {
        const detail = error?.error?.detail || 'Failed to scale vuln-spring';
        this.messageService.add({ key: 'tst', severity: 'error', summary: 'Scale', detail });
      }
    });
  }
}
