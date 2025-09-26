#!/bin/bash
forensicAnalysis=false
AISuggestion=false

# Parse command-line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -fa|--forensic-analysis) forensicAnalysis=true ;;
        -ai|--ai-suggestion) AISuggestion=true ;;
        -h|--help) echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] --"; exit 0 ;;
        *) podName=$1 ;;
    esac
    shift
done

if [ -z "$podName" ]; then
    echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] --"
    exit 1
fi

source /home/ubuntu/natwork_demo/CubeMig/scripts/migration/.env


kubectl config use-context cluster1 || handle_error "Failed to switch context to cluster1"
appName=$(kubectl get pods $podName -o jsonpath='{.metadata.labels.app}') || handle_error "Failed to get app name"

log_dir="/home/ubuntu/contMigration_logs/$appName/$podName"
log_file="$log_dir/migration_log.txt"

# Create log directory and file if they do not exist
mkdir -p "$log_dir" || handle_error "Failed to create log directory"
touch "$log_file" || handle_error "Failed to create log file"

# Function to log messages
log() {
  echo "$1" >> "$log_file"
}

# Function to handle errors
handle_error() {
  log "Error: $1"
  exit 1
}

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

destCluster="cluster2"
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
checkpoint_output=$(curl -sk -X POST "https://$nodename:10250/checkpoint/default/${podName}/${containerName}" \
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
checkpointfile=$(ls -1t /home/ubuntu/nfs/checkpoints/${nodename}/checkpoint-${podName}_default-${containerName}-*.tar | head -n 1)
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
buildah config --annotation=io.kubernetes.cri-o.annotations.checkpoint.name=${containerName} $newcontainer || handle_error "Failed to add annotation to container"
newImageTime=$(($(date +%s%3N) - $startTime))

checkpoint_image_name=$(kubectl get pod $podName -o jsonpath='{.spec.containers[0].image}' | cut -d'/' -f 2 | cut -d':' -f 1) || handle_error "Failed to get image name"
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

# Step 9: Switch to destination cluster and prepare
kubectl config use-context $destCluster || handle_error "Failed to switch context to $destCluster"

log "-- Ensuring original image is available on destination cluster --"

# Get both the image tag and the exact digest that was used in the original pod
original_image_tag=$(kubectl config use-context cluster1 > /dev/null && kubectl get pod $podName -o jsonpath='{.spec.containers[0].image}') || handle_error "Failed to get original image tag"
original_image_digest=$(kubectl config use-context cluster1 > /dev/null && kubectl get pod $podName -o jsonpath='{.status.containerStatuses[0].imageID}') || handle_error "Failed to get original image digest"

log "Original image tag: $original_image_tag"
log "Original image digest: $original_image_digest"

# Use the exact digest to ensure we get the same image that was used for the checkpoint
log "-- Pre-pulling exact original image by digest on destination cluster --"
temp_pod_name="image-puller-$(date +%s)"
kubectl run $temp_pod_name --image="$original_image_digest" --restart=Never --rm=true --command -- sleep 5 > /dev/null 2>&1 || true
log "-- Original image pull completed --"

kubectl config use-context $destCluster || handle_error "Failed to switch context to $destCluster"

log "-- Applying restore yaml file --"

startTime=$(date +%s%3N)
kubectl apply -f /home/ubuntu/natwork_demo/CubeMig/scripts/migration/yaml/restore_$appName.yaml || handle_error "Failed to apply restore yaml file"

newPodName=$appName-restore

log "-- Waiting for the new pod \"$newPodName\" to be ready --"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/$newPodName || handle_error "Pod is not running"
podReadyTime=$(($(date +%s%3N) - $startTime))

migrationTotalTime=$(($(date +%s%3N) - $migrationStartTime))

log "-- $newPodName running --"

log "------------------------------------------------------------------"

log "--- Deleting old pod ---"

kubectl config use-context cluster1 || handle_error "Failed to switch context to cluster1"
kubectl delete pod $podName || handle_error "Failed to delete pod"

log "-- Old pod \"$podName\" deleted --"

log "------------------------------------------------------------------"

log "-- Summarizing migration performance --"
summarize_performance
log "-- Performance summary created --"


if [ "$forensicAnalysis" == true ]; then
  log "-- Performing forensic analysis --"
  sudo chmod 770 /home/ubuntu/natwork_demo/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh
  /home/ubuntu/natwork_demo/CubeMig/scripts/utils/forensic_analysis/forensic_analysis.sh "$checkpointfile" "$log_dir" || handle_error "Failed to perform forensic analysis"
  log "-- Forensic analysis complete --"
fi

if [ "$forensicAnalysis" == true ] && [ "$AISuggestion" == true ]; then
  log "-- Asking AI for suggestion --"
  generate_ai_suggestion
  log "-- AI suggestion generated --"
fi

log "------------------------------------------------------------------"

checkpointDir="/home/ubuntu/nfs/checkpoints/${nodename}/checkpoint-*_default-${containerName}-*.tar"
log "-- Deleting oldest checkpoint if more than 5 are saved --"

if  [ "$(ls $checkpointDir | wc -l)" -gt 5 ]
      then
  log "-- More than 5 checkpoint files for $podName on $nodename detected. Deleting oldest one... --"
  deleteFile=$(ls -1t $checkpointDir | tail -n 1)
  log "-- Deleting $deleteFile --"
  rm "$(ls -1t $checkpointDir | tail -n 1)"
else
  log "-- 5 or less checkpoint files for $podName on $nodename detected --"
fi

log "------------------------------------------------------------------"
log "-- Migration complete --"

exit 0
