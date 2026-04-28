from typing import Optional
from pydantic import BaseModel

class MigrationInfo(BaseModel):
     hostname: Optional[str] = None
     rule: Optional[str] = None
     k8s_pod_name: Optional[str] = None
     container_name: Optional[str] = None
     migration_type: Optional[str] = None
     source_cluster: Optional[str] = None
     target_cluster: Optional[str] = None
     namespace: Optional[str] = None
     registry_address: Optional[str] = None
     forensic_analysis: Optional[bool] = None
     AI_suggestion: Optional[bool] = None
     disable_istio_sidecar: Optional[bool] = None
     timestamp: Optional[str] = None