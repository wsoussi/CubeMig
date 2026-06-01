export interface MigrationRequest {
    sourceCluster: string;
    targetCluster: string;
    namespace: string;
    podName: string;
    appName: string;
    registryAddress: string;
    istioRoutingContext: string;
    forensicAnalysis: boolean;
    AISuggestion: boolean;
    disableIstioSidecar: boolean;
    skipCpuCompatCheck: boolean;
    cleanupIncompatibleMounts: boolean;
}
