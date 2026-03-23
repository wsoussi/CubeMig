#!/bin/bash
forensicAnalysis=false
AISuggestion=false
disableIstioSidecar=false
enableCheckpointPrepull="${ENABLE_CHECKPOINT_PREPULL:-false}"
preflightDestinationSetup="${PREFLIGHT_DESTINATION_SETUP:-true}"
preflightClusterChecks="${PREFLIGHT_CLUSTER_CHECKS:-true}"

# Cluster parameters must be provided explicitly
sourceCluster=""
destCluster=""
namespace="default"
cluster1Registry="${CLUSTER1_REGISTRY:-160.85.255.146:5000}"

# Parse command-line options
log_dir_specified=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -fa|--forensic-analysis) forensicAnalysis=true ;;
        -ai|--ai-suggestion) AISuggestion=true ;;
        -h|--help) echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] [--log-dir <path>] [--source-cluster <name>] [--dest-cluster <name>] [--namespace <ns>] [--disable-istio-sidecar] --"; exit 0 ;;
        --log-dir) 
            shift
            custom_log_dir=$1
            log_dir_specified=true
            ;;
        --source-cluster)
            shift
            sourceCluster=$1
            ;;
        --dest-cluster)
            shift
            destCluster=$1
            ;;
        --namespace)
            shift
            namespace=$1
            ;;
        --disable-istio-sidecar)
            disableIstioSidecar=true
            ;;
        *) 
            if [[ -z "$podName" ]]; then
                podName=$1
            fi
            ;;
    esac
    shift
done

if [ -z "$podName" ]; then
    echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] [--log-dir <path>] [--source-cluster <name>] [--dest-cluster <name>] [--namespace <ns>] [--disable-istio-sidecar] --"
    exit 1
fi

if [ -z "$sourceCluster" ] || [ -z "$destCluster" ]; then
    echo "Error: --source-cluster and --dest-cluster are required"
    exit 1
fi

if [ "$sourceCluster" = "$destCluster" ]; then
    echo "Error: source and destination cluster must be different"
    exit 1
fi

# If user did not provide a namespace, keep default above
# namespace already set to "default" unless overridden by --namespace

source /home/ubuntu/natwork_demo/CubeMig/scripts/migration/.env

insecure_registry_setup_attempted=false
criu_tcp_close_setup_attempted=false

# Function to log messages
log() {
  echo "$1" >> "$log_file"
}

# Function to handle errors
handle_error() {
  local errorMsg="$1"
  log "Error: $1"
  
  # If the error is related to pod not running, get more detailed information
  if [[ "$1" == "Pod is not running" ]]; then
    log "Collecting detailed diagnostics for pod $newPodName..."
    
    # Get pod details
    log "Pod status:"
    kubectl get pod $newPodName -o wide >> "$log_file" 2>&1 || log "Failed to get pod status"
    
    # Get pod description
    log "Pod description:"
    kubectl describe pod $newPodName >> "$log_file" 2>&1 || log "Failed to describe pod"
    
    # Get pod logs (with --previous to get terminated container logs)
    log "Pod logs (if available):"
    kubectl logs $newPodName --previous --tail=50 >> "$log_file" 2>&1 || log "No previous logs available"
    kubectl logs $newPodName --tail=50 >> "$log_file" 2>&1 || log "No logs available"
    
    # Get events related to this pod
    log "Pod events:"
    kubectl get events --field-selector involvedObject.name=$newPodName >> "$log_file" 2>&1 || log "Failed to get pod events"
    
    # Check image pull status
    log "Image pull status:"
    kubectl describe pod $newPodName | grep -A5 "Events:" >> "$log_file" 2>&1
    
    # Check if the pod is trying to pull the image
    log "Image pull details:"
    kubectl describe pod $newPodName | grep -A10 "Container $newPodName" >> "$log_file" 2>&1
    
    # Get registry image information
    log "Registry image check:"
    curl -s "http://$cluster1Registry/v2/$checkpoint_image_name/tags/list" >> "$log_file" 2>&1 || log "Failed to get registry image info"
  fi
  
  exit 1
}

context_exists() {
  local context_name="$1"
  kubectl config get-contexts -o name | grep -Fxq "$context_name"
}

context_exists "$sourceCluster" || handle_error "Unknown source cluster context: $sourceCluster"
context_exists "$destCluster" || handle_error "Unknown destination cluster context: $destCluster"

if [[ "$enableCheckpointPrepull" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  enableCheckpointPrepull=true
else
  enableCheckpointPrepull=false
fi

if [[ "$preflightDestinationSetup" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  preflightDestinationSetup=true
else
  preflightDestinationSetup=false
fi

if [[ "$preflightClusterChecks" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  preflightClusterChecks=true
else
  preflightClusterChecks=false
fi

kubectl config use-context "$sourceCluster" || handle_error "Failed to switch context to $sourceCluster"
kubectl config set-context --current --namespace="$namespace"
appName=$(kubectl get pods $podName -o jsonpath='{.metadata.labels.app}') || handle_error "Failed to get app name"

# Set the log directory
if [[ "$log_dir_specified" == true ]]; then
    log_dir="$custom_log_dir"
else
    log_dir="/home/ubuntu/contMigration_logs/$appName/$podName"
fi
log_file="$log_dir/migration_log.txt"

# Create log directory and file if they do not exist
mkdir -p "$log_dir" || handle_error "Failed to create log directory"
touch "$log_file" || handle_error "Failed to create log file"

# Function to convert time units to milliseconds
convert_to_ms() {
  local time_str=$1
  if [[ $time_str == *"ms" ]]; then
    echo "${time_str% ms}"
  elif [[ $time_str == *"µs" ]]; then
    echo "$time_str" | awk '{printf "%.3f", $1 / 1000}'
  else
    echo "0"
  fi
}

sanitize_k8s_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g; s/-+/-/g'
}

prepull_image_on_destination() {
  local image_ref="$1"
  local run_id="$2"
  local step_name="$3"
  local attempt="${4:-1}"
  local template="/home/ubuntu/teemig/CubeMig/scripts/migration/yaml/prepull-base-image-daemonset.yaml"
  local safe_image_name
  local ds_name
  local ds_manifest
  local escaped_image_ref

  if [[ ! -f "$template" ]]; then
    log "-- Warning: Pre-pull daemonset template not found, skipping base image pre-pull --"
    return 0
  fi

  safe_image_name=$(sanitize_k8s_name "${containerName:-prepull}")
  ds_name="prepull-${safe_image_name}-${step_name}-${run_id}"
  ds_name="${ds_name:0:63}"
  ds_name="${ds_name%-}"
  ds_manifest="${log_dir}/${ds_name}.yaml"

  escaped_image_ref=$(printf '%s\n' "$image_ref" | sed -e 's/[\/&]/\\&/g')
  sed -e "s/__DS_NAME__/${ds_name}/g" \
      -e "s/__IMAGE_REF__/${escaped_image_ref}/g" \
      "$template" > "$ds_manifest" || handle_error "Failed to generate pre-pull daemonset manifest"

  log "-- Pre-pulling image \"$image_ref\" on destination cluster using daemonset \"$ds_name\" --"
  kubectl apply -f "$ds_manifest" >> "$log_file" 2>&1 || handle_error "Failed to apply pre-pull daemonset"

  # Best-effort wait: give kubelet time to pull the image on destination nodes.
  sleep 20
  kubectl -n kube-system get events --field-selector reason=Pulled >> "$log_file" 2>&1 || true

  # Detect the common HTTP/HTTPS mismatch from kubelet event text.
  if kubectl -n kube-system describe pods -l "app=${ds_name}" 2>/dev/null | grep -q "http: server gave HTTP response to HTTPS client"; then
    log "-- Detected registry TLS mismatch while pre-pulling $image_ref --"
    kubectl delete -f "$ds_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || true

    if [[ "$attempt" -eq 1 ]]; then
      ensure_insecure_registry_on_destination
      prepull_image_on_destination "$image_ref" "$run_id" "$step_name" 2
      return $?
    fi

    handle_error "Pre-pull failed after insecure-registry setup attempt for image: $image_ref"
  fi

  kubectl delete -f "$ds_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || log "-- Warning: Failed to delete pre-pull daemonset --"
  log "-- Pre-pull daemonset cleanup complete for $image_ref --"
}

ensure_insecure_registry_on_destination() {
  local setup_manifest="/home/ubuntu/teemig/CubeMig/scripts/utils/setup/insecure-registry-daemonset.yaml"

  if [[ "$insecure_registry_setup_attempted" == true ]]; then
    log "-- Insecure-registry setup already attempted in this migration run; skipping --"
    return 0
  fi

  if [[ ! -f "$setup_manifest" ]]; then
    handle_error "Insecure-registry setup manifest not found: $setup_manifest"
  fi

  insecure_registry_setup_attempted=true
  log "-- Applying on-demand insecure-registry daemonset (destination cluster) --"
  kubectl apply -f "$setup_manifest" >> "$log_file" 2>&1 || handle_error "Failed to apply insecure-registry daemonset"

  # Give daemonset time to write config/restart CRI-O where needed.
  sleep 20
  kubectl -n kube-system get pods -l app=setup-insecure-registry -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l app=setup-insecure-registry --tail=50 >> "$log_file" 2>&1 || true

  # The setup is only needed on demand; do not keep it running permanently.
  kubectl delete -f "$setup_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || log "-- Warning: Failed to delete insecure-registry daemonset --"
  log "-- On-demand insecure-registry setup completed and cleaned up --"
}

ensure_criu_tcp_close_on_destination() {
  local setup_manifest="/home/ubuntu/teemig/CubeMig/scripts/utils/setup/criu-tcp-close-daemonset.yaml"

  if [[ "$criu_tcp_close_setup_attempted" == true ]]; then
    log "-- CRIU tcp-close setup already attempted in this migration run; skipping --"
    return 0
  fi

  if [[ ! -f "$setup_manifest" ]]; then
    handle_error "CRIU tcp-close setup manifest not found: $setup_manifest"
  fi

  criu_tcp_close_setup_attempted=true
  log "-- Applying preflight CRIU tcp-close daemonset (destination cluster) --"
  kubectl apply -f "$setup_manifest" >> "$log_file" 2>&1 || handle_error "Failed to apply CRIU tcp-close daemonset"

  sleep 10
  kubectl -n kube-system get pods -l app=setup-criu-tcp-close -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l app=setup-criu-tcp-close --tail=50 >> "$log_file" 2>&1 || true

  kubectl delete -f "$setup_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || log "-- Warning: Failed to delete CRIU tcp-close daemonset --"
  log "-- Preflight CRIU tcp-close setup completed and cleaned up --"
}

run_destination_cluster_checks() {
  log "-- Destination cluster checks started --"
  log "-- Context: $destCluster | Namespace: $namespace --"

  # API server / client versions
  kubectl version >> "$log_file" 2>&1 || log "-- Warning: Failed to collect kubectl version --"

  # Node readiness and runtime matrix (kubelet/container runtime/kernel/os)
  kubectl get nodes -o wide >> "$log_file" 2>&1 || log "-- Warning: Failed to list nodes --"
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" | ready="}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{" | kubelet="}{.status.nodeInfo.kubeletVersion}{" | runtime="}{.status.nodeInfo.containerRuntimeVersion}{" | kernel="}{.status.nodeInfo.kernelVersion}{" | os="}{.status.nodeInfo.osImage}{"\n"}{end}' >> "$log_file" 2>&1 || true

  # Quick API health probe from kubectl side
  kubectl get --raw='/readyz?verbose' >> "$log_file" 2>&1 || log "-- Warning: Failed to query API readyz endpoint --"

  # Helpful inventory for Istio-related traffic switch debugging
  kubectl get virtualservice -A >> "$log_file" 2>&1 || log "-- Warning: Failed to list VirtualServices --"

  log "-- Destination cluster checks completed --"
}

run_global_cluster_checks() {
  log "-- Global preflight checks started --"

  log "-- Source cluster preflight checks started --"
  kubectl config use-context "$sourceCluster" >> "$log_file" 2>&1 || handle_error "Failed to switch context to $sourceCluster for preflight checks"
  kubectl config set-context --current --namespace="$namespace" >> "$log_file" 2>&1 || true
  kubectl version >> "$log_file" 2>&1 || log "-- Warning: Failed to collect kubectl version on source cluster --"
  kubectl get nodes -o wide >> "$log_file" 2>&1 || log "-- Warning: Failed to list source cluster nodes --"
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" | ready="}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{" | kubelet="}{.status.nodeInfo.kubeletVersion}{" | runtime="}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}' >> "$log_file" 2>&1 || true
  log "-- Source cluster preflight checks completed --"

  kubectl config use-context "$destCluster" >> "$log_file" 2>&1 || handle_error "Failed to switch context to $destCluster for preflight checks"
  kubectl config set-context --current --namespace="$namespace" >> "$log_file" 2>&1 || true
  run_destination_cluster_checks

  kubectl config use-context "$sourceCluster" >> "$log_file" 2>&1 || handle_error "Failed to switch context back to $sourceCluster after preflight checks"
  kubectl config set-context --current --namespace="$namespace" >> "$log_file" 2>&1 || true
  currentCluster="$sourceCluster"

  log "-- Global preflight checks completed --"
}

resolve_base_image_for_prepull() {
  local source_ref="$1"
  local fallback_default="${BASE_IMAGE_PREPULL_FALLBACK:-}"

  if [[ "$source_ref" == *":checkpoint"* ]]; then
    if [[ -n "$fallback_default" ]]; then
      echo "$fallback_default"
      return
    fi

    # App-specific default fallback for chained mmt-probe migrations.
    if [[ "${containerName:-}" == mmt-probe* ]]; then
      echo "ghcr.io/montimage/mmt-probe:latest"
      return
    fi
  fi

  echo "$source_ref"
}

summarize_performance() {
  checkpoint_info=$(checkpointctl inspect "$checkpointfile" --stats)
  freezing_time=$(echo "$checkpoint_info" | grep -E '^\s*├── Freezing time:' | awk -F': ' '{print $2}')
  frozen_time=$(echo "$checkpoint_info" | grep -E '^\s*├── Frozen time:' | awk -F': ' '{print $2}')
  memdump_time=$(echo "$checkpoint_info" | grep -E '^\s*├── Memdump time:' | awk -F': ' '{print $2}')
  memwrite_time=$(echo "$checkpoint_info" | grep -E '^\s*├── Memwrite time:' | awk -F': ' '{print $2}')
  # Convert times to milliseconds and sum them using awk
  total_dump_time_ms=$(awk -v fz=$(convert_to_ms "$freezing_time") \
                          -v fn=$(convert_to_ms "$frozen_time") \
                          -v md=$(convert_to_ms "$memdump_time") \
                          -v mw=$(convert_to_ms "$memwrite_time") \
                          'BEGIN {print fz + fn + md + mw}')
  
  cat <<EOF >> "$log_dir/performance_summary.txt"
Performance Summary
-------------------
--- CRIU dump performance ---
Freezing Time: $freezing_time 
Frozen Time: $frozen_time
Memdump Time: $memdump_time
Memwrite Time: $memwrite_time
Total Dump Time: ${total_dump_time_ms} ms
-------------------
--- Migration performance ---
Checkpoint Creation: $checkpointTime ms
Checkpoint Location: $latestCheckpointTime ms
Permission Change: $permissionTime ms
Image Creation: $newImageTime ms
Image Push: $pushImageTime ms
Pod Ready: $podReadyTime ms
Total: $migrationTotalTime ms
-------------------
--- Cleanup performance ---
Source pod deletion time: $podDeletionTime ms
EOF
}

generate_ai_suggestion() {
  # Read the contents of the forensic analysis file and save it to a variable
  forensicReport=$(cat "$log_dir/forensic_report.txt" | jq -Rs .)

  # Define the system instruction
  systemInstruction="You are a professional IT security analyst specializing in container security. Your task is to analyze \`checkpointctl\` output provided by the user and generate a detailed security assessment. Specifically: \n- Identify and explain any issues, vulnerabilities, or misconfigurations present in the container based on the report.\n- Suggest corrective actions to address each identified issue.\n- Hypothesize potential attacks or threats that could exploit these vulnerabilities and explain the potential impact of these attacks.\n- Make one hypothesis about what attack happened in this container\n\nYour responses should be clear, concise, and professional, aimed at helping the user improve the container's security posture effectively. Use technical language appropriate for IT professionals and provide actionable recommendations.\n\nIt is possible that attacks come in a base64 encoded command. Make sure to decrypt the base64 encoded string to get more information about the attack.\n\n\nThe running app is a spring boot application.\nThe fact that these files are changed is required by the application and should not be considered as an issue:\n- etc/mtab\n- run/secrets/kubernetes.io/\n- run/secrets/kubernetes.io/serviceaccount/\n- tmp/hsperfdata_root/1"

  # Use the variables inside the curl command
  AIOutput=$(curl "https://api.groq.com/openai/v1/chat/completions" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${GROQ_API_KEY}" \
    -d "{
          \"messages\": [
            {
              \"role\": \"system\",
              \"content\": \"$systemInstruction\"
            },
            {
              \"role\": \"user\",
              \"content\": $forensicReport
            }
          ],
          \"model\": \"llama-3.3-70b-versatile\",
          \"temperature\": 1,
          \"max_tokens\": 1024,
          \"top_p\": 1,
          \"stream\": false,
          \"stop\": null
        }") || handle_error "Failed to get AI suggestion"

  ai_suggestion=$(echo "$AIOutput" | jq -r '.choices[0].message.content')
  model=$(echo "$AIOutput" | jq -r '.model')
  ai_queue_time=$(echo "$AIOutput" | jq -r '.usage.queue_time' | awk '{print $1 * 1000}')
  ai_prompt_time=$(echo "$AIOutput" | jq -r '.usage.prompt_time' | awk '{print $1 * 1000}')
  ai_completion_time=$(echo "$AIOutput" | jq -r '.usage.completion_time' | awk '{print $1 * 1000}')
  ai_total_time=$(echo "$AIOutput" | jq -r '.usage.total_time' | awk '{print $1 * 1000}')
  
  # Create a new file and save the values of model and ai_suggestion
  ai_suggestion_file="$log_dir/ai_suggestion.txt"
  echo "Model: $model" > "$ai_suggestion_file"
  echo "AI Suggestion: $ai_suggestion" >> "$ai_suggestion_file"

      cat <<EOF >> "$log_dir/performance_summary.txt"
--- AI generation performance ---
Queue Time: $ai_queue_time ms
Prompt Time: $ai_prompt_time ms
Completion Time: $ai_completion_time ms
Total Time: $ai_total_time ms
-------------------
EOF

}

log "Starting migration for $podName"

currentCluster=$(kubectl config current-context) || handle_error "Failed to get current context"
log "Source cluster: $currentCluster"

log "Target cluster: $destCluster"
log "Namespace: $namespace"
log "Disable Istio sidecar: $disableIstioSidecar"
log "Enable checkpoint pre-pull: $enableCheckpointPrepull"
log "Preflight destination setup: $preflightDestinationSetup"
log "Preflight cluster checks: $preflightClusterChecks"

log "Forensic analysis: $forensicAnalysis"
log "AI suggestion: $AISuggestion"

if [[ "$preflightClusterChecks" == true ]]; then
  run_global_cluster_checks
else
  log "-- Global preflight checks skipped by feature flag --"
  log "-- Set PREFLIGHT_CLUSTER_CHECKS=true to enable global cluster checks --"
fi


# Step 2: Get pod, container names, and node where the pod is running
containerName=$(kubectl get pods $podName -o jsonpath='{.spec.containers[0].name}') || handle_error "Failed to get container name"
nodename=$(kubectl get pods $podName -o jsonpath='{.spec.nodeName}') || handle_error "Failed to get node name"
# Step 3: Checkpoint via curl

log "-- Creating checkpoint for $podName on $nodename --"

migrationStartTime=$(date +%s%3N)

startTime=$(date +%s%3N)
checkpoint_output=$(curl -sk -X POST "https://$nodename:10250/checkpoint/${namespace}/${podName}/${containerName}" \
  --key /home/ubuntu/.kube/pki/$currentCluster-apiserver-kubelet-client.key \
  --cacert /home/ubuntu/.kube/pki/$currentCluster-ca.crt \
  --cert /home/ubuntu/.kube/pki/$currentCluster-apiserver-kubelet-client.crt) || handle_error "Failed to create checkpoint"
checkpointTime=$(($(date +%s%3N) - $startTime))
log "checkpoint output: $checkpoint_output"
log "-- Checkpoint created --"

log "------------------------------------------------------------------"

log "-- Determining latest checkpoint for ${podName} --"

startTime=$(date +%s%3N)
# Step 4: Get path to newest checkpoint file with node name incorporated
checkpointfile=$(ls -1t /home/ubuntu/nfs/checkpoints/${nodename}/checkpoint-${podName}_${namespace}-${containerName}-*.tar | head -n 1)
latestCheckpointTime=$(($(date +%s%3N) - $startTime))

log "-- Latest checkpoint found --"

log "------------------------------------------------------------------"

log "-- Changing permissions for checkpoint file --"

startTime=$(date +%s%3N)
# Step 4.5: Change permissions of the checkpoint file
sudo chmod a+rwx "$checkpointfile" || handle_error "Failed to change permissions of checkpoint file"
permissionTime=$(($(date +%s%3N) - $startTime))

log "-- Permissions changed --"

log "------------------------------------------------------------------"

source_image_ref=$(kubectl get pod $podName -o jsonpath='{.spec.containers[0].image}') || handle_error "Failed to get image name"

log "-- Convert checkpoint into image --"

startTime=$(date +%s%3N)
# Step 5: Convert checkpoint to image
log "Checkpoint image name: $source_image_ref"
log "Checkpoint file: $checkpointfile"
newcontainer=$(buildah from --tls-verify=false "$source_image_ref") || handle_error "Failed to create new container"
buildah add $newcontainer $checkpointfile / || handle_error "Failed to add checkpoint file to container"
buildah config --annotation=io.kubernetes.cri-o.annotations.checkpoint.name=${containerName} $newcontainer || handle_error "Failed to add checkpoint annotation to container"
buildah config --annotation=io.container.manager=crio $newcontainer || handle_error "Failed to add crio annotation to container"
newImageTime=$(($(date +%s%3N) - $startTime))

checkpoint_image_name=$(image="$source_image_ref" && image=${image##*/} && image=${image%%:*} && echo "$image") || handle_error "Failed to get image name"
checkpoint_image_tag="checkpoint-$(date +%Y%m%d%H%M%S)-${RANDOM}"
local_checkpoint_image_ref="${checkpoint_image_name}:${checkpoint_image_tag}"
registry_checkpoint_image_ref="${cluster1Registry}/${checkpoint_image_name}:${checkpoint_image_tag}"

log "Checkpoint image name: $checkpoint_image_name"
log "Checkpoint image tag: $checkpoint_image_tag"
log "-- Commiting new image --"

startTime=$(date +%s%3N)
#sudo buildah commit $newcontainer $checkpoint_image_name:checkpoint
buildah commit $newcontainer "$local_checkpoint_image_ref" || handle_error "Failed to commit new image"
buildah rm $newcontainer || handle_error "Failed to remove new container"

log "-- Pushing image \"$registry_checkpoint_image_ref\" to local registry --"
# Step 6: Push the image to local registry
buildah push --tls-verify=false "localhost/$local_checkpoint_image_ref" "$registry_checkpoint_image_ref" || handle_error "Failed to push image to local registry"
pushImageTime=$(($(date +%s%3N) - $startTime))

log "-- Image pushed onto local registy --"

log "------------------------------------------------------------------"

# Step 9: Apply the updated YAML file
kubectl config use-context "$destCluster" || handle_error "Failed to switch context to $destCluster"
kubectl config set-context --current --namespace="$namespace"
if [[ "$preflightDestinationSetup" == true ]]; then
  log "-- Destination preflight started (insecure-registry + CRIU tcp-close) --"
  ensure_insecure_registry_on_destination
  ensure_criu_tcp_close_on_destination
  log "-- Destination preflight completed --"
else
  log "-- Destination preflight skipped by feature flag --"
  log "-- Set PREFLIGHT_DESTINATION_SETUP=true to enable destination setup --"
fi
timestampSuffix=$(date +"%Y%m%d-%H%M%S")
prepull_run_id="$(echo "$timestampSuffix" | tr -d '-')"
prepull_base_image_ref="$(resolve_base_image_for_prepull "$source_image_ref")"
log "-- Pre-pull step (base image) started --"
log "-- Base image chosen for pre-pull: $prepull_base_image_ref --"
prepull_image_on_destination "$prepull_base_image_ref" "$prepull_run_id" "base"
log "-- Pre-pull step (base image) completed --"
if [[ "$enableCheckpointPrepull" == true ]]; then
  log "-- Pre-pull step (checkpoint image) started --"
  prepull_image_on_destination "$registry_checkpoint_image_ref" "$prepull_run_id" "checkpoint"
  log "-- Pre-pull step (checkpoint image) completed --"
else
  log "-- Pre-pull step (checkpoint image) skipped by feature flag --"
  log "-- Set ENABLE_CHECKPOINT_PREPULL=true to enable checkpoint pre-pull --"
fi

log "-- Applying restore yaml file --"

startTime=$(date +%s%3N)
templateContainerName="$containerName"
if [[ "$templateContainerName" == *"-restore-"* ]]; then
  templateContainerName="${templateContainerName%%-restore-*}"
elif [[ "$templateContainerName" == *"-restore" ]]; then
  templateContainerName="${templateContainerName%-restore}"
fi

newPodName="${templateContainerName}-restore-${timestampSuffix}"
newPodName="${newPodName:0:63}"
restoreTemplate="/home/ubuntu/teemig/CubeMig/scripts/migration/yaml/restore_${templateContainerName}.yaml"
restoreManifest="${log_dir}/restore_${newPodName}.yaml"

if [[ ! -f "$restoreTemplate" ]]; then
  handle_error "Restore template not found: $restoreTemplate"
fi

sed -e "s/${templateContainerName}-restore/${newPodName}/g" \
    -e "s|^\([[:space:]]*image:[[:space:]]*\).*|\1${registry_checkpoint_image_ref}|g" \
    "$restoreTemplate" > "$restoreManifest" || handle_error "Failed to generate restore yaml file"

if [[ "$disableIstioSidecar" == true ]]; then
  if grep -q '^  annotations:' "$restoreManifest"; then
    if ! grep -q 'sidecar.istio.io/inject' "$restoreManifest"; then
      sed -i '/^  annotations:/a\    sidecar.istio.io/inject: "false"' "$restoreManifest" || handle_error "Failed to set sidecar disable annotation"
    else
      sed -i 's/^[[:space:]]*sidecar\.istio\.io\/inject:.*/    sidecar.istio.io\/inject: "false"/' "$restoreManifest" || handle_error "Failed to update sidecar disable annotation"
    fi
  else
    sed -i '/^  name:/a\  annotations:\n    sidecar.istio.io/inject: "false"' "$restoreManifest" || handle_error "Failed to insert annotations block for sidecar disable"
  fi
  log "-- Added sidecar.istio.io/inject=false to restore manifest for debug run --"
fi

kubectl apply -f "$restoreManifest" || handle_error "Failed to apply restore yaml file"

log "-- Waiting for the new pod \"$newPodName\" to be ready --"
# Wait with timeout and fail fast on known terminal container errors.
wait_timeout_seconds=300
poll_interval_seconds=5
elapsed_seconds=0
pod_running=false

while (( elapsed_seconds < wait_timeout_seconds )); do
    pod_phase=$(kubectl get pod "$newPodName" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    waiting_reasons=$(kubectl get pod "$newPodName" -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}' 2>/dev/null || true)

    if [[ "$pod_phase" == "Running" ]]; then
        pod_running=true
        break
    fi

    if [[ "$waiting_reasons" == *"CreateContainerError"* ]] || [[ "$waiting_reasons" == *"RunContainerError"* ]] || [[ "$waiting_reasons" == *"ErrImagePull"* ]] || [[ "$waiting_reasons" == *"ImagePullBackOff"* ]]; then
        log "-- Fail-fast: Detected terminal pod startup error for $newPodName --"
        log "-- Pod phase: $pod_phase --"
        log "-- Container waiting reasons: $waiting_reasons --"
        log "-- Detailed pod diagnostics (including CRIU restore hints) --"
        pod_describe_output=$(kubectl describe pod "$newPodName" 2>/dev/null || true)
        if [[ -n "$pod_describe_output" ]]; then
            printf '%s\n' "$pod_describe_output" >> "$log_file"
        else
            log "Failed to describe pod in fail-fast path"
        fi

        restore_log_path=$(printf '%s\n' "$pod_describe_output" | sed -n 's/.*log file: \([^"]*\).*/\1/p' | tail -n 1)
        if [[ -n "$restore_log_path" ]]; then
            log "-- Detected restore log path on destination node: $restore_log_path --"
            restore_container_token="${restore_log_path#*/overlay-containers/}"
            restore_container_token="${restore_container_token%%/userdata/*}"
            if [[ "$restore_container_token" =~ ^[a-f0-9]{12,64}$ ]]; then
                log "-- Parsed overlay container ID: $restore_container_token --"
            elif [[ -n "$restore_container_token" ]]; then
                log "-- Restore path token is not an overlay ID: $restore_container_token --"
                log "-- Note: overlay-containers usually uses runtime IDs, not pod names --"
                log "-- On destination node, resolve runtime ID with: sudo crictl ps -a --name \"$newPodName\" --"
                log "-- Then inspect logs with: sudo ls -la /run/containers/storage/overlay-containers/<CONTAINER_ID>/userdata --"
            fi
        else
            log "-- No restore log path detected in pod events --"
        fi
        handle_error "Pod startup failed: $waiting_reasons"
    fi

    sleep "$poll_interval_seconds"
    elapsed_seconds=$((elapsed_seconds + poll_interval_seconds))
done

if [[ "$pod_running" == true ]]; then
  log "-- $newPodName is running --"
  podReadyTime=$(($(date +%s%3N) - $startTime))

  selected_virtualservice=""
  kubectl config use-context "$currentCluster" || handle_error "Failed to switch context to $currentCluster"
  kubectl config set-context --current --namespace="$namespace"
  if kubectl get virtualservice "$appName" >/dev/null 2>&1; then
    selected_virtualservice="$appName"
  elif kubectl get virtualservice routing-demo >/dev/null 2>&1; then
    selected_virtualservice="routing-demo"
  fi

  if [[ "$containerName" == "mmt-probe" ]]; then
    log "-- Detected mmt-probe container, switching mirroring rule --"
    if [[ -n "$selected_virtualservice" ]]; then
      kubectl patch virtualservice "$selected_virtualservice" --type='json' -p='[
        {
          "op": "replace",
          "path": "/spec/http/0/mirrors/0/destination/subset",
          "value": "v2-monitor"
        }
      ]' || handle_error "Failed to redirect mirrored traffic to new app"
    else
      log "-- Warning: No VirtualService found (expected \"$appName\" or \"routing-demo\"); skipping mirror switch --"
    fi

  elif [[ "$namespace" == "istio-enabled" ]]; then
    log "-- Switching traffic to the new pod --"
    if [[ -n "$selected_virtualservice" ]]; then
      kubectl patch virtualservice "$selected_virtualservice" --type='json' -p='[
        {
          "op": "replace",
          "path": "/spec/http/0/route/0/destination/subset",
          "value": "v2"
        }
      ]' || handle_error "Failed to redirect traffic to new app"
    else
      log "-- Warning: No VirtualService found (expected \"$appName\" or \"routing-demo\"); skipping traffic switch --"
    fi
  fi
else
  log "-- Warning: $newPodName did not start within 5 minutes, but migration artifacts are in place --"
  log "-- You may need to check the pod status manually --"
  podReadyTime=$(($(date +%s%3N) - $startTime))
fi

migrationTotalTime=$(($(date +%s%3N) - $migrationStartTime))

log "------------------------------------------------------------------"

log "--- Deleting old pod ---"
podDeletionStartTime=$(date +%s%3N)
kubectl config use-context "$sourceCluster" || handle_error "Failed to switch context to $sourceCluster"
kubectl config set-context --current --namespace="$namespace"
kubectl delete pod $podName || handle_error "Failed to delete pod"
podDeletionTime=$(($(date +%s%3N) - $podDeletionStartTime))
log "-- Old pod \"$podName\" deleted --"

log "------------------------------------------------------------------"

log "-- Summarizing migration performance --"
summarize_performance
log "-- Performance summary created --"


if [ "$forensicAnalysis" == true ]; then
  log "-- Performing forensic analysis --"
  sudo chmod 770 /home/ubuntu/teemig/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh
  /home/ubuntu/teemig/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh "$checkpointfile" "$log_dir" || handle_error "Failed to perform forensic analysis"
  log "-- Forensic analysis complete --"
fi

if [ "$forensicAnalysis" == true ] && [ "$AISuggestion" == true ]; then
  log "-- Asking AI for suggestion --"
  generate_ai_suggestion
  log "-- AI suggestion generated --"
fi

log "------------------------------------------------------------------"

# Improved cleanup: Clean by application name, not individual pod names
# Extract base app name (vuln-spring, vuln-redis, atomic-red, etc.)
baseAppName=$(echo "$containerName" | sed 's/-[0-9].*$//')
checkpointDir="/home/ubuntu/nfs/checkpoints/${nodename}/checkpoint-*_${namespace}-${baseAppName}-*.tar"
log "-- Deleting old checkpoints for application ${baseAppName} if more than 5 are saved --"

checkpointCount=$(ls $checkpointDir 2>/dev/null | wc -l)
if [ "$checkpointCount" -gt 5 ]; then
  excessCount=$((checkpointCount - 5))
  log "-- $checkpointCount checkpoint files for ${baseAppName} on $nodename detected. Deleting oldest $excessCount files... --"
  
  # Delete the oldest files to keep only 5 (more efficient approach)
  filesToDelete=$(ls -1t $checkpointDir | tail -n $excessCount)
  for fileToDelete in $filesToDelete; do
    log "-- Deleting $fileToDelete --"
    rm "$fileToDelete" 2>/dev/null || log "-- Warning: Could not delete $fileToDelete --"
  done
  
  # Verify final count
  finalCount=$(ls $checkpointDir 2>/dev/null | wc -l)
  log "-- Cleanup complete. ${baseAppName} now has $finalCount checkpoint files --"
else
  log "-- $checkpointCount checkpoint files for ${baseAppName} on $nodename detected (within limit) --"
fi

log "------------------------------------------------------------------"
log "-- Migration complete --"

exit 0
