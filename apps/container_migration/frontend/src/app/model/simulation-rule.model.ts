export interface SimulationRule {
    name: string;
    enabled: boolean;
    appNamePattern: string;
    attackTypes: string[];
    sourceCluster: string;
    targetCluster: string;
    namespace: string;
    registryAddress?: string | null;
    forensicAnalysis: boolean;
    AISuggestion: boolean;
    disableIstioSidecar: boolean;
    skipCpuCompatCheck: boolean;
    cleanupIncompatibleMounts: boolean;
}

export interface SimulationRulesResponse {
    rules: SimulationRule[];
}
