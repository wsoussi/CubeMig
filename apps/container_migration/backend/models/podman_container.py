from typing import List, Optional
from pydantic import BaseModel

class PodmanContainer(BaseModel):
    containerName: str
    containerID: str
    image: str
    status: str
    environment: str  # Either "SEV-SNP" or "Normal"

class PodmanContainersResponse(BaseModel):
    normal_containers: List[PodmanContainer] = []
    sevsnp_containers: List[PodmanContainer] = []
    error: Optional[str] = None
