from datetime import datetime, timedelta, timezone
from typing import Any
import json
import subprocess
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from utils.k8s_client import k8s_client

router = APIRouter()

ROUTING_DEMO_VS_NAME = "routing-demo"
ROUTING_DEMO_NAMESPACE = "istio-enabled"
ROUTING_DEMO_SUBSET_JSON_PATH = "/spec/http/0/route/0/destination/subset"
ROUTING_DEMO_FAULT_JSON_PATH = "/spec/http/0/fault"


class RoutingDemoTrafficClusterBody(BaseModel):
    cluster: str = Field(..., description="Kube context where the VirtualService routing-demo is patched")


class RoutingDemoScaleBody(BaseModel):
    cluster: str = Field(..., description="Kube context where deployment routing-demo should be scaled")
    replicas: int = Field(1, ge=0, le=20, description="Target replicas for deployment routing-demo")


class HttpProbeBody(BaseModel):
    url: str = Field(..., description="Target URL for backend curl probe")
    connect_timeout_s: float = Field(2.0, ge=0.1, le=30.0, description="Curl connect timeout in seconds")
    max_time_s: float = Field(10.0, ge=0.5, le=60.0, description="Curl max runtime in seconds")


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
def get_clusters():
    return {"clusters": k8s_client.list_clusters()}


# Use sync `def` (not `async def`) for blocking K8s/subprocess calls so FastAPI runs them in a
# threadpool and does not stall the event loop — parallel pod lists stay responsive.


@router.get("/pods/{cluster}/{namespace}")
def get_pods(cluster: str, namespace: str):
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
def delete_pod(cluster: str, namespace: str, pod_name: str):
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
def get_routing_demo_traffic_subset(cluster: str):
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
def toggle_routing_demo_traffic(body: RoutingDemoTrafficClusterBody):
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


@router.post("/routing-demo/clear-fault")
def clear_routing_demo_fault(body: RoutingDemoTrafficClusterBody):
    """Remove Istio fault.abort (pre-checkpoint HTTP 503) from VirtualService routing-demo http[0]."""
    cluster = body.cluster
    _require_cluster(cluster)

    patch = [{"op": "remove", "path": ROUTING_DEMO_FAULT_JSON_PATH}]
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
    if patch_proc.returncode == 0:
        return {
            "cluster": cluster,
            "removed": True,
            "message": f"Removed fault filter from VirtualService {ROUTING_DEMO_VS_NAME} (primary /whoami route).",
        }

    err = ((patch_proc.stderr or "") + (patch_proc.stdout or "")).strip().lower()
    if (
        "nonexistent" in err
        or "non-existent" in err
        or "missing path" in err
        or "remove operation does not apply" in err
    ):
        return {
            "cluster": cluster,
            "removed": False,
            "message": "No fault filter was set on the VirtualService (nothing to remove).",
        }

    raise HTTPException(
        status_code=500,
        detail=(patch_proc.stderr or patch_proc.stdout or "patch failed").strip(),
    )


@router.post("/routing-demo/scale")
def scale_routing_demo(body: RoutingDemoScaleBody):
    """Scale deployment routing-demo (default replicas=1) in istio-enabled namespace."""
    cluster = body.cluster
    _require_cluster(cluster)

    proc = _kubectl(
        cluster,
        [
            "scale",
            "deploy",
            ROUTING_DEMO_VS_NAME,
            "-n",
            ROUTING_DEMO_NAMESPACE,
            f"--replicas={body.replicas}",
        ],
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=(proc.stderr or proc.stdout or "kubectl scale failed").strip(),
        )

    return {
        "cluster": cluster,
        "deployment": ROUTING_DEMO_VS_NAME,
        "namespace": ROUTING_DEMO_NAMESPACE,
        "replicas": body.replicas,
        "message": f"Scaled deployment {ROUTING_DEMO_VS_NAME} to replicas={body.replicas} in {cluster}",
    }


@router.post("/http-probe")
def run_http_probe(body: HttpProbeBody):
    """Run a backend-side curl probe and return response metadata plus body/stdout."""
    cmd = [
        "curl",
        "-sS",
        "-o",
        "-",
        "-w",
        "\nhttp=%{http_code} total_s=%{time_total}",
        "--connect-timeout",
        str(body.connect_timeout_s),
        "--max-time",
        str(body.max_time_s),
        body.url,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=int(body.max_time_s + 2), check=False)
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail=f"Curl probe timed out after {body.max_time_s}s")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to execute curl probe: {str(exc)}")

    stdout = proc.stdout or ""
    stderr = (proc.stderr or "").strip()
    output_lines = stdout.splitlines()
    metrics_line = output_lines[-1] if output_lines else ""
    body_output = "\n".join(output_lines[:-1]) if len(output_lines) > 1 else (output_lines[0] if output_lines and not metrics_line.startswith("http=") else "")

    http_code = 0
    total_s = 0.0
    if metrics_line.startswith("http="):
        parts = metrics_line.split()
        for p in parts:
            if p.startswith("http="):
                try:
                    http_code = int(p.replace("http=", "").strip())
                except ValueError:
                    http_code = 0
            if p.startswith("total_s="):
                try:
                    total_s = float(p.replace("total_s=", "").strip())
                except ValueError:
                    total_s = 0.0

    parsed_json: Any = None
    counter: int | None = None
    if body_output:
        try:
            parsed_json = json.loads(body_output)
            if isinstance(parsed_json, dict):
                raw_counter = parsed_json.get("counter")
                if isinstance(raw_counter, int):
                    counter = raw_counter
        except Exception:
            parsed_json = None

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "url": body.url,
        "http_code": http_code,
        "total_s": total_s,
        "total_ms": round(total_s * 1000.0, 2),
        "ok": proc.returncode == 0 and 200 <= http_code < 400,
        "stdout": body_output,
        "stdout_json": parsed_json,
        "counter": counter,
        "stderr": stderr,
        "exit_code": proc.returncode,
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
