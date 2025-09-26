from typing import Optional
from pydantic import BaseModel

class TeeOperationInfo(BaseModel):
     containerName: Optional[str] = None
     operation: Optional[str] = None  # 'encapsulate' or 'decapsulate'
