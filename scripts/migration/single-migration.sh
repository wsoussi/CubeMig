#!/bin/bash
forensicAnalysis=false
AISuggestion=false

# Defaults for optional variables
sourceCluster="cluster1"
destCluster="cluster2"
namespace="default"

# Parse command-line options
log_dir_specified=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -fa|--forensic-analysis) forensicAnalysis=true ;;
        -ai|--ai-suggestion) AISuggestion=true ;;
        -h|--help) echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] [--log-dir <path>] [--source-cluster <name>] [--dest-cluster <name>] [--namespace <ns>] --"; exit 0 ;;
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
        *) 
            if [[ -z "$podName" ]]; then
                podName=$1
            fi
            ;;
    esac
    shift
done

if [ -z "$podName" ]; then
    echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] --"
    exit 1
fi

# If user did not provide a namespace, keep default above
# namespace already set to "default" unless overridden by --namespace

source /home/ubuntu/natwork_demo/CubeMig/scripts/migration/.env

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
    curl -s http://10.0.0.180:5000/v2/$checkpoint_image_name/tags/list >> "$log_file" 2>&1 || log "Failed to get registry image info"
  fi
  
  exit 1
}

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

log "Forensic analysis: $forensicAnalysis"
log "AI suggestion: $AISuggestion"


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

checkpoint_image_name=$(kubectl get pod $podName -o jsonpath='{.spec.containers[0].image}') || handle_error "Failed to get image name"

log "-- Convert checkpoint into image --"

startTime=$(date +%s%3N)
# Step 5: Convert checkpoint to image
log "Checkpoint image name: $checkpoint_image_name"
log "Checkpoint file: $checkpointfile"
newcontainer=$(buildah from $checkpoint_image_name) || handle_error "Failed to create new container"
buildah add $newcontainer $checkpointfile / || handle_error "Failed to add checkpoint file to container"
buildah config --annotation=io.kubernetes.cri-o.annotations.checkpoint.name=${containerName} $newcontainer || handle_error "Failed to add checkpoint annotation to container"
buildah config --annotation=io.container.manager=crio $newcontainer || handle_error "Failed to add crio annotation to container"
newImageTime=$(($(date +%s%3N) - $startTime))

checkpoint_image_name=$(image=$(kubectl get pod "$podName" -o jsonpath='{.spec.containers[0].image}') && image=${image##*/} && image=${image%%:*} && echo "$image") || handle_error "Failed to get image name"

log "Checkpoint image name: $checkpoint_image_name"
log "-- Commiting new image --"

startTime=$(date +%s%3N)
#sudo buildah commit $newcontainer $checkpoint_image_name:checkpoint
buildah commit $newcontainer $checkpoint_image_name:checkpoint || handle_error "Failed to commit new image"
buildah rm $newcontainer || handle_error "Failed to remove new container"

log "-- Pushing image \"$checkpoint_image_name:checkpoint\" to local registry --"
# Step 6: Push the image to local registry
buildah push --tls-verify=false localhost/$checkpoint_image_name:checkpoint 10.0.0.180:5000/$checkpoint_image_name:checkpoint || handle_error "Failed to push image to local registry"
pushImageTime=$(($(date +%s%3N) - $startTime))

log "-- Image pushed onto local registy --"

log "------------------------------------------------------------------"

# Step 9: Apply the updated YAML file
kubectl config use-context "$destCluster" || handle_error "Failed to switch context to $destCluster"
kubectl config set-context --current --namespace="$namespace"

log "-- Applying restore yaml file --"

startTime=$(date +%s%3N)
kubectl apply -f /home/ubuntu/meierm78/CubeMig/scripts/migration/yaml/restore_$containerName.yaml || handle_error "Failed to apply restore yaml file"

newPodName=$containerName-restore

log "-- Waiting for the new pod \"$newPodName\" to be ready --"
# Wait with timeout to allow for image pulling and startup
if kubectl wait --for=jsonpath='{.status.phase}'=Running pod/$newPodName --timeout=300s; then
    log "-- $newPodName is running --"
    podReadyTime=$(($(date +%s%3N) - $startTime))
    if [[ "$containerName" == "mmt-probe" ]]; then
      log "-- Detected mmt-probe container, switching mirroring rule --"
      kubectl config use-context "$currentCluster" || handle_error "Failed to switch context to $currentCluster"
      kubectl config set-context --current --namespace="$namespace"

      kubectl patch virtualservice "$appName" --type='json' -p='[
        {
          "op": "replace",
          "path": "/spec/http/0/mirror/subset",
          "value": "v2-monitor"
        }
      ]' || handle_error "Failed to redirect mirrored traffic to new app"



    elif [[ "$namespace" == "istio-enabled" ]]; then
      log "-- Switching traffic to the new pod --"
      kubectl config use-context "$currentCluster" || handle_error "Failed to switch context to $currentCluster"
      kubectl config set-context --current --namespace="$namespace"

      kubectl patch virtualservice "$appName" --type='json' -p='[
        {
          "op": "replace",
          "path": "/spec/http/0/route/0/destination/subset",
          "value": "v2"
        }
      ]' || handle_error "Failed to redirect traffic to new app"
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
  sudo chmod 770 /home/ubuntu/meierm78/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh
  /home/ubuntu/meierm78/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh "$checkpointfile" "$log_dir" || handle_error "Failed to perform forensic analysis"
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
