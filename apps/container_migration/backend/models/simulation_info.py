from typing import Optional
from pydantic import BaseModel

class SimulationInfo(BaseModel):
     appName: Optional[str] = None
     attackType: Optional[str] = None
     cluster: Optional[str] = None
     namespace: Optional[str] = None