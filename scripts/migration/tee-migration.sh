#!/bin/bash

# This script is used to migrate a podman container running in sous@bert.cloudlab.zhaw.ch to an SEV-SNP VM

# Usage: ./tee-migration.sh <container_name> <src_vm_name> <dest_vm_name> [cpu-cap-mode]

# Check if the container name and the source VM name and destination VM name are provided
# Check if the container name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <container_name>"
    exit 1
fi
# Check if the source VM name is provided
if [ -z "$2" ]; then
    echo "Usage: $0 <container_name> <src_vm_name>"
    exit 1
fi
# Check if the destination VM name is provided
if [ -z "$3" ]; then
    echo "Usage: $0 <container_name> <src_vm_name> <dest_vm_name> [cpu-cap-mode]"
    exit 1
fi

# Set the container name
CONTAINER_NAME="$1"
# Set the source VM name
SRC_VM_NAME="$2"
# Set the destination VM name
DEST_VM_NAME="$3"
# CRIU cpu capability mode: safe default to "cpu", configurable with arg 4 or CRIU_CPU_CAP
CRIU_CPU_CAP_MODE="${4:-${CRIU_CPU_CAP:-cpu}}"
# Set the SSH key to access both VMs
SSH_KEY="~/.ssh/id_rsa"

# define wich VM is SEV-SNP and which is non-SEV-SNP
if [[ "$SRC_VM_NAME" == *"192.168.122"* ]]; then
    SEV_SNP_VM="$SRC_VM_NAME"
    NON_SEV_SNP_VM="$DEST_VM_NAME"
else
    SEV_SNP_VM="$DEST_VM_NAME"
    NON_SEV_SNP_VM="$SRC_VM_NAME"
fi
# prepare customized ssh access for sev-snp VM and non-sev-snp VM: sev-snp VM is accessible via jump ssh -J $NON_SEV_SNP_VM $SEV_SNP_VM
SSH_ACCESS_SEV_SNP_VM="-i $SSH_KEY -J $NON_SEV_SNP_VM $SEV_SNP_VM"
SSH_ACCESS_NON_SEV_SNP_VM="-i $SSH_KEY $NON_SEV_SNP_VM"

# define source and destination VM access based on above ssh access
if [[ "$SRC_VM_NAME" == *"192.168.122"* ]]; then
    SRC_VM_ACCESS="$SSH_ACCESS_SEV_SNP_VM"
    DEST_VM_ACCESS="$SSH_ACCESS_NON_SEV_SNP_VM"
else
    SRC_VM_ACCESS="$SSH_ACCESS_NON_SEV_SNP_VM"
    DEST_VM_ACCESS="$SSH_ACCESS_SEV_SNP_VM"
fi

# define the checkpoint name
CHECKPOINT_NAME="$CONTAINER_NAME-checkpoint.tar.gz"

validate_criu_cpu_cap_mode() {
    case "$1" in
        cpu|fpu|ins|all|none|cpu,fpu|cpu,ins|fpu,ins|cpu,fpu,ins)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if ! validate_criu_cpu_cap_mode "$CRIU_CPU_CAP_MODE"; then
    echo "Error: Unsupported CRIU cpu-cap mode '$CRIU_CPU_CAP_MODE'. Allowed: cpu, fpu, ins, cpu,fpu, cpu,ins, fpu,ins, cpu,fpu,ins, all, none."
    exit 1
fi
if [[ "$CRIU_CPU_CAP_MODE" == "none" ]]; then
    echo "Error: CRIU cpu-cap mode 'none' is unsafe and not allowed by default. Use cpu or all (or another strict mode)."
    exit 1
fi


####### DO THE MIGRATION #######


# verify if the container is running in the source VM
if ! ssh $SRC_VM_ACCESS "sudo podman ps | grep \"$CONTAINER_NAME\""; then
    echo "Container $CONTAINER_NAME is not running in the source VM $SRC_VM_NAME"
    exit 1
else
    echo "Container $CONTAINER_NAME is running in the source VM $SRC_VM_NAME"
fi

# make a checkpoint of the container
if ! ssh $SRC_VM_ACCESS "sudo podman container checkpoint $CONTAINER_NAME --tcp-established --file-locks --cpu-cap=$CRIU_CPU_CAP_MODE -e ~/podman_checkpoints/$CONTAINER_NAME-checkpoint.tar.gz"; then
    echo "Failed to checkpoint the container $CONTAINER_NAME"
    exit 1
else
    echo "Container $CONTAINER_NAME checkpointed successfully"
fi

# add rights to all users to access and modify the podman checkpoints
if ! ssh $SRC_VM_ACCESS "sudo chmod 777 ~/podman_checkpoints/$CHECKPOINT_NAME"; then
    echo "Failed to add rights to all users to access and modify the podman checkpoints in the source VM $SRC_VM_NAME"
    exit 1
else
    echo "Rights added to all users to access and modify the podman checkpoints in the source VM $SRC_VM_NAME"
fi

# copy the checkpoint to the destination VM
if ! ssh $SRC_VM_ACCESS "sudo scp -i $SSH_KEY ~/podman_checkpoints/$CHECKPOINT_NAME $DEST_VM_NAME:~/podman_checkpoints/$CHECKPOINT_NAME"; then
    echo "Failed to copy the checkpoint to the destination VM $DEST_VM_NAME"
    exit 1
else
    echo "Checkpoint $CHECKPOINT_NAME copied to the destination VM $DEST_VM_NAME"
fi

# validate destination CPU compatibility before restore
if ! ssh $DEST_VM_ACCESS "set -e; tmp_dir=\$(mktemp -d); trap 'rm -rf \"\$tmp_dir\"' EXIT; tar -xzf ~/podman_checkpoints/$CHECKPOINT_NAME -C \"\$tmp_dir\"; cpuinfo_path=\$(find \"\$tmp_dir\" -type f -name cpuinfo.img | head -n 1); if [ -z \"\$cpuinfo_path\" ]; then echo \"ERROR: cpuinfo.img not found in checkpoint archive\" >&2; exit 2; fi; images_dir=\$(dirname \"\$cpuinfo_path\"); criu cpuinfo check -D \"\$images_dir\" --cpu-cap \"$CRIU_CPU_CAP_MODE\""; then
    echo "CPU capability check failed: target CPU is missing required CPU/instruction-set features."
    echo "source node: $SRC_VM_NAME"
    echo "target node: $DEST_VM_NAME"
    echo "checkpoint image: ~/podman_checkpoints/$CHECKPOINT_NAME"
    echo "cpu-cap mode: $CRIU_CPU_CAP_MODE"
    exit 1
else
    echo "CPU capability check passed for checkpoint $CHECKPOINT_NAME (mode: $CRIU_CPU_CAP_MODE)"
fi

# restore the container in the destination VM
if ! ssh $DEST_VM_ACCESS "sudo podman container restore --tcp-established --file-locks --cpu-cap=$CRIU_CPU_CAP_MODE --import ~/podman_checkpoints/$CHECKPOINT_NAME"; then
    echo "Failed to restore the container $CONTAINER_NAME in the destination VM $DEST_VM_NAME"
else
    echo "Container $CONTAINER_NAME restored successfully in the destination VM $DEST_VM_NAME"
fi

# start the container in the destination VM
if ! ssh $DEST_VM_ACCESS "sudo podman start $CONTAINER_NAME"; then
    echo "Failed to start the container $CONTAINER_NAME in the destination VM $DEST_VM_NAME"
else
    echo "Container $CONTAINER_NAME started successfully in the destination VM $DEST_VM_NAME"
fi