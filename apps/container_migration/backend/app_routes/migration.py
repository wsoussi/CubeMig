from fastapi import APIRouter, HTTPException
from datetime import datetime
import json
import os
import asyncio
import re
from pathlib import Path
from pydantic import BaseModel
from models.migration_info import MigrationInfo
from models.alert_model import Alert
from utils.migration_util import load_config
from utils.k8s_client import k8s_client
from kubernetes.client.rest import ApiException
import pytz

router = APIRouter()

triggeredMigrations = []
activeMigrations: dict[str, str] = {}
base_log_path = "/home/ubuntu/contMigration_logs"
config = load_config()
timezone = pytz.timezone('Europe/Berlin')

class ManualMigrationRequest(BaseModel):
    sourceCluster: str
    targetCluster: str
    namespace: str
    podName: str
    appName: str
    registryAddress: str | None = None
    istioRoutingContext: str = "cluster1"
    forensicAnalysis: bool = False
    AISuggestion: bool = False
    disableIstioSidecar: bool = False
    skipCpuCompatCheck: bool = False
    cleanupIncompatibleMounts: bool = False

def _validate_cluster_pair(source_cluster: str, target_cluster: str):
    if not source_cluster or not target_cluster:
        raise HTTPException(status_code=400, detail="sourceCluster and targetCluster are required")
    if source_cluster == target_cluster:
        raise HTTPException(status_code=400, detail="sourceCluster and targetCluster must be different")
    if not k8s_client.has_cluster(source_cluster):
        raise HTTPException(status_code=400, detail=f"Unknown source cluster: {source_cluster}")
    if not k8s_client.has_cluster(target_cluster):
        raise HTTPException(status_code=400, detail=f"Unknown target cluster: {target_cluster}")

def _validate_istio_routing_context(istio_routing_context: str):
    if not istio_routing_context:
        raise HTTPException(status_code=400, detail="istioRoutingContext is required")
    if not k8s_client.has_cluster(istio_routing_context):
        raise HTTPException(status_code=400, detail=f"Unknown Istio routing context: {istio_routing_context}")

def _clusters_with_pod(pod_name: str, namespace: str) -> list[str]:
    """Return kube contexts where the pod exists in the given namespace."""
    pod_name = (pod_name or "").strip()
    namespace = (namespace or "default").strip()
    if not pod_name:
        return []
    found: list[str] = []
    for cluster_name in k8s_client.list_clusters():
        try:
            api = k8s_client.get_client(cluster_name)
            api.read_namespaced_pod(name=pod_name, namespace=namespace)
            found.append(cluster_name)
        except ApiException as exc:
            if exc.status != 404:
                print(f"Warning: pod lookup on {cluster_name}/{namespace}/{pod_name}: {exc}")
        except Exception as exc:
            print(f"Warning: pod lookup on {cluster_name}/{namespace}/{pod_name}: {exc}")
    return found

def _apply_rule_config_to_info(info: MigrationInfo, rule_config, namespace: str) -> None:
    info.source_cluster = rule_config.cluster
    info.target_cluster = rule_config.targetCluster
    info.namespace = namespace
    info.forensic_analysis = rule_config.forensic_analysis
    info.AI_suggestion = rule_config.AI_suggestion
    info.istio_routing_context = (rule_config.istio_routing_context or "cluster1").strip() or "cluster1"
    if rule_config.registry_address:
        info.registry_address = rule_config.registry_address.strip() or None
    if rule_config.disable_istio_sidecar:
        info.disable_istio_sidecar = True
    if rule_config.skip_cpu_compat_check:
        info.skip_cpu_compat_check = True
    if rule_config.cleanup_incompatible_mounts:
        info.cleanup_incompatible_mounts = True

def _extract_return_code(content: str):
    for line in content.splitlines():
        if line.startswith("Return code:"):
            value = line.split(":", 1)[1].strip()
            if value.isdigit():
                return int(value)
    return None

_LOG_LINE_TS = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+(.*)$"
)


def _file_has_timestamped_migration_lines(path: str, max_lines: int = 30) -> bool:
    """True when the file contains ISO8601 lines from single-migration.sh log()."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as file:
            for i, line in enumerate(file):
                if i >= max_lines:
                    break
                if _LOG_LINE_TS.match(line.strip()):
                    return True
    except OSError:
        return False
    return False


def _migration_log_file_path(log_path: str) -> str | None:
    """Prefer migration_log.txt; fall back to migration.log only when timestamped."""
    for name in ("migration_log.txt", "migration.log"):
        candidate = os.path.join(log_path, name)
        if os.path.isfile(candidate) and _file_has_timestamped_migration_lines(candidate):
            return candidate
    return None


def _read_migration_log_content_lines(log_path: str) -> list[str]:
    migration_log_file = _migration_log_file_path(log_path)
    if not migration_log_file:
        return []
    with open(migration_log_file, "r", encoding="utf-8", errors="replace") as file:
        return [line.rstrip("\n") for line in file.readlines()]


def _latest_progress_line(log_path: str):
    migration_log_file = _migration_log_file_path(log_path)
    if not migration_log_file:
        return None

    with open(migration_log_file, "r", encoding="utf-8", errors="replace") as file:
        lines = [line.strip() for line in file.readlines() if line.strip()]
    if not lines:
        return None
    return lines[-1]

def _recent_log_lines(log_path: str, line_count: int = 12):
    migration_log_file = _migration_log_file_path(log_path)
    if not migration_log_file:
        return []

    with open(migration_log_file, "r", encoding="utf-8", errors="replace") as file:
        lines = [line.rstrip("\n") for line in file.readlines() if line.strip()]
    if not lines:
        return []
    return lines[-line_count:]

def _full_log_lines(log_path: str):
    lines = _read_migration_log_content_lines(log_path)
    result_file = os.path.join(log_path, "migration_result.txt")
    error_file = os.path.join(log_path, "migration_error.txt")

    if os.path.exists(result_file):
        lines.append("")
        lines.append("----- migration_result.txt -----")
        with open(result_file, "r") as file:
            lines.extend([line.rstrip("\n") for line in file.readlines()])

    if os.path.exists(error_file):
        lines.append("")
        lines.append("----- migration_error.txt -----")
        with open(error_file, "r") as file:
            lines.extend([line.rstrip("\n") for line in file.readlines()])

    return lines


def _parse_log_timestamp_message(line: str):
    raw = (line or "").strip()
    if not raw:
        return None, ""
    m = _LOG_LINE_TS.match(raw)
    if not m:
        return None, raw
    ts_s, msg = m.group(1), m.group(2)
    try:
        ts_norm = ts_s.replace("Z", "+00:00")
        return datetime.fromisoformat(ts_norm), msg
    except ValueError:
        return None, raw


def _duration_ms_between_markers(log_lines, start_markers: tuple, end_markers: tuple):
    """First timestamped line matching any start_markers, then first subsequent line matching any end_markers."""
    start_ts = None
    start_idx = None
    for i, line in enumerate(log_lines):
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if any(m in msg for m in start_markers):
            start_ts, start_idx = ts, i
            break
    if start_ts is None or start_idx is None:
        return None
    for line in log_lines[start_idx + 1 :]:
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if any(m in msg for m in end_markers):
            return int((ts - start_ts).total_seconds() * 1000)
    return None


def _pipeline_check_duration_ms(log_lines):
    start_idx = None
    start_ts = None
    for i, line in enumerate(log_lines):
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if any(
            m in msg
            for m in ("Destination cluster checks started", "Global preflight checks started")
        ):
            if start_idx is None or i < start_idx:
                start_idx, start_ts = i, ts
    if start_ts is None or start_idx is None:
        return None
    for line in log_lines[start_idx + 1 :]:
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if any(
            m in msg
            for m in ("Global preflight checks completed", "Destination cluster checks completed")
        ):
            return int((ts - start_ts).total_seconds() * 1000)
    return None


def _downtime_ms_from_log(log_lines):
    """
    Time from source workload stop (post-checkpoint) until restore pod reports running.
    Requires ISO8601-prefixed log lines from single-migration.sh.
    """
    start_idx = None
    start_ts = None
    for i, line in enumerate(log_lines):
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if "--- Stopping source workload" in msg:
            start_idx, start_ts = i, ts
            break
    if start_ts is None:
        for i, line in enumerate(log_lines):
            ts, msg = _parse_log_timestamp_message(line)
            if ts is None:
                continue
            if "-- Scaled deployment" in msg and "0 replicas" in msg:
                start_idx, start_ts = i, ts
                break
    if start_ts is None or start_idx is None:
        return None
    for line in log_lines[start_idx + 1 :]:
        ts, msg = _parse_log_timestamp_message(line)
        if ts is None:
            continue
        if " is running --" in msg:
            return int((ts - start_ts).total_seconds() * 1000)
    return None


def _attach_stage_durations_ms(stages: list, log_lines: list):
    computers = {
        "pipeline_check": _pipeline_check_duration_ms,
        "dest_prep": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Destination preparation (pre-checkpoint) started",),
            ("-- Destination preparation (pre-checkpoint) completed",),
        ),
        "checkpoint": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Creating checkpoint for",),
            (
                "-- Checkpoint created --",
                "-- Latest checkpoint found:",
                "-- Permissions changed --",
            ),
        ),
        "source_stop_post_checkpoint": lambda lines: _duration_ms_between_markers(
            lines,
            (
                "-- Post-checkpoint: stop source workload",
                "--- Stopping source workload",
            ),
            ("-- Convert checkpoint into image",),
        ),
        "image": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Convert checkpoint into image",),
            ("-- Image pushed onto local registy", "-- Image pushed onto local registry"),
        ),
        "checkpoint_prepull": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Pre-pull step (checkpoint image) started",),
            (
                "-- Pre-pull step (checkpoint image) completed",
                "-- Pre-pull step (checkpoint image) skipped by feature flag",
            ),
        ),
        "restore": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Applying restore yaml file", '-- Waiting for the new pod'),
            (" is running --",),
        ),
        "traffic": lambda lines: _duration_ms_between_markers(
            lines,
            (
                "switching mirroring rule",
                "Switching traffic to the new pod",
                "-- No Istio VirtualService patch for this workload",
            ),
            ("-- Traffic switch step completed --", "Traffic switch skipped (restore pod not running)"),
        ),
        "cleanup": lambda lines: _duration_ms_between_markers(
            lines,
            ("-- Traffic switch step completed --", "Traffic switch skipped (restore pod not running)"),
            ("-- Source workload cleanup completed --",),
        ),
    }
    for st in stages:
        key = st.get("key")
        if key not in computers:
            continue
        ms = computers[key](log_lines)
        if ms is not None:
            st["duration_ms"] = ms


def _build_stage_statuses(log_lines, final_status: str):
    # Order matches single-migration.sh: checks → dest prep → checkpoint → **stop source on source**
    # (replicas 0 / delete) → image → optional checkpoint pre-pull → restore → traffic → finalize script.
    stages = [
        {"key": "pipeline_check", "label": "Pipeline checks", "status": "pending"},
        {
            "key": "dest_prep",
            "label": "Destination prep (pre-checkpoint)",
            "status": "pending",
        },
        {"key": "checkpoint", "label": "Checkpoint creation", "status": "pending"},
        {
            "key": "source_stop_post_checkpoint",
            "label": "Source scaled down (post-checkpoint)",
            "status": "pending",
        },
        {"key": "image", "label": "Image conversion and push", "status": "pending"},
        {
            "key": "checkpoint_prepull",
            "label": "Checkpoint image pre-pull (optional)",
            "status": "pending",
        },
        {"key": "restore", "label": "Restore pod startup", "status": "pending"},
        {"key": "traffic", "label": "Traffic switch", "status": "pending"},
        {"key": "cleanup", "label": "Migration finalize", "status": "pending"},
    ]

    joined = "\n".join(log_lines)

    if "Destination cluster checks started" in joined:
        stages[0]["status"] = "running"
    if "Global preflight checks started" in joined:
        stages[0]["status"] = "running"
    if "Global preflight checks completed" in joined or "Destination cluster checks completed" in joined:
        stages[0]["status"] = "completed"

    if "Destination preparation (pre-checkpoint) started" in joined:
        stages[1]["status"] = "running"
    if "Destination preparation (pre-checkpoint) completed" in joined:
        stages[1]["status"] = "completed"

    if "Creating checkpoint" in joined:
        stages[2]["status"] = "running"
    if (
        "-- Checkpoint created --" in joined
        or "-- Latest checkpoint found:" in joined
        or "-- Permissions changed --" in joined
    ):
        stages[2]["status"] = "completed"

    # First source stop (after durable checkpoint) happens before image build — not "final cleanup".
    if "-- Post-checkpoint: stop source workload" in joined or (
        "--- Stopping source workload" in joined and "Convert checkpoint into image" not in joined
    ):
        stages[3]["status"] = "running"
    if "Convert checkpoint into image" in joined or "Pushing image" in joined:
        stages[3]["status"] = "completed"

    if "Convert checkpoint into image" in joined or "Pushing image" in joined:
        stages[4]["status"] = "running"
    if "Image pushed onto local registy" in joined or "Image pushed onto local registry" in joined:
        stages[4]["status"] = "completed"

    if "Pre-pull step (checkpoint image) started" in joined:
        stages[5]["status"] = "running"
    if (
        "Pre-pull step (checkpoint image) completed" in joined
        or "Pre-pull step (checkpoint image) skipped by feature flag" in joined
    ):
        stages[5]["status"] = "completed"

    if "Applying restore yaml file" in joined or "Waiting for the new pod" in joined:
        stages[6]["status"] = "running"
    if " is running --" in joined:
        stages[6]["status"] = "completed"

    if "-- Traffic switch step completed --" in joined:
        stages[7]["status"] = "completed"
    elif "Traffic switch skipped (restore pod not running)" in joined:
        stages[7]["status"] = "completed"
    elif "switching mirroring rule" in joined or "Switching traffic to the new pod" in joined:
        stages[7]["status"] = "running"

    traffic_done = (
        "-- Traffic switch step completed --" in joined
        or "Traffic switch skipped (restore pod not running)" in joined
    )
    if traffic_done and "-- Source workload cleanup completed --" not in joined:
        stages[8]["status"] = "running"
    if "-- Source workload cleanup completed --" in joined:
        stages[8]["status"] = "completed"

    # Older migration logs (checkpoint before destination prep) lack dest_prep markers.
    if (
        final_status == "completed"
        and stages[1]["status"] == "pending"
        and "Destination preparation (pre-checkpoint)" not in joined
        and (
            "-- Checkpoint created --" in joined
            or "-- Latest checkpoint found:" in joined
            or "-- Post-checkpoint: stop source workload" in joined
        )
    ):
        stages[1]["status"] = "completed"

    if final_status == "error":
        for stage in reversed(stages):
            if stage["status"] == "running":
                stage["status"] = "failed"
                break
        else:
            for stage in reversed(stages):
                if stage["status"] == "completed":
                    stage["status"] = "failed"
                    break

    downtime_ms = _downtime_ms_from_log(log_lines)
    _attach_stage_durations_ms(stages, log_lines)

    return {"stage_statuses": stages, "downtime_ms": downtime_ms}

def _metadata_from_eval_json(log_path: str, metadata: dict) -> dict:
    """Fill cluster/namespace from evaluation metadata.json when the log is missing."""
    meta_file = os.path.join(log_path, "metadata.json")
    if not os.path.isfile(meta_file):
        return metadata
    try:
        meta = json.loads(Path(meta_file).read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return metadata
    if metadata.get("source_cluster") in (None, "", "unknown") and meta.get("source"):
        metadata["source_cluster"] = str(meta["source"])
    if metadata.get("target_cluster") in (None, "", "unknown") and meta.get("dest"):
        metadata["target_cluster"] = str(meta["dest"])
    if metadata.get("namespace") in (None, "", "unknown") and meta.get("namespace"):
        metadata["namespace"] = str(meta["namespace"])
    if metadata.get("target_pod_name") in (None, "", "unknown") and meta.get("pod"):
        metadata["target_pod_name"] = str(meta["pod"])
    return metadata


def _extract_log_metadata(log_path: str):
    metadata = {
        "source_cluster": "unknown",
        "target_cluster": "unknown",
        "namespace": "unknown",
        "target_pod_name": "unknown"
    }
    migration_log_file = _migration_log_file_path(log_path)
    if not migration_log_file:
        if _is_eval_run_log_dir(log_path):
            return _metadata_from_eval_json(log_path, metadata)
        return metadata

    with open(migration_log_file, "r", encoding="utf-8", errors="replace") as file:
        content = file.read()

    # Lines may be prefixed with UTC timestamps from log(); strip via shared parser.
    for line in content.splitlines():
        _, msg = _parse_log_timestamp_message(line)
        if msg.startswith("Source cluster:"):
            metadata["source_cluster"] = msg.split(":", 1)[1].strip()
        elif msg.startswith("Target cluster:"):
            metadata["target_cluster"] = msg.split(":", 1)[1].strip()
        elif msg.startswith("Namespace:"):
            metadata["namespace"] = msg.split(":", 1)[1].strip()

    target_pod_match = re.search(r'Waiting for the new pod "([^"]+)" to be ready', content)
    if target_pod_match:
        metadata["target_pod_name"] = target_pod_match.group(1).strip()

    return metadata

def _fetch_target_runtime_details(metadata: dict):
    details = {
        "target_node": "unknown",
        "recent_k8s_events": []
    }
    target_cluster = metadata.get("target_cluster")
    namespace = metadata.get("namespace")
    target_pod_name = metadata.get("target_pod_name")

    if not target_cluster or target_cluster == "unknown" or not namespace or namespace == "unknown" or not target_pod_name or target_pod_name == "unknown":
        return details

    try:
        client = k8s_client.get_client(target_cluster)
        pod = client.read_namespaced_pod(name=target_pod_name, namespace=namespace)
        if pod and pod.spec and pod.spec.node_name:
            details["target_node"] = pod.spec.node_name

        event_list = client.list_namespaced_event(namespace=namespace, field_selector=f"involvedObject.name={target_pod_name}")
        events = event_list.items if event_list and event_list.items else []
        events.sort(key=lambda event: event.last_timestamp or event.event_time or event.first_timestamp or datetime.min)
        trimmed = events[-8:]
        details["recent_k8s_events"] = [
            f"{event.type} {event.reason}: {event.message}"
            for event in trimmed
            if event.message
        ]
    except Exception:
        # Best-effort runtime details should never break status endpoint.
        return details

    return details

def _collect_recent_migrations(limit: int, offset: int):
    entries = []
    for container_dir in os.listdir(base_log_path):
        container_path = os.path.join(base_log_path, container_dir)
        if not os.path.isdir(container_path):
            continue

        for log_dir in os.listdir(container_path):
            log_path = os.path.join(container_path, log_dir)
            if not os.path.isdir(log_path):
                continue

            created_ts = os.path.getctime(log_path)
            result_file = os.path.join(log_path, "migration_result.txt")
            error_file = os.path.join(log_path, "migration_error.txt")
            full_log_lines = _full_log_lines(log_path)
            status = "running"
            summary = _latest_progress_line(log_path) or "Migration is still in progress"
            return_code = None

            if os.path.exists(result_file):
                with open(result_file, "r") as file:
                    content = file.read()
                return_code = _extract_return_code(content)
                if return_code == 0:
                    status = "completed"
                    summary = "Migration completed successfully"
                else:
                    status = "error"
                    summary = f"Migration failed with return code {return_code}" if return_code is not None else "Migration failed"
            elif os.path.exists(error_file):
                status = "error"
                with open(error_file, "r") as file:
                    first_line = file.readline().strip()
                summary = first_line or "Migration failed"

            if "_" in log_dir:
                _, pod_name = log_dir.split("_", 1)
            else:
                pod_name = log_dir
            metadata = _extract_log_metadata(log_path)
            built = _build_stage_statuses(full_log_lines, status)

            entries.append({
                "pod_name": pod_name,
                "app_name": container_dir,
                "source_cluster": metadata["source_cluster"],
                "target_cluster": metadata["target_cluster"],
                "namespace": metadata["namespace"],
                "target_pod_name": metadata["target_pod_name"],
                "status": status,
                "summary": summary,
                "log_path": log_path,
                "log_lines": full_log_lines,
                "return_code": return_code,
                "stage_statuses": built["stage_statuses"],
                "downtime_ms": built.get("downtime_ms"),
                "created_at": datetime.fromtimestamp(created_ts, tz=timezone).isoformat()
            })

    entries.sort(key=lambda item: item["created_at"], reverse=True)
    total = len(entries)
    paged_items = entries[offset:offset + limit]
    has_more = (offset + limit) < total
    return paged_items, total, has_more

@router.post("/alert")
async def handle_alerts(alert: Alert):
    reload_config()

    if not alert.output_fields:
        raise HTTPException(status_code=400, detail="output_fields required (k8s.pod.name, container.name)")

    pod_name = (alert.output_fields.k8s_pod_name or "").strip()
    if not pod_name:
        raise HTTPException(status_code=400, detail="output_fields.k8s.pod.name is required")

    namespace = (alert.output_fields.k8s_ns_name or "default").strip()
    container_name = alert.output_fields.container_name

    rule_name = (alert.rule or "").strip()
    if not rule_name:
        raise HTTPException(status_code=400, detail="rule is required")

    if pod_name in triggeredMigrations:
        return {
            "message": "No action taken",
            "detail": f"Migration already triggered for pod {pod_name} in this backend session",
        }

    info = MigrationInfo(
        hostname=alert.hostname,
        rule=rule_name,
        k8s_pod_name=pod_name,
        container_name=container_name,
        migration_type="automated",
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    )

    if info.rule != "PTRACE attached to process":
        falco_log_path = f"{base_log_path}/falco"
        os.makedirs(falco_log_path, exist_ok=True)
        with open(f"{falco_log_path}/alert.txt", "a") as file:
            file.write(f"Received alert: {info.rule} for pod: {pod_name} at {datetime.now(timezone)}\n")

    pod_clusters = _clusters_with_pod(pod_name, namespace)
    if not pod_clusters:
        print(f"No cluster found for pod {namespace}/{pod_name}; cannot select source cluster")
        return {"message": "No action taken", "detail": f"Pod {namespace}/{pod_name} not found on any configured cluster"}

    for rule_config in config.config:
        if rule_name != rule_config.rule:
            continue
        if rule_config.cluster not in pod_clusters:
            continue

        if rule_config.action == "migrate":
            _apply_rule_config_to_info(info, rule_config, namespace)
            _validate_cluster_pair(info.source_cluster, info.target_cluster)
            _validate_istio_routing_context(info.istio_routing_context or "cluster1")
            triggeredMigrations.append(pod_name)
            print(
                f"Triggering migration for pod {pod_name}: "
                f"{info.source_cluster} -> {info.target_cluster} (rule: {info.rule})"
            )
            return await trigger_migration(info)
        if rule_config.action == "log":
            print(f"Logging event for pod {pod_name} on {rule_config.cluster}")
            handle_log(info)
            return {"message": "Event logged"}

    configured_rules = sorted(
        {rc.rule for rc in config.config if rc.cluster in pod_clusters}
    )
    print(
        f"No matching config for rule '{rule_name}' on pod clusters {pod_clusters} "
        f"(namespace={namespace}); configured rules for these clusters: {configured_rules}"
    )
    return {
        "message": "No action taken",
        "detail": (
            f"Pod found on {pod_clusters}, but no config entry matches rule '{rule_name}' "
            f"with action migrate/log for that source cluster. "
            f"Available rules on {pod_clusters}: {configured_rules}"
        ),
    }

async def trigger_migration(info: MigrationInfo):
    pod_name = (info.k8s_pod_name or "").strip()
    if not pod_name:
        raise HTTPException(status_code=400, detail="k8s_pod_name is required")
    if pod_name in activeMigrations:
        return {
            "message": f"Migration already running for pod {pod_name}",
            "log_path": activeMigrations[pod_name],
            "already_running": True
        }

    log_path = f"{base_log_path}/{info.container_name}/{info.timestamp.replace(':', '-')}_{info.k8s_pod_name}"
    os.makedirs(log_path, exist_ok=True)
    with open(f"{log_path}/migration_log.txt", "w") as file:
        if info.migration_type == "automated":
            file.write(f"Migration log of automated container migration of {info.k8s_pod_name}\n")
            file.write(f"Migration is triggered because of falco rule of:\n{info.rule}\nreceived on {info.hostname}\n")
            file.write(f"Migration is triggered at {datetime.now(timezone)}\n\n")
        elif info.migration_type == "manual":
            file.write(f"Migration log of manual container migration of {info.k8s_pod_name}\n")
            file.write(f"Migration is triggered by user\n")
            file.write(f"Migration is triggered at {datetime.now(timezone)}\n\n")
    print(f"Forensic analysis: {info.forensic_analysis}")
    print(f"AI suggestion: {info.AI_suggestion}")

    activeMigrations[pod_name] = log_path
    # Start the migration process in the background
    asyncio.create_task(run_migration_script(info, log_path))
    
    return {"message": "Migration task has been started", "log_path": log_path}

async def run_migration_script(info: MigrationInfo, log_path: str):
    """Run the migration script asynchronously in the background"""
    print(info)
    try:
        cmd = ["/home/ubuntu/teemig/CubeMig/scripts/migration/single-migration.sh", info.k8s_pod_name, "--log-dir", log_path]
        if info.source_cluster:
            cmd.extend(["--source-cluster", info.source_cluster])
        if info.target_cluster:
            cmd.extend(["--dest-cluster", info.target_cluster])
        if info.namespace:
            cmd.extend(["--namespace", info.namespace])
        if info.registry_address:
            cmd.extend(["--registry", info.registry_address])
        if info.istio_routing_context:
            cmd.extend(["--istio-routing-context", info.istio_routing_context])
        if info.forensic_analysis:
            cmd.append("--forensic-analysis")
        if info.AI_suggestion:
            cmd.append("--ai-suggestion")
        if info.disable_istio_sidecar:
            cmd.append("--disable-istio-sidecar")
        if info.skip_cpu_compat_check:
            cmd.append("--skip-cpu-compat-check")
        if info.cleanup_incompatible_mounts:
            cmd.append("--cleanup-incompatible-mounts")
        else:
            cmd.append("--skip-checkpoint-normalization")
    
        # Run the subprocess asynchronously
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            stdin=asyncio.subprocess.DEVNULL
        )
        
        stdout, stderr = await process.communicate()
        
        # Log the results
        with open(f"{log_path}/migration_result.txt", "w") as file:
            file.write(f"Migration completed at {datetime.now(timezone)}\n")
            file.write(f"Return code: {process.returncode}\n")
            if stdout:
                file.write(f"STDOUT:\n{stdout.decode()}\n")
            if stderr:
                file.write(f"STDERR:\n{stderr.decode()}\n")
        
        if process.returncode == 0:
            print(f"Migration of {info.k8s_pod_name} completed successfully")
        else:
            print(f"Migration of {info.k8s_pod_name} failed with return code {process.returncode}")
            
    except Exception as e:
        # Log any errors that occur during migration
        with open(f"{log_path}/migration_error.txt", "w") as file:
            file.write(f"Migration error at {datetime.now(timezone)}\n")
            file.write(f"Error: {str(e)}\n")
        print(f"Error during migration of {info.k8s_pod_name}: {str(e)}")
    finally:
        pod_name = (info.k8s_pod_name or "").strip()
        if pod_name and activeMigrations.get(pod_name) == log_path:
            activeMigrations.pop(pod_name, None)

def handle_log(info: MigrationInfo):
    log_path = f"{base_log_path}/{info.container_name}/{info.timestamp.replace(':', '-')}_{info.k8s_pod_name}"
    os.makedirs(log_path, exist_ok=True)
    log_file = os.path.join(log_path, "event_log.txt")
    if not os.path.exists(log_file):
        with open(log_file, "w") as file:
            file.write(f"Log of events generated by Falco on {info.k8s_pod_name}\n")
            file.write(f"{datetime.now(timezone)}: Event received. Rule: {info.rule}\n")
    else:
        with open(log_file, "a") as file:
            file.write(f"{datetime.now(timezone)}: Event received. Rule: {info.rule}\n")

def _find_cont_migration_log_for_pod(pod_name: str) -> str | None:
    """Newest log directory under contMigration_logs whose folder name contains pod_name."""
    pod_logs: list[tuple[str, float]] = []
    if not os.path.isdir(base_log_path):
        return None
    for container_dir in os.listdir(base_log_path):
        container_path = os.path.join(base_log_path, container_dir)
        if not os.path.isdir(container_path):
            continue
        for log_dir in os.listdir(container_path):
            if pod_name not in log_dir:
                continue
            log_path = os.path.join(container_path, log_dir)
            if os.path.isdir(log_path):
                pod_logs.append((log_path, os.path.getctime(log_path)))
    if not pod_logs:
        return None
    return max(pod_logs, key=lambda item: item[1])[0]


def _find_eval_log_dir_for_pod(pod_name: str) -> str | None:
    """Newest evaluation run directory for this pod (metadata.json match)."""
    eval_root = Path(os.getenv("EVALUATION_OUT_ROOT", "/home/ubuntu/evaluation-runs"))
    if not eval_root.is_dir():
        return None
    best_dir: str | None = None
    best_mtime = 0.0
    for meta_file in eval_root.glob("*/*/metadata.json"):
        try:
            data = json.loads(meta_file.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        if data.get("pod") != pod_name:
            continue
        mtime = meta_file.stat().st_mtime
        if mtime > best_mtime:
            best_mtime = mtime
            best_dir = str(meta_file.parent)
    return best_dir


def _resolve_log_path_for_pod(pod_name: str) -> str | None:
    """Prefer in-flight migration, then newest eval run, then contMigration_logs."""
    if pod_name in activeMigrations:
        return activeMigrations[pod_name]

    try:
        from app_routes.evaluation import active_eval_runs

        for info in active_eval_runs.values():
            if info.get("pod") == pod_name and info.get("run_dir"):
                return str(info["run_dir"])
    except Exception:
        pass

    eval_dir = _find_eval_log_dir_for_pod(pod_name)
    cont_dir = _find_cont_migration_log_for_pod(pod_name)
    if eval_dir and cont_dir:
        eval_has_log = _migration_log_file_path(eval_dir) is not None
        cont_has_log = _migration_log_file_path(cont_dir) is not None
        if eval_has_log and not cont_has_log:
            return eval_dir
        if cont_has_log and not eval_has_log:
            return cont_dir
        eval_mtime = os.path.getmtime(eval_dir)
        cont_mtime = os.path.getmtime(cont_dir)
        return eval_dir if eval_mtime >= cont_mtime else cont_dir
    return eval_dir or cont_dir


def _is_eval_run_log_dir(log_path: str) -> bool:
    eval_root = os.path.abspath(os.getenv("EVALUATION_OUT_ROOT", "/home/ubuntu/evaluation-runs"))
    return os.path.abspath(log_path).startswith(eval_root + os.sep)


def _status_from_eval_run_dir(log_path: str):
    """Build migration-status payload from an evaluation-runs directory."""
    metadata = _metadata_from_eval_json(log_path, _extract_log_metadata(log_path))
    runtime_details = _fetch_target_runtime_details(metadata)
    full_log_lines = _full_log_lines(log_path)

    exit_code: int | None = None
    meta_file = os.path.join(log_path, "metadata.json")
    if os.path.isfile(meta_file):
        try:
            meta = json.loads(Path(meta_file).read_text(encoding="utf-8", errors="replace"))
            raw_ec = meta.get("exit_code")
            if raw_ec is not None and str(raw_ec) not in ("", "-1"):
                exit_code = int(raw_ec)
        except Exception:
            exit_code = None

    if exit_code is None:
        built = _build_stage_statuses(full_log_lines, "running")
        progress = _latest_progress_line(log_path)
        return {
            "status": "running",
            "log_path": log_path,
            "message": progress or "Evaluation migration in progress",
            "recent_log_lines": _recent_log_lines(log_path),
            "log_lines": full_log_lines,
            "stage_statuses": built["stage_statuses"],
            "downtime_ms": built.get("downtime_ms"),
            **runtime_details,
            **metadata,
        }

    if exit_code == 0:
        built = _build_stage_statuses(full_log_lines, "completed")
        return {
            "status": "completed",
            "log_path": log_path,
            "return_code": exit_code,
            "recent_log_lines": _recent_log_lines(log_path),
            "log_lines": full_log_lines,
            "stage_statuses": built["stage_statuses"],
            "downtime_ms": built.get("downtime_ms"),
            **runtime_details,
            **metadata,
        }

    built = _build_stage_statuses(full_log_lines, "error")
    return {
        "status": "error",
        "log_path": log_path,
        "error": f"Evaluation migration failed with exit code {exit_code}",
        "return_code": exit_code,
        "recent_log_lines": _recent_log_lines(log_path),
        "log_lines": full_log_lines,
        "stage_statuses": built["stage_statuses"],
        "downtime_ms": built.get("downtime_ms"),
        **runtime_details,
        **metadata,
    }


@router.post("/migrate")
async def migrate_pod(body: ManualMigrationRequest):
    _validate_cluster_pair(body.sourceCluster, body.targetCluster)
    istio_routing_context = (body.istioRoutingContext or "cluster1").strip() or "cluster1"
    _validate_istio_routing_context(istio_routing_context)
    
    info = MigrationInfo(
        k8s_pod_name=body.podName,
        container_name=body.appName,
        migration_type="manual",
        source_cluster=body.sourceCluster,
        target_cluster=body.targetCluster,
        namespace=body.namespace,
        registry_address=(body.registryAddress or "").strip() or None,
        istio_routing_context=istio_routing_context,
        forensic_analysis=body.forensicAnalysis,
        AI_suggestion=body.AISuggestion,
        disable_istio_sidecar=body.disableIstioSidecar,
        skip_cpu_compat_check=body.skipCpuCompatCheck,
        cleanup_incompatible_mounts=body.cleanupIncompatibleMounts,
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    )
    return await trigger_migration(info)

@router.get("/migration-status/{pod_name}")
def get_migration_status(pod_name: str):
    """Get the status of a migration by checking the log files"""
    try:
        latest_log_path = _resolve_log_path_for_pod(pod_name)
        if not latest_log_path:
            return {"status": "not_found", "message": f"No migration logs found for pod {pod_name}"}

        if _is_eval_run_log_dir(latest_log_path):
            return _status_from_eval_run_dir(latest_log_path)
        metadata = _extract_log_metadata(latest_log_path)
        runtime_details = _fetch_target_runtime_details(metadata)
        full_log_lines = _full_log_lines(latest_log_path)
        
        # Check for completion indicators
        result_file = os.path.join(latest_log_path, "migration_result.txt")
        error_file = os.path.join(latest_log_path, "migration_error.txt")
        
        if os.path.exists(result_file):
            with open(result_file, 'r') as f:
                content = f.read()
            return_code = _extract_return_code(content)
            if return_code == 0:
                built = _build_stage_statuses(full_log_lines, "completed")
                return {
                    "status": "completed",
                    "log_path": latest_log_path,
                    "result": content,
                    "return_code": return_code,
                    "recent_log_lines": _recent_log_lines(latest_log_path),
                    "log_lines": full_log_lines,
                    "stage_statuses": built["stage_statuses"],
                    "downtime_ms": built.get("downtime_ms"),
                    **runtime_details,
                    **metadata
                }
            built = _build_stage_statuses(full_log_lines, "error")
            return {
                "status": "error",
                "log_path": latest_log_path,
                "error": content,
                "return_code": return_code,
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": built["stage_statuses"],
                "downtime_ms": built.get("downtime_ms"),
                **runtime_details,
                **metadata
            }
        elif os.path.exists(error_file):
            with open(error_file, 'r') as f:
                content = f.read()
            built = _build_stage_statuses(full_log_lines, "error")
            return {
                "status": "error",
                "log_path": latest_log_path,
                "error": content,
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": built["stage_statuses"],
                "downtime_ms": built.get("downtime_ms"),
                **runtime_details,
                **metadata
            }
        else:
            progress = _latest_progress_line(latest_log_path)
            built = _build_stage_statuses(full_log_lines, "running")
            return {
                "status": "running",
                "log_path": latest_log_path,
                "message": progress or "Migration is still in progress",
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": built["stage_statuses"],
                "downtime_ms": built.get("downtime_ms"),
                **runtime_details,
                **metadata
            }
            
    except Exception as e:
        return {"status": "error", "message": f"Error checking migration status: {str(e)}"}

@router.get("/migration-history")
def get_migration_history(limit: int = 10, offset: int = 0):
    try:
        if limit < 1:
            limit = 1
        if limit > 50:
            limit = 50
        if offset < 0:
            offset = 0
        items, total, has_more = _collect_recent_migrations(limit, offset)
        return {
            "items": items,
            "limit": limit,
            "offset": offset,
            "total": total,
            "has_more": has_more
        }
    except Exception as e:
        return {"items": [], "limit": limit, "offset": offset, "total": 0, "has_more": False, "error": f"Error reading migration history: {str(e)}"}

def reload_config():
    global config
    config = load_config()
