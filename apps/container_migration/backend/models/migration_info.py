from typing import Optional
from pydantic import BaseModel

class MigrationInfo(BaseModel):
     hostname: Optional[str] = None
     rule: Optional[str] = None
     k8s_pod_name: Optional[str]
     container_name: Optional[str]
     migration_type: Optional[str]
     forensic_analysis: Optional[bool] = None
     AI_suggestion: Optional[bool] = None
     timestamp: Optional[str] = None