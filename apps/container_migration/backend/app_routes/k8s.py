from datetime import datetime, timedelta, timezone
import json
import subprocess
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from utils.k8s_client import k8s_client

router = APIRouter()

ROUTING_DEMO_VS_NAME = "routing-demo"
ROUTING_DEMO_NAMESPACE = "istio-enabled"
ROUTING_DEMO_SUBSET_JSON_PATH = "/spec/http/0/route/0/destination/subset"


class RoutingDemoTrafficClusterBody(BaseModel):
    cluster: str = Field(..., description="Kube context where the VirtualService routing-demo is patched")


def _kubectl(cluster: str, args: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", "--context", cluster, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _require_cluster(cluster: str):
    if not k8s_client.has_cluster(cluster):
        raise HTTPException(status_code=400, detail=f"Unknown cluster context: {cluster}")

@router.get("/clusters")
async def get_clusters():
    return {"clusters": k8s_client.list_clusters()}

@router.get("/pods/{cluster}/{namespace}")
async def get_pods(cluster: str, namespace: str):
    """Get a list of pods in the specified Kubernetes namespace"""
    try:
        client = k8s_client.get_client(cluster)
        pods = client.list_namespaced_pod(namespace=namespace)
        podsList = []
        for pod in pods.items:
            # Safely handle the case where pod.metadata.labels might be None
            labels = pod.metadata.labels or {}
            pod_info = dict({
                "podName": pod.metadata.name, 
                "appName": labels.get('app', 'N/A'), 
                "status": pod.status.phase,
                "age": format_age(datetime.now(timezone.utc) - pod.metadata.creation_timestamp)
            })

            if pod.status.phase == "Pending" and pod.status.container_statuses:
                waiting_reason = pod.status.container_statuses[0].state.waiting.reason if pod.status.container_statuses[0].state.waiting else "Unknown"
                pod_info.update({"reason": waiting_reason})
            
            podsList.append(pod_info)
        
        return {"pods": podsList}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error fetching pods: {str(e)}")

@router.delete("/pods/{cluster}/{namespace}/{pod_name}")
async def delete_pod(cluster: str, namespace: str, pod_name: str):
    """Delete a Kubernetes pod by its name."""
    try:
        client = k8s_client.get_client(cluster)
        response = client.delete_namespaced_pod(
            name=pod_name,
            namespace=namespace
        )
        return {
            "message": f"Pod '{pod_name}' deleted successfully in cluster '{cluster}'"
        }
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        # Handle Kubernetes API exceptions
        raise HTTPException(
            status_code=500,
            detail=f"Failed to delete pod '{pod_name}' in namespace {namespace} in cluster '{cluster}': {str(e)}",
        )


@router.get("/routing-demo/traffic-subset/{cluster}")
async def get_routing_demo_traffic_subset(cluster: str):
    """Return the primary /whoami route subset (v1 or v2) for VirtualService routing-demo."""
    _require_cluster(cluster)
    proc = _kubectl(
        cluster,
        [
            "get",
            "virtualservice",
            ROUTING_DEMO_VS_NAME,
            "-n",
            ROUTING_DEMO_NAMESPACE,
            "-o",
            f"jsonpath={{.spec.http[0].route[0].destination.subset}}",
        ],
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=404,
            detail=(proc.stderr or proc.stdout or "kubectl failed").strip(),
        )
    subset = (proc.stdout or "").strip()
    return {"cluster": cluster, "subset": subset}


@router.post("/routing-demo/toggle-traffic")
async def toggle_routing_demo_traffic(body: RoutingDemoTrafficClusterBody):
    """Flip primary route subset between v1 and v2 (same JSON patch as single-migration traffic switch)."""
    cluster = body.cluster
    _require_cluster(cluster)

    get_proc = _kubectl(
        cluster,
        [
            "get",
            "virtualservice",
            ROUTING_DEMO_VS_NAME,
            "-n",
            ROUTING_DEMO_NAMESPACE,
            "-o",
            f"jsonpath={{.spec.http[0].route[0].destination.subset}}",
        ],
    )
    if get_proc.returncode != 0:
        raise HTTPException(
            status_code=404,
            detail=(get_proc.stderr or get_proc.stdout or "VirtualService not found").strip(),
        )
    current = (get_proc.stdout or "").strip()
    if current == "v1":
        new_subset = "v2"
    elif current == "v2":
        new_subset = "v1"
    else:
        raise HTTPException(
            status_code=400,
            detail=f"Current subset is {current!r}; only v1 and v2 are supported for toggle.",
        )

    patch = [
        {
            "op": "replace",
            "path": ROUTING_DEMO_SUBSET_JSON_PATH,
            "value": new_subset,
        }
    ]
    patch_proc = _kubectl(
        cluster,
        [
            "patch",
            "virtualservice",
            ROUTING_DEMO_VS_NAME,
            "-n",
            ROUTING_DEMO_NAMESPACE,
            "--type=json",
            "-p",
            json.dumps(patch),
        ],
    )
    if patch_proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(patch_proc.stderr or patch_proc.stdout or "patch failed").strip(),
        )

    return {
        "cluster": cluster,
        "previous_subset": current,
        "subset": new_subset,
        "message": f"VirtualService {ROUTING_DEMO_VS_NAME} primary route is now {new_subset}",
    }


def format_age(age: timedelta) -> str:
    days = age.days
    seconds = age.seconds
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60

    if days > 0:
        if hours > 0:
            return f"{days}d{hours}h"
        else:
            return f"{days}d"
    elif hours > 0:
        return f"{hours}h{minutes}m"
    else:
        return f"{minutes}m"
