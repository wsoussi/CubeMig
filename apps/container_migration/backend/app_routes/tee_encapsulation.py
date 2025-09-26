from fastapi import APIRouter
import subprocess
import os
import sys
import json
import datetime
from models.tee_operation_info import TeeOperationInfo
from models.podman_container import PodmanContainer, PodmanContainersResponse

router = APIRouter()

# Define source and destination VMs
NORMAL_VM = "sous@bert.cloudlab.zhaw.ch"
SEV_SNP_VM = "ubuntu@192.168.122.77"
BASE_LOG_PATH = "/home/ubuntu/contMigration_logs"

def log_operation(container_name, operation, success, src_vm, dest_vm, log_path, output=None, error=None):
    """Log TEE operation details to a file for tracking"""
    try:
        # Create log directory path
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        os.makedirs(log_path, exist_ok=True)
        
        # Write to tee_operation.txt in container's directory
        log_file = os.path.join(log_path, 'tee_operation.txt')
        with open(log_file, 'w') as f:
            f.write(f"TEE Operation Log for Container: {container_name}\n")
            f.write(f"Operation Type: {operation}\n")
            f.write(f"Timestamp: {timestamp}\n")
            f.write(f"Source VM: {src_vm}\n")
            f.write(f"Destination VM: {dest_vm}\n")
            f.write(f"Status: {'Success' if success else 'Failed'}\n\n")
            
            if output:
                f.write("Operation Output:\n")
                f.write(output + "\n\n")
            if error:
                f.write("Error Details:\n")
                f.write(error + "\n")
        
        print(f"Operation logged: {container_name} - {operation} - {'Success' if success else 'Failed'}")
    except Exception as e:
        print(f"Error logging operation: {str(e)}")

@router.get("/containers")
def get_podman_containers():
    """Get a list of podman containers running in both environments"""
    normal_containers = []
    sevsnp_containers = []
    error_message = None
    
    try:
        # Get containers from NORMAL environment (bert)
        print(f"Fetching containers from normal environment: {NORMAL_VM}")
        ssh_key_path = os.path.expanduser("~/.ssh/id_rsa")
        normal_result = subprocess.run(
            ["ssh", "-i", ssh_key_path, NORMAL_VM, "sudo podman ps --format json"],
            capture_output=True,
            text=True,
            check=False  # Don't raise exception on non-zero exit
        )
        
        if normal_result.returncode == 0 and normal_result.stdout.strip():
            try:
                print(f"Normal VM stdout: {normal_result.stdout}")
                if normal_result.stdout.strip().startswith('['):
                    normal_json = json.loads(normal_result.stdout)
                    for container in normal_json:
                        normal_containers.append(PodmanContainer(
                            containerName=container.get("Names", ["unknown"])[0] if isinstance(container.get("Names"), list) else container.get("Names", "unknown"),
                            containerID=container.get("Id", "unknown"),
                            image=container.get("Image", "unknown"),
                            status=container.get("Status", "unknown"),
                            environment="Normal"
                        ))
                else:
                    print(f"Invalid JSON format from Normal VM: {normal_result.stdout}")
            except json.JSONDecodeError as e:
                print(f"JSON decode error from Normal VM: {str(e)}")
        else:
            print(f"Error fetching containers from Normal VM: {normal_result.stderr}")
            
        # Get containers from SEV-SNP environment
        print(f"Fetching containers from SEV-SNP environment: {SEV_SNP_VM}")
        sevsnp_result = subprocess.run(
            ["ssh", "-i", ssh_key_path, "-J", NORMAL_VM, SEV_SNP_VM, "sudo podman ps --format json"],
            capture_output=True,
            text=True,
            check=False  # Don't raise exception on non-zero exit
        )
        
        if sevsnp_result.returncode == 0 and sevsnp_result.stdout.strip():
            try:
                print(f"SEV-SNP VM stdout: {sevsnp_result.stdout}")
                if sevsnp_result.stdout.strip().startswith('['):
                    sevsnp_json = json.loads(sevsnp_result.stdout)
                    for container in sevsnp_json:
                        sevsnp_containers.append(PodmanContainer(
                            containerName=container.get("Names", ["unknown"])[0] if isinstance(container.get("Names"), list) else container.get("Names", "unknown"),
                            containerID=container.get("Id", "unknown"),
                            image=container.get("Image", "unknown"),
                            status=container.get("Status", "unknown"),
                            environment="SEV-SNP"
                        ))
                else:
                    print(f"Invalid JSON format from SEV-SNP VM: {sevsnp_result.stdout}")
            except json.JSONDecodeError as e:
                print(f"JSON decode error from SEV-SNP VM: {str(e)}")
        else:
            print(f"Error fetching containers from SEV-SNP VM: {sevsnp_result.stderr}")
            
        return PodmanContainersResponse(
            normal_containers=normal_containers,
            sevsnp_containers=sevsnp_containers
        )
    
    except subprocess.CalledProcessError as e:
        error_message = f"Error fetching podman containers: {str(e)}\nStderr: {e.stderr}"
        print(error_message)
        return PodmanContainersResponse(
            normal_containers=[],
            sevsnp_containers=[],
            error=error_message
        )
    
    except Exception as e:
        error_message = f"Unexpected error: {str(e)}"
        print(error_message)
        return PodmanContainersResponse(
            normal_containers=[],
            sevsnp_containers=[],
            error=error_message
        )


@router.post("")
def perform_tee_operation(teeInfo: TeeOperationInfo):
    print(f"Received TEE operation request: {teeInfo.operation} for container {teeInfo.containerName}")
    
    # Path to the tee-migration.sh script
    script_path = "/home/ubuntu/meierm78/ContMigration-VT1/scripts/migration/tee-migration.sh"

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_path = f"{BASE_LOG_PATH}/{teeInfo.containerName}/{timestamp.replace(':', '-')}_{teeInfo.containerName}"

    try:
        # Determine source and destination based on operation
        if teeInfo.operation == "encapsulate":
            src_vm = NORMAL_VM
            dest_vm = SEV_SNP_VM
        else:  # decapsulate
            src_vm = SEV_SNP_VM
            dest_vm = NORMAL_VM
            
        # Execute the tee-migration.sh script
        print(f"Executing command: {script_path} {teeInfo.containerName} {src_vm} {dest_vm}")
        # Add SSH key path as an environment variable for the script
        env = os.environ.copy()
        env["SSH_KEY_PATH"] = os.path.expanduser("~/.ssh/id_rsa")
        
        result = subprocess.run(
            [script_path, teeInfo.containerName, src_vm, dest_vm, log_path],
            capture_output=True,
            text=True,
            check=False,  # Don't raise exception on non-zero exit
            env=env
        )
        
        print(f"Command exit code: {result.returncode}")
        print(f"Command stdout: {result.stdout}")
        print(f"Command stderr: {result.stderr}")
        
        # Log the operation result with output/error details
        success = result.returncode == 0
        log_operation(
            teeInfo.containerName, 
            teeInfo.operation, 
            success, 
            src_vm, 
            dest_vm,
            log_path,
            output=result.stdout if success else None,
            error=result.stderr if not success else None
        )
        
        if success:
            return {
                "success": True,
                "message": f"TEE operation completed successfully: {teeInfo.operation}",
                "details": result.stdout
            }
        else:
            error_details = result.stderr if result.stderr else result.stdout
            return {
                "success": False,
                "message": f"TEE operation failed with exit code {result.returncode}",
                "details": error_details
            }
    except subprocess.CalledProcessError as e:
        error_message = f"TEE operation failed: {str(e)}"
        print(f"Error: {error_message}")
        print(f"Command stderr: {e.stderr}")
        return {
            "success": False,
            "message": error_message,
            "details": e.stderr
        }
    except Exception as e:
        error_message = f"Error during TEE operation: {str(e)}"
        print(f"Exception: {error_message}")
        return {
            "success": False, 
            "message": error_message,
            "details": ""
        }

@router.get("/operations")
def get_operation_history():
    """Get the history of TEE operations"""
    try:
        log_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'logs')
        log_file = os.path.join(log_dir, 'tee_operations.log')
        
        if not os.path.exists(log_file):
            return {"operations": []}
        
        with open(log_file, 'r') as f:
            log_entries = f.readlines()
            
        operations = []
        for entry in log_entries:
            if entry.strip():
                operations.append(entry.strip())
                
        return {"operations": operations}
    except Exception as e:
        error_message = f"Error retrieving operation history: {str(e)}"
        print(error_message)
        return {"operations": [], "error": error_message}
