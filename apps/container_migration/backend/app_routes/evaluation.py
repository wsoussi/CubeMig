"""API for thesis evaluation runs via ``run_eval_migration.sh``.

Browse completed runs (CSV index, artifacts) or start a new run from the UI.
The UI path spawns the same wrapper + ``single-migration.sh`` command line
that you would run manually in a terminal.
"""

import asyncio
import csv
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field

from app_routes.simulation import ATTACK_FALCO_RULES, SUPPORTED_ATTACK_TYPES
from utils.k8s_client import k8s_client

router = APIRouter()

CUBEMIG_ROOT = Path(os.getenv("CUBEMIG_ROOT", "/home/ubuntu/teemig/CubeMig"))
EVAL_WRAPPER = CUBEMIG_ROOT / "scripts/utils/evaluation/run_eval_migration.sh"
MIGRATION_SCRIPT = CUBEMIG_ROOT / "scripts/migration/single-migration.sh"
DEFAULT_REGISTRY = os.getenv("MIGRATION_REGISTRY", "160.85.255.146:5000")
PNET_REGISTRY = os.getenv("PNET_WIREGUARD_MIGRATION_REGISTRY", "10.10.10.1:5000")
DEFAULT_ROUTING_DEMO_PROBE_URL = os.getenv(
    "ROUTING_DEMO_PROBE_URL",
    "http://10.0.0.18:32366/whoami",
)
DEFAULT_MMT_FALCO_KAFKA_BOOTSTRAP = os.getenv("MMT_FALCO_KAFKA_BOOTSTRAP", "192.168.200.11:30094")
DEFAULT_MMT_FALCO_KAFKA_TOPIC = os.getenv("MMT_FALCO_KAFKA_TOPIC", "mmt-falco-events")
DEFAULT_MMT_FALCO_ALERT_TIMEOUT_SECONDS = int(os.getenv("MMT_FALCO_ALERT_TIMEOUT_SECONDS", "60"))
DEFAULT_SIMULATION_ALERT_TIMEOUT_SECONDS = int(os.getenv("EVAL_SIMULATION_ALERT_TIMEOUT_SECONDS", "60"))
DEFAULT_SIMULATION_API_URL = os.getenv("EVAL_SIMULATION_API_URL", "http://127.0.0.1:8000/simulate")
MMT_FALCO_RULE = "MMT Attack Candidate From Kafka"

VALID_WORKLOADS = frozenset({"routing-demo", "mmt-probe", "vuln-spring", "vuln-redis"})
VALID_TRIGGERS = frozenset({"manual", "falco", "simulate"})
SIMULATION_WORKLOADS = frozenset({"vuln-spring", "vuln-redis"})

# Keys: ``YYYY-MM-DD/run_id`` while the wrapper subprocess is running.
active_eval_runs: dict[str, dict] = {}


class EvaluationStartRequest(BaseModel):
    run_id: str | None = None
    source: str
    dest: str
    namespace: str = "istio-enabled"
    workload: str
    pod: str
    load_rps: int = Field(default=1, ge=0)
    concurrency: int = Field(default=1, ge=1)
    trigger: str = "manual"
    out_root: str | None = None
    checkpoint_root: str | None = None
    registry_address: str | None = None
    probe_url: str | None = None
    falco_kafka_bootstrap: str | None = None
    falco_kafka_topic: str | None = None
    falco_alert_timeout_seconds: int = Field(default=DEFAULT_MMT_FALCO_ALERT_TIMEOUT_SECONDS, ge=1)
    simulation_attack_type: str | None = None
    simulation_alert_timeout_seconds: int = Field(default=DEFAULT_SIMULATION_ALERT_TIMEOUT_SECONDS, ge=1)
    istio_routing_context: str = "cluster1"
    skip_cpu_compat_check: bool = True
    cleanup_incompatible_mounts: bool | None = None
    disable_istio_sidecar: bool = False
    forensic_analysis: bool = False
    ai_suggestion: bool = False

# Same default as the wrapper script (run_eval_migration.sh --out-root).
EVAL_ROOT = Path(os.getenv("EVALUATION_OUT_ROOT", "/home/ubuntu/evaluation-runs"))

# Per-run files the wrapper may produce. Anything not in this set is rejected
# by the file endpoint so we cannot accidentally serve checkpoint .tar archives
# or secrets that someone dropped into the run directory by hand.
TEXT_ARTIFACTS: tuple[str, ...] = (
    "metadata.json",
    "migration.log",
    "k8s_before.txt",
    "k8s_after.txt",
    "istio_before.yaml",
    "istio_after.yaml",
    "host_metrics.csv",
    "http_probe.csv",
    "http_probe_summary.json",
    "falco_event.json",
    "falco_trigger.txt",
    "falco_trigger.json",
    "simulation_trigger.txt",
    "simulation_trigger.json",
    "wg_before.txt",
    "wg_after.txt",
    "reset_after.txt",
    "reset_after_istio.yaml",
    "reset_after_k8s.txt",
    "artifact_sizes.txt",
    "failure_diagnostics.txt",
    "checkpoint/checkpoint_path.txt",
    "checkpoint/checkpoint_stat.txt",
    "checkpoint/checkpoint_sha256.txt",
    "checkpoint/checkpoint_tar_listing.txt",
    "checkpoint/checkpointctl_show.txt",
    "checkpoint/checkpointctl_inspect.txt",
)

# UI rendering safety: cap any single artifact at 1 MB so the browser tab does
# not lock up on a huge migration.log.
MAX_FILE_BYTES = 1_000_000


def _resolve_run_dir(date: str, run_id: str) -> Path:
    """Validate path components (no traversal, no separators) and return the run dir."""
    for label, value in (("date", date), ("run_id", run_id)):
        if not value or "/" in value or "\\" in value or ".." in value:
            raise HTTPException(status_code=400, detail=f"Invalid {label}: {value!r}")
    run_dir = EVAL_ROOT / date / run_id
    if not run_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Run directory not found: {run_dir}")
    return run_dir


def _derive_date_from_row(row: dict) -> str | None:
    """Prefer the date embedded in the run_dir path, fall back to start_time_utc[:10]."""
    run_dir = row.get("run_dir") or ""
    parts = [p for p in run_dir.split("/") if p]
    for part in parts:
        if len(part) == 10 and part[4] == "-" and part[7] == "-":
            return part
    start = row.get("start_time_utc") or ""
    return start[:10] if len(start) >= 10 else None


def _validate_run_id(run_id: str) -> None:
    if not run_id or "/" in run_id or "\\" in run_id or ".." in run_id:
        raise HTTPException(status_code=400, detail=f"Invalid run_id: {run_id!r}")
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$", run_id):
        raise HTTPException(status_code=400, detail="run_id must be alphanumeric (._- allowed)")


def _generate_run_id(source: str, dest: str, workload: str, load_rps: int) -> str:
    ts = datetime.now(timezone.utc).strftime("%H%M%S")
    raw = f"{source}_to_{dest}_{workload}_{load_rps}rps_{ts}"
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "_", raw).strip("_")
    return safe[:80] or f"eval_{ts}"


def _default_registry(dest: str) -> str:
    normalized = (dest or "").strip().lower()
    if normalized in ("cluster-pnet", "pnet"):
        return PNET_REGISTRY
    return DEFAULT_REGISTRY


def _heterogeneous_dest(dest: str) -> bool:
    normalized = (dest or "").strip().lower()
    return normalized in ("cluster-pnet", "pnet", "cluster-sev-snp", "sev-snp")


def _is_mmt_falco_evaluation(body: EvaluationStartRequest) -> bool:
    return (
        body.trigger == "falco"
        and body.workload == "routing-demo"
        and body.source == "cluster-pnet"
        and body.dest == "cluster-sev-snp"
    )


def _is_simulation_evaluation(body: EvaluationStartRequest) -> bool:
    return body.trigger == "simulate" and body.workload in SIMULATION_WORKLOADS


def _running_workload_pods(cluster: str, namespace: str, workload: str) -> list[str]:
    client_api = k8s_client.get_client(cluster)
    try:
        pod_list = client_api.list_namespaced_pod(namespace=namespace, label_selector=f"app={workload}")
        pods = [
            pod.metadata.name
            for pod in pod_list.items
            if pod.metadata and pod.metadata.name and pod.status and pod.status.phase == "Running"
        ]
    except Exception:
        pods = []
    if pods:
        return sorted(pods)

    pod_list = client_api.list_namespaced_pod(namespace=namespace)
    return sorted(
        pod.metadata.name
        for pod in pod_list.items
        if (
            pod.metadata
            and pod.metadata.name
            and pod.metadata.name.startswith(workload)
            and pod.status
            and pod.status.phase == "Running"
        )
    )


def _validate_start_request(body: EvaluationStartRequest) -> None:
    if body.source == body.dest:
        raise HTTPException(status_code=400, detail="source and dest must be different")
    if body.workload not in VALID_WORKLOADS:
        raise HTTPException(status_code=400, detail=f"workload must be one of: {sorted(VALID_WORKLOADS)}")
    if body.trigger not in VALID_TRIGGERS:
        raise HTTPException(status_code=400, detail=f"trigger must be one of: {sorted(VALID_TRIGGERS)}")
    if body.trigger == "simulate" and body.workload not in SIMULATION_WORKLOADS:
        raise HTTPException(status_code=400, detail="trigger=simulate is only supported for workload=vuln-spring or workload=vuln-redis")
    if _is_simulation_evaluation(body):
        attack_type = (body.simulation_attack_type or "").strip()
        if attack_type not in SUPPORTED_ATTACK_TYPES:
            raise HTTPException(
                status_code=400,
                detail=f"simulation_attack_type must be one of: {sorted(SUPPORTED_ATTACK_TYPES)}",
            )
    if not k8s_client.has_cluster(body.source):
        raise HTTPException(status_code=400, detail=f"Unknown source cluster: {body.source}")
    if not k8s_client.has_cluster(body.dest):
        raise HTTPException(status_code=400, detail=f"Unknown dest cluster: {body.dest}")
    if not k8s_client.has_cluster((body.istio_routing_context or "cluster1").strip() or "cluster1"):
        raise HTTPException(status_code=400, detail=f"Unknown Istio routing context: {body.istio_routing_context}")
    if not EVAL_WRAPPER.is_file():
        raise HTTPException(status_code=500, detail=f"Evaluation wrapper not found: {EVAL_WRAPPER}")
    if not MIGRATION_SCRIPT.is_file():
        raise HTTPException(status_code=500, detail=f"Migration script not found: {MIGRATION_SCRIPT}")
    if _is_simulation_evaluation(body):
        running = _running_workload_pods(body.source, body.namespace, body.workload)
        if len(running) != 1 or running[0] != body.pod:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Simulation evaluations require exactly one running {body.workload} pod in the selected "
                    f"source namespace, and it must be the selected pod. Found: {running or 'none'}. "
                    f"Scale {body.workload} to 1 and refresh the pod selection before starting."
                ),
            )


def _build_migration_argv(body: EvaluationStartRequest, registry: str, run_dir: Path) -> list[str]:
    cmd = [
        str(MIGRATION_SCRIPT),
        body.pod,
        "--log-dir",
        str(run_dir),
        "--source-cluster",
        body.source,
        "--dest-cluster",
        body.dest,
        "--namespace",
        body.namespace,
        "--registry",
        registry,
        "--istio-routing-context",
        (body.istio_routing_context or "cluster1").strip() or "cluster1",
    ]
    if body.forensic_analysis:
        cmd.append("--forensic-analysis")
    if body.ai_suggestion:
        cmd.append("--ai-suggestion")
    if body.disable_istio_sidecar:
        cmd.append("--disable-istio-sidecar")
    if body.skip_cpu_compat_check:
        cmd.append("--skip-cpu-compat-check")
    cleanup = body.cleanup_incompatible_mounts
    if cleanup is None:
        cleanup = _heterogeneous_dest(body.dest)
    if cleanup:
        cmd.append("--cleanup-incompatible-mounts")
    else:
        cmd.append("--skip-checkpoint-normalization")
    return cmd


def _build_wrapper_argv(
    body: EvaluationStartRequest,
    run_id: str,
    out_root: Path,
    ckpt_root: Path,
    falco_nonce: str | None = None,
) -> list[str]:
    routing_context = (body.istio_routing_context or "cluster1").strip() or "cluster1"
    argv = [
        str(EVAL_WRAPPER),
        "--run-id",
        run_id,
        "--source",
        body.source,
        "--dest",
        body.dest,
        "--namespace",
        body.namespace,
        "--workload",
        body.workload,
        "--pod",
        body.pod,
        "--load-rps",
        str(body.load_rps),
        "--concurrency",
        str(body.concurrency),
        "--trigger",
        body.trigger,
        "--out-root",
        str(out_root),
        "--checkpoint-root",
        str(ckpt_root),
        "--istio-routing-context",
        routing_context,
    ]
    if body.workload == "routing-demo":
        probe_url = (body.probe_url or "").strip() or DEFAULT_ROUTING_DEMO_PROBE_URL
        if probe_url:
            argv.extend(["--probe-url", probe_url])
        argv.extend(["--reset-routing-context", routing_context])
    if _is_mmt_falco_evaluation(body):
        argv.extend([
            "--falco-trigger-kafka-bootstrap",
            (body.falco_kafka_bootstrap or "").strip() or DEFAULT_MMT_FALCO_KAFKA_BOOTSTRAP,
            "--falco-trigger-topic",
            (body.falco_kafka_topic or "").strip() or DEFAULT_MMT_FALCO_KAFKA_TOPIC,
            "--falco-trigger-timeout-seconds",
            str(body.falco_alert_timeout_seconds),
            "--falco-trigger-nonce",
            falco_nonce or "",
        ])
    if _is_simulation_evaluation(body):
        attack_type = (body.simulation_attack_type or "").strip()
        argv.extend([
            "--simulation-attack-type",
            attack_type,
            "--simulation-expected-rule",
            ATTACK_FALCO_RULES.get(attack_type, ""),
            "--simulation-alert-timeout-seconds",
            str(body.simulation_alert_timeout_seconds),
            "--simulation-api-url",
            DEFAULT_SIMULATION_API_URL,
        ])
    argv.append("--")
    registry = (body.registry_address or "").strip() or _default_registry(body.dest)
    run_dir = out_root / datetime.now(timezone.utc).strftime("%Y-%m-%d") / run_id
    argv.extend(_build_migration_argv(body, registry, run_dir))
    return argv


def _tail_file(path: Path, max_lines: int = 30) -> list[str]:
    if not path.is_file():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return [ln for ln in lines if ln.strip()][-max_lines:]
    except Exception:  # noqa: BLE001
        return []


async def _run_evaluation_subprocess(key: str, argv: list[str], run_dir: Path) -> None:
    pod_name = active_eval_runs.get(key, {}).get("pod", "")
    falco_correlation_id = active_eval_runs.get(key, {}).get("falco_correlation_id")
    try:
        process = await asyncio.create_subprocess_exec(
            *argv,
            cwd=str(CUBEMIG_ROOT),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            stdin=asyncio.subprocess.DEVNULL,
        )
        active_eval_runs[key]["pid"] = process.pid
        await process.wait()
        active_eval_runs[key]["return_code"] = process.returncode
    except Exception as exc:  # noqa: BLE001
        active_eval_runs[key]["error"] = str(exc)
    finally:
        active_eval_runs[key]["status"] = "finished"
        if falco_correlation_id:
            from app_routes.migration import unregister_pending_eval_falco_alert

            unregister_pending_eval_falco_alert(falco_correlation_id)
        if pod_name:
            from app_routes.migration import activeMigrations

            if activeMigrations.get(pod_name) == str(run_dir):
                activeMigrations.pop(pod_name, None)


@router.post("/start")
async def start_evaluation(body: EvaluationStartRequest):
    """Start ``run_eval_migration.sh`` in the background (same as manual CLI)."""
    _validate_start_request(body)

    out_root = Path(body.out_root or os.getenv("EVALUATION_OUT_ROOT", "/home/ubuntu/evaluation-runs"))
    ckpt_root = Path(body.checkpoint_root or os.getenv("CHECKPOINT_ROOT", "/home/ubuntu/nfs/checkpoints"))

    run_id = (body.run_id or "").strip() or _generate_run_id(body.source, body.dest, body.workload, body.load_rps)
    _validate_run_id(run_id)

    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    run_dir = out_root / date / run_id
    key = f"{date}/{run_id}"

    if key in active_eval_runs:
        raise HTTPException(status_code=409, detail=f"Evaluation run already in progress: {run_id}")

    falco_nonce = f"{run_id}-{secrets.token_hex(8)}" if _is_mmt_falco_evaluation(body) else None
    simulation_correlation_id = f"{run_id}-simulation-{secrets.token_hex(8)}" if _is_simulation_evaluation(body) else None
    argv = _build_wrapper_argv(body, run_id, out_root, ckpt_root, falco_nonce)
    sep_idx = argv.index("--") if "--" in argv else len(argv)
    active_eval_runs[key] = {
        "status": "running",
        "run_id": run_id,
        "date": date,
        "pod": body.pod,
        "run_dir": str(run_dir),
        "out_root": str(out_root),
        "started_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "argv_preview": " ".join(argv[: min(sep_idx + 3, len(argv))]) + (" …" if len(argv) > sep_idx + 3 else ""),
    }
    if falco_nonce:
        active_eval_runs[key]["falco_nonce"] = falco_nonce
        active_eval_runs[key]["falco_correlation_id"] = falco_nonce
        from app_routes.migration import register_pending_eval_falco_alert

        register_pending_eval_falco_alert(
            run_id=run_id,
            run_dir=str(run_dir),
            pod=body.pod,
            namespace=body.namespace,
            source_cluster=body.source,
            workload=body.workload,
            rule=MMT_FALCO_RULE,
            nonce=falco_nonce,
        )
    if simulation_correlation_id:
        active_eval_runs[key]["falco_correlation_id"] = simulation_correlation_id
        from app_routes.migration import register_pending_eval_falco_alert

        attack_type = (body.simulation_attack_type or "").strip()
        register_pending_eval_falco_alert(
            run_id=run_id,
            run_dir=str(run_dir),
            pod=body.pod,
            namespace=body.namespace,
            source_cluster=body.source,
            workload=body.workload,
            rule=ATTACK_FALCO_RULES[attack_type],
            correlation_id=simulation_correlation_id,
            timeout_seconds=body.simulation_alert_timeout_seconds,
            allow_missing_k8s_metadata=True,
        )
    # Migration tab polls activeMigrations / contMigration_logs — point it at this run dir.
    from app_routes.migration import activeMigrations

    activeMigrations[body.pod] = str(run_dir)
    asyncio.create_task(_run_evaluation_subprocess(key, argv, run_dir))

    return {
        "message": "Evaluation run started",
        "run_id": run_id,
        "date": date,
        "run_dir": str(run_dir),
        "out_root": str(out_root),
    }


def _resolve_run_paths(date: str, run_id: str, active: dict | None = None) -> tuple[Path, Path, Path]:
    """Return (run_dir, timestamped migration log path, metadata.json path)."""
    if active and active.get("run_dir"):
        run_dir = Path(active["run_dir"])
    else:
        run_dir = EVAL_ROOT / date / run_id
        meta_path = run_dir / "metadata.json"
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8", errors="replace"))
                if meta.get("run_dir"):
                    run_dir = Path(meta["run_dir"])
            except Exception:  # noqa: BLE001
                pass
    from app_routes.migration import _migration_log_file_path

    log_file = _migration_log_file_path(str(run_dir))
    if log_file:
        return run_dir, Path(log_file), run_dir / "metadata.json"
    return run_dir, run_dir / "migration_log.txt", run_dir / "metadata.json"


def _migration_monitor_fields(run_dir: Path, final_status: str) -> dict:
    """Fields aligned with GET /migration-status for the pipeline monitor UI."""
    from app_routes.migration import (
        _build_stage_statuses,
        _extract_log_metadata,
        _fetch_target_runtime_details,
        _full_log_lines,
        _latest_progress_line,
        _metadata_from_eval_json,
        _recent_log_lines,
    )

    log_path = str(run_dir)
    metadata = _metadata_from_eval_json(log_path, _extract_log_metadata(log_path))
    runtime = _fetch_target_runtime_details(metadata)
    full_log_lines = _full_log_lines(log_path)
    built = _build_stage_statuses(full_log_lines, final_status)
    return {
        "log_path": log_path,
        "stage_statuses": built.get("stage_statuses") or [],
        "downtime_ms": built.get("downtime_ms"),
        "recent_log_lines": _recent_log_lines(log_path),
        "log_lines": full_log_lines[-80:] if full_log_lines else [],
        "message": _latest_progress_line(log_path),
        **metadata,
        **runtime,
    }


@router.get("/runs/{date}/{run_id}/status")
def get_run_status(date: str, run_id: str):
    """Poll whether a run is still executing and return recent ``migration.log`` lines."""
    _validate_run_id(run_id)
    if "/" in date or "\\" in date or ".." in date:
        raise HTTPException(status_code=400, detail=f"Invalid date: {date!r}")

    key = f"{date}/{run_id}"
    active = active_eval_runs.get(key)
    run_dir, log_path, meta_path = _resolve_run_paths(date, run_id, active)
    if active and active.get("status") == "running":
        return {
            "status": "running",
            "run_id": run_id,
            "date": date,
            "run_dir": str(run_dir),
            "started_at": active.get("started_at"),
            **_migration_monitor_fields(run_dir, "running"),
        }

    metadata: dict | None = None
    if meta_path.exists():
        try:
            metadata = json.loads(meta_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:  # noqa: BLE001
            metadata = None

    exit_code = None
    if metadata is not None:
        exit_code = metadata.get("exit_code")

    if exit_code is not None and str(exit_code) not in ("", "-1"):
        try:
            code_int = int(exit_code)
        except (TypeError, ValueError):
            code_int = None
        if code_int is not None:
            final = "completed" if code_int == 0 else "error"
            return {
                "status": "completed" if code_int == 0 else "failed",
                "run_id": run_id,
                "date": date,
                "run_dir": str(run_dir),
                "exit_code": code_int,
                "metadata": metadata,
                **_migration_monitor_fields(run_dir, final),
            }

    if active and active.get("status") == "finished":
        rc = active.get("return_code")
        final = "completed" if rc == 0 else "error"
        return {
            "status": "completed" if rc == 0 else "failed",
            "run_id": run_id,
            "date": date,
            "run_dir": str(run_dir),
            "exit_code": rc,
            "error": active.get("error"),
            **_migration_monitor_fields(run_dir, final),
        }

    if run_dir.is_dir():
        final = "running"
        return {
            "status": "unknown",
            "run_id": run_id,
            "date": date,
            "run_dir": str(run_dir),
            **_migration_monitor_fields(run_dir, final),
        }

    raise HTTPException(status_code=404, detail=f"Run not found: {date}/{run_id}")


@router.get("/runs")
def list_runs():
    """Return all rows from ``evaluation_results.csv``, newest first."""
    csv_path = EVAL_ROOT / "evaluation_results.csv"
    runs: list[dict] = []
    error: str | None = None
    if csv_path.exists():
        try:
            with csv_path.open(newline="") as fh:
                reader = csv.DictReader(fh)
                for row in reader:
                    enriched = dict(row)
                    enriched["date"] = _derive_date_from_row(row)
                    runs.append(enriched)
        except Exception as exc:  # noqa: BLE001 — surface any CSV parse failure to the UI
            error = f"Failed to parse evaluation_results.csv: {exc}"

    runs.reverse()
    return {
        "out_root": str(EVAL_ROOT),
        "runs": runs,
        "error": error,
    }


@router.get("/runs/{date}/{run_id}")
def get_run(date: str, run_id: str):
    """Return parsed metadata.json plus the inventory of available text artifacts."""
    run_dir = _resolve_run_dir(date, run_id)

    metadata: dict | None = None
    meta_path = run_dir / "metadata.json"
    if meta_path.exists():
        try:
            metadata = json.loads(meta_path.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:  # noqa: BLE001
            metadata = {"_error": f"metadata.json unreadable: {exc}"}

    artifacts = []
    for name in TEXT_ARTIFACTS:
        path = run_dir / name
        if path.exists():
            try:
                artifacts.append({"name": name, "size_bytes": path.stat().st_size})
            except Exception:  # noqa: BLE001
                artifacts.append({"name": name, "size_bytes": None})

    return {
        "run_dir": str(run_dir),
        "metadata": metadata,
        "artifacts": artifacts,
    }


@router.get("/runs/{date}/{run_id}/file")
def get_run_file(date: str, run_id: str, name: str = Query(..., description="Artifact name, must be in TEXT_ARTIFACTS")):
    """Return the (truncated) UTF-8 content of one whitelisted text artifact."""
    if name not in TEXT_ARTIFACTS:
        raise HTTPException(status_code=400, detail=f"Artifact not in allow-list: {name}")
    run_dir = _resolve_run_dir(date, run_id)
    file_path = run_dir / name
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail=f"Artifact not found: {name}")
    try:
        full_size = file_path.stat().st_size
        with file_path.open("rb") as fh:
            data = fh.read(MAX_FILE_BYTES + 1)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    truncated = len(data) > MAX_FILE_BYTES
    if truncated:
        data = data[:MAX_FILE_BYTES]
    return {
        "name": name,
        "size_bytes": full_size,
        "truncated": truncated,
        "content": data.decode("utf-8", errors="replace"),
    }
