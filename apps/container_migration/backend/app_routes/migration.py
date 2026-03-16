from fastapi import APIRouter, HTTPException, Request
from datetime import datetime
import subprocess
import os
import asyncio
from pathlib import Path
import re
from models.migration_info import MigrationInfo
from models.alert_model import Alert
from utils.migration_util import load_config
import pytz

router = APIRouter()

triggeredMigrations = []
base_log_path = "/home/ubuntu/contMigration_logs"
config = load_config()
timezone = pytz.timezone('Europe/Berlin')

def _extract_return_code(content: str):
    for line in content.splitlines():
        if line.startswith("Return code:"):
            value = line.split(":", 1)[1].strip()
            if value.isdigit():
                return int(value)
    return None

def _latest_progress_line(log_path: str):
    migration_log_file = os.path.join(log_path, "migration_log.txt")
    if not os.path.exists(migration_log_file):
        return None

    with open(migration_log_file, "r") as file:
        lines = [line.strip() for line in file.readlines() if line.strip()]
    if not lines:
        return None
    return lines[-1]

def _recent_log_lines(log_path: str, line_count: int = 12):
    migration_log_file = os.path.join(log_path, "migration_log.txt")
    if not os.path.exists(migration_log_file):
        return []

    with open(migration_log_file, "r") as file:
        lines = [line.rstrip("\n") for line in file.readlines() if line.strip()]
    if not lines:
        return []
    return lines[-line_count:]

def _full_log_lines(log_path: str):
    lines = []
    migration_log_file = os.path.join(log_path, "migration_log.txt")
    result_file = os.path.join(log_path, "migration_result.txt")
    error_file = os.path.join(log_path, "migration_error.txt")

    if os.path.exists(migration_log_file):
        with open(migration_log_file, "r") as file:
            lines.extend([line.rstrip("\n") for line in file.readlines()])

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

def _build_stage_statuses(log_lines, final_status: str):
    stages = [
        {"key": "checkpoint", "label": "Checkpoint creation", "status": "pending"},
        {"key": "image", "label": "Image conversion and push", "status": "pending"},
        {"key": "restore", "label": "Restore pod startup", "status": "pending"},
        {"key": "traffic", "label": "Traffic switch", "status": "pending"},
        {"key": "cleanup", "label": "Source cleanup", "status": "pending"},
    ]

    joined = "\n".join(log_lines)

    if "Creating checkpoint" in joined:
        stages[0]["status"] = "running"
    if "-- Checkpoint created --" in joined:
        stages[0]["status"] = "completed"

    if "Convert checkpoint into image" in joined or "Pushing image" in joined:
        stages[1]["status"] = "running"
    if "Image pushed onto local registy" in joined or "Image pushed onto local registry" in joined:
        stages[1]["status"] = "completed"

    if "Waiting for the new pod" in joined:
        stages[2]["status"] = "running"
    if " is running --" in joined:
        stages[2]["status"] = "completed"

    if "switching mirroring rule" in joined or "Switching traffic to the new pod" in joined:
        stages[3]["status"] = "running"
    if "--- Deleting old pod ---" in joined or "-- Migration complete --" in joined:
        stages[3]["status"] = "completed"

    if "--- Deleting old pod ---" in joined:
        stages[4]["status"] = "running"
    if "Old pod" in joined and "deleted" in joined:
        stages[4]["status"] = "completed"

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

    return stages

def _extract_log_metadata(log_path: str):
    metadata = {
        "source_cluster": "unknown",
        "target_cluster": "unknown",
        "namespace": "unknown",
        "target_pod_name": "unknown"
    }
    migration_log_file = os.path.join(log_path, "migration_log.txt")
    if not os.path.exists(migration_log_file):
        return metadata

    with open(migration_log_file, "r") as file:
        content = file.read()

    source_match = re.search(r"^Source cluster:\s*(.+)$", content, re.MULTILINE)
    target_match = re.search(r"^Target cluster:\s*(.+)$", content, re.MULTILINE)
    namespace_match = re.search(r"^Namespace:\s*(.+)$", content, re.MULTILINE)
    target_pod_match = re.search(r'Waiting for the new pod "([^"]+)" to be ready', content)

    if source_match:
        metadata["source_cluster"] = source_match.group(1).strip()
    if target_match:
        metadata["target_cluster"] = target_match.group(1).strip()
    if namespace_match:
        metadata["namespace"] = namespace_match.group(1).strip()
    if target_pod_match:
        metadata["target_pod_name"] = target_pod_match.group(1).strip()

    return metadata

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
            stage_statuses = _build_stage_statuses(full_log_lines, status)

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
                "stage_statuses": stage_statuses,
                "created_at": datetime.fromtimestamp(created_ts, tz=timezone).isoformat()
            })

    entries.sort(key=lambda item: item["created_at"], reverse=True)
    total = len(entries)
    paged_items = entries[offset:offset + limit]
    has_more = (offset + limit) < total
    return paged_items, total, has_more

@router.post("/alert")
async def handle_alerts(alert: Alert):
    info = MigrationInfo(
        hostname=alert.hostname, 
        rule=alert.rule, 
        k8s_pod_name=alert.output_fields.k8s_pod_name, 
        container_name=alert.output_fields.container_name,
        migration_type="automated",
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    )
    if(info.rule != "PTRACE attached to process"):
        falco_log_path = f"{base_log_path}/falco"
        os.makedirs(falco_log_path, exist_ok=True)
        with open(f"{falco_log_path}/alert.txt", "a") as file:
            file.write(f"Received alert: {info.rule} for pod: {info.k8s_pod_name} at {datetime.now(timezone)}\n")
    
    for rule_config in config.config:
        if info.rule == rule_config.rule and info.k8s_pod_name not in triggeredMigrations:
            if rule_config.action == "migrate":
                info.forensic_analysis = rule_config.forensic_analysis
                info.AI_suggestion = rule_config.AI_suggestion
                triggeredMigrations.append(info.k8s_pod_name)
                print(f"Triggering migration for pod: {info.k8s_pod_name}")
                return await trigger_migration(info)
            elif rule_config.action == "log":
                print(f"Logging event for pod: {info.k8s_pod_name}")
                handle_log(info)
                return {"message": "Event logged"}
    return {"message": "No action taken"}

async def trigger_migration(info: MigrationInfo):
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
        if info.forensic_analysis:
            cmd.append("--forensic-analysis")
        if info.AI_suggestion:
            cmd.append("--ai-suggestion")
    
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

@router.post("/migrate")
async def migrate_pod(request: Request):
    body = await request.json()
    source_cluster = body.get("sourceCluster")
    target_cluster = body.get("targetCluster")
    namespace = body.get("namespace")
    pod_name = body.get("podName")
    app_name = body.get("appName")
    generate_forensic_report = body.get("forensicAnalysis")
    generate_AI_suggestion = body.get("AISuggestion")
    
    info = MigrationInfo(
        k8s_pod_name=pod_name,
        container_name=app_name,
        migration_type="manual",
        source_cluster=source_cluster,
        target_cluster=target_cluster,
        namespace=namespace,
        forensic_analysis=generate_forensic_report,
        AI_suggestion=generate_AI_suggestion,
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    )
    return await trigger_migration(info)

@router.get("/migration-status/{pod_name}")
async def get_migration_status(pod_name: str):
    """Get the status of a migration by checking the log files"""
    try:
        # Find the most recent migration log for this pod
        pod_logs = []
        for container_dir in os.listdir(base_log_path):
            container_path = os.path.join(base_log_path, container_dir)
            if os.path.isdir(container_path):
                for log_dir in os.listdir(container_path):
                    if pod_name in log_dir:
                        log_path = os.path.join(container_path, log_dir)
                        pod_logs.append((log_path, os.path.getctime(log_path)))
        
        if not pod_logs:
            return {"status": "not_found", "message": f"No migration logs found for pod {pod_name}"}
        
        # Get the most recent log directory
        latest_log_path = max(pod_logs, key=lambda x: x[1])[0]
        metadata = _extract_log_metadata(latest_log_path)
        full_log_lines = _full_log_lines(latest_log_path)
        
        # Check for completion indicators
        result_file = os.path.join(latest_log_path, "migration_result.txt")
        error_file = os.path.join(latest_log_path, "migration_error.txt")
        
        if os.path.exists(result_file):
            with open(result_file, 'r') as f:
                content = f.read()
            return_code = _extract_return_code(content)
            if return_code == 0:
                stage_statuses = _build_stage_statuses(full_log_lines, "completed")
                return {
                    "status": "completed",
                    "log_path": latest_log_path,
                    "result": content,
                    "return_code": return_code,
                    "recent_log_lines": _recent_log_lines(latest_log_path),
                    "log_lines": full_log_lines,
                    "stage_statuses": stage_statuses,
                    **metadata
                }
            stage_statuses = _build_stage_statuses(full_log_lines, "error")
            return {
                "status": "error",
                "log_path": latest_log_path,
                "error": content,
                "return_code": return_code,
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": stage_statuses,
                **metadata
            }
        elif os.path.exists(error_file):
            with open(error_file, 'r') as f:
                content = f.read()
            stage_statuses = _build_stage_statuses(full_log_lines, "error")
            return {
                "status": "error",
                "log_path": latest_log_path,
                "error": content,
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": stage_statuses,
                **metadata
            }
        else:
            progress = _latest_progress_line(latest_log_path)
            stage_statuses = _build_stage_statuses(full_log_lines, "running")
            return {
                "status": "running",
                "log_path": latest_log_path,
                "message": progress or "Migration is still in progress",
                "recent_log_lines": _recent_log_lines(latest_log_path),
                "log_lines": full_log_lines,
                "stage_statuses": stage_statuses,
                **metadata
            }
            
    except Exception as e:
        return {"status": "error", "message": f"Error checking migration status: {str(e)}"}

@router.get("/migration-history")
async def get_migration_history(limit: int = 10, offset: int = 0):
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