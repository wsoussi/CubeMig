export interface MigrationRequest {
    sourceCluster: string;
    targetCluster: string;
    namespace: string;
    podName: string;
    appName: string;
    registryAddress: string;
    forensicAnalysis: boolean;
    AISuggestion: boolean;
    disableIstioSidecar: boolean;
}