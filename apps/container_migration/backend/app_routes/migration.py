from fastapi import APIRouter, HTTPException, Request
from datetime import datetime
import subprocess
import os
import asyncio
from models.migration_info import MigrationInfo
from models.alert_model import Alert
from utils.migration_util import load_config
import pytz

router = APIRouter()

triggeredMigrations = []
base_log_path = "/home/ubuntu/contMigration_logs"
config = load_config()
timezone = pytz.timezone('Europe/Berlin')

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
    try:
        cmd = ["/home/ubuntu/meierm78/ContMigration-VT1/scripts/migration/single-migration.sh", info.k8s_pod_name, "--log-dir", log_path]
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
    pod_name = body.get("podName")
    app_name = body.get("appName")
    generate_forensic_report = body.get("forensicAnalysis")
    generate_AI_suggestion = body.get("AISuggestion")
    
    info = MigrationInfo(
        k8s_pod_name=pod_name,
        container_name=app_name,
        migration_type="manual",
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
        
        # Check for completion indicators
        result_file = os.path.join(latest_log_path, "migration_result.txt")
        error_file = os.path.join(latest_log_path, "migration_error.txt")
        
        if os.path.exists(result_file):
            with open(result_file, 'r') as f:
                content = f.read()
            return {"status": "completed", "log_path": latest_log_path, "result": content}
        elif os.path.exists(error_file):
            with open(error_file, 'r') as f:
                content = f.read()
            return {"status": "error", "log_path": latest_log_path, "error": content}
        else:
            return {"status": "running", "log_path": latest_log_path, "message": "Migration is still in progress"}
            
    except Exception as e:
        return {"status": "error", "message": f"Error checking migration status: {str(e)}"}

def reload_config():
    global config
    config = load_config()