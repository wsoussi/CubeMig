export interface RuleConfig {
    rule: string;
    cluster: string;
    action: string;
    targetCluster?: string | null;
    forensic_analysis: boolean;
    AI_suggestion: boolean;
    registry_address?: string | null;
    istio_routing_context?: string | null;
    disable_istio_sidecar?: boolean;
    skip_cpu_compat_check?: boolean;
    cleanup_incompatible_mounts?: boolean;
}

export interface Config {
    config: RuleConfig[];
}
