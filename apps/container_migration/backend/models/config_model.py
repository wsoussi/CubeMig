from pydantic import BaseModel
from typing import List, Optional

class RuleConfig(BaseModel):
    rule: str
    cluster: str
    action: str
    targetCluster: Optional[str] = None
    forensic_analysis: Optional[bool] = False
    AI_suggestion: Optional[bool] = False
    registry_address: Optional[str] = None
    disable_istio_sidecar: Optional[bool] = False
    skip_cpu_compat_check: Optional[bool] = False
    cleanup_incompatible_mounts: Optional[bool] = False

class Config(BaseModel):
    config: List[RuleConfig]