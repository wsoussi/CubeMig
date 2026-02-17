export interface MigrationRequest {
    sourceCluster: string;
    targetCluster: string;
    namespace: string;
    podName: string;
    appName: string;
    forensicAnalysis: boolean;
    AISuggestion: boolean;
}