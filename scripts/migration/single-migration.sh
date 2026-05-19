#!/bin/bash
# Basic / cold stateful migration: CRIU checkpoint, wait until the .tar is visible on
# the migration host NFS mirror, chmod, then scale source to 0 (checkpoint finished
# writing; no further requests). Scaling before the archive exists can prevent the
# file from appearing on NFS (kubelet/pod teardown vs. sync).
forensicAnalysis=false
AISuggestion=false
disableIstioSidecar=false
skipCpuCompatCheck="${SKIP_CPU_COMPAT_CHECK:-false}"
cleanupIncompatibleMounts="${CLEANUP_INCOMPATIBLE_MOUNTS:-false}"
enableCheckpointPrepull="${ENABLE_CHECKPOINT_PREPULL:-false}"
preflightDestinationSetup="${PREFLIGHT_DESTINATION_SETUP:-true}"
preflightClusterChecks="${PREFLIGHT_CLUSTER_CHECKS:-true}"
normalizeCheckpointMounts="${NORMALIZE_CHECKPOINT_MOUNTS:-false}"
normalizeCheckpointMounts_cli_specified=false
skipCheckpointNormalization_explicit=false
checkpointNormalizeMounts="${CHECKPOINT_NORMALIZE_MOUNTS:-}"
criuCpuCapMode="${CRIU_CPU_CAP:-cpu}"

# Cluster parameters must be provided explicitly
sourceCluster=""
destCluster=""
namespace="default"
# Host:port of the registry where checkpoint images are pushed (typically the migration/Podman host, not a K8s node).
# MIGRATION_REGISTRY wins; CLUSTER1_REGISTRY is still read for backward compatibility with older .env files.
migrationRegistry="${MIGRATION_REGISTRY:-${CLUSTER1_REGISTRY:-160.85.255.146:5000}}"
PNET_WIREGUARD_MIGRATION_REGISTRY="${PNET_WIREGUARD_MIGRATION_REGISTRY:-10.10.10.1:5000}"

# Parse command-line options
log_dir_specified=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -fa|--forensic-analysis) forensicAnalysis=true ;;
        -ai|--ai-suggestion) AISuggestion=true ;;
        -h|--help) echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] [--log-dir <path>] [--source-cluster <name>] [--dest-cluster <name>] [--namespace <ns>] [--registry <host:port>] [--disable-istio-sidecar] [--skip-cpu-compat-check] [--cleanup-incompatible-mounts] [--skip-checkpoint-normalization] [--normalize-checkpoint-mounts] [--cpu-cap <cpu|fpu|ins|cpu,ins|all>] --"; echo "-- Env: MIGRATION_REGISTRY=<host:port> (default 160.85.255.146:5000; CLUSTER1_REGISTRY still accepted). PRE_CHECKPOINT_ISTIO_503=true|false (default true): inject HTTP 503 on routing-demo VS before checkpoint; cleared when switching to v2. CRIU_CPU_CAP=<mode> defaults to cpu. SKIP_CPU_COMPAT_CHECK=true|false skips the CRIU CPU compatibility validator pod. CLEANUP_INCOMPATIBLE_MOUNTS=true|false runs the source pre-checkpoint powercap cleanup and also enables checkpoint mount normalization unless --skip-checkpoint-normalization is passed. NORMALIZE_CHECKPOINT_MOUNTS=true|false (default false) can enable checkpoint normalization for direct CLI runs without cleanup. CHECKPOINT_NORMALIZE_MOUNTS=/path/a,/path/b overrides the Python normalizer's conservative bad-mount list. --"; exit 0 ;;
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
        --registry)
            shift
            migrationRegistry=$1
            ;;
        --disable-istio-sidecar)
            disableIstioSidecar=true
            ;;
        --skip-cpu-compat-check)
            skipCpuCompatCheck=true
            ;;
        --cleanup-incompatible-mounts)
            cleanupIncompatibleMounts=true
            if [[ "$skipCheckpointNormalization_explicit" != true ]]; then
              normalizeCheckpointMounts=true
              normalizeCheckpointMounts_cli_specified=true
            fi
            ;;
        --skip-checkpoint-normalization)
            normalizeCheckpointMounts=false
            normalizeCheckpointMounts_cli_specified=true
            skipCheckpointNormalization_explicit=true
            ;;
        --normalize-checkpoint-mounts)
            normalizeCheckpointMounts=true
            normalizeCheckpointMounts_cli_specified=true
            skipCheckpointNormalization_explicit=false
            ;;
        --cpu-cap)
            shift
            criuCpuCapMode=$1
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
    echo "-- Usage: $0 <podName> [--forensic-analysis|-fa] [--log-dir <path>] [--source-cluster <name>] [--dest-cluster <name>] [--namespace <ns>] [--registry <host:port>] [--disable-istio-sidecar] [--skip-cpu-compat-check] [--cleanup-incompatible-mounts] [--skip-checkpoint-normalization] [--normalize-checkpoint-mounts] [--cpu-cap <cpu|fpu|ins|cpu,ins|all>] --"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
fi
if [[ "$normalizeCheckpointMounts_cli_specified" != true ]]; then
  normalizeCheckpointMounts="${NORMALIZE_CHECKPOINT_MOUNTS:-$normalizeCheckpointMounts}"
fi
checkpointNormalizeMounts="${CHECKPOINT_NORMALIZE_MOUNTS:-$checkpointNormalizeMounts}"

insecure_registry_setup_attempted=false
criu_tcp_close_setup_attempted=false
criu_cpu_cap_setup_attempted=false
incompatible_mounts_cleanup_done=false
source_workload_stopped=false
istio_pre_checkpoint_503_applied=false
checkpointNormalizationTime=0

# Function to log messages (UTC ISO8601 prefix enables stage/downtime timing in the API/UI)
log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) $1" >> "$log_file"
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
    curl -s "http://$migrationRegistry/v2/$checkpoint_image_name/tags/list" >> "$log_file" 2>&1 || log "Failed to get registry image info"
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

if [[ "$skipCpuCompatCheck" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  skipCpuCompatCheck=true
else
  skipCpuCompatCheck=false
fi

if [[ "$cleanupIncompatibleMounts" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  cleanupIncompatibleMounts=true
else
  cleanupIncompatibleMounts=false
fi

if [[ "$normalizeCheckpointMounts" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  normalizeCheckpointMounts=true
else
  normalizeCheckpointMounts=false
fi

preCheckpointIstio503="${PRE_CHECKPOINT_ISTIO_503:-true}"
if [[ "$preCheckpointIstio503" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee]?[Ss])$ ]]; then
  preCheckpointIstio503=true
else
  preCheckpointIstio503=false
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

# Slow/flaky API paths (e.g. single-node cluster-sev-snp): TLS timeouts during long migrations.
# --validate=false avoids OpenAPI schema fetch (common failure: "failed to download openapi").
KUBECTL_DEST_TIMEOUT="${KUBECTL_DEST_TIMEOUT:-120s}"
KUBECTL_PROXY_PORT="${KUBECTL_PROXY_PORT:-8001}"
# Curl client-side cap on the checkpoint POST. Must cover the time CRIU/CRI-O actually
# needs to dump + write the checkpoint tar on the source node (e.g. when the checkpoint
# storage is NFS and slow). Must be <= the kubelet's runtimeRequestTimeout on the source
# node, otherwise the kubelet aborts the gRPC call to CRI-O before curl gives up.
CHECKPOINT_HTTP_MAX_TIME="${CHECKPOINT_HTTP_MAX_TIME:-900}"

# Stop any kubectl proxy (or other listener) on the given local port so we can bind a
# proxy for the correct --source-cluster. Reusing a proxy left over from another migration
# (e.g. cluster-pnet) causes immediate 404 "nodes \"worker2\" not found" on cluster1.
stop_kubectl_proxy_on_port() {
  local port="$1"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    local pids
    pids=$(lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null || true
    fi
  else
    pkill -f "kubectl.*proxy.*--port=${port}" 2>/dev/null || true
  fi
  sleep 1
}

# True when the apiserver proxy on :port belongs to the migration source (node object exists).
kubectl_proxy_serves_source_node() {
  local port="$1"
  local nodename="$2"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:${port}/api/v1/nodes/${nodename}" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

kubectl_apply_dest() {
  local manifest="$1"
  local err_context="$2"
  local attempt max_attempts
  max_attempts=3
  for attempt in $(seq 1 "$max_attempts"); do
    if kubectl apply --request-timeout="$KUBECTL_DEST_TIMEOUT" --validate=false -f "$manifest" >> "$log_file" 2>&1; then
      return 0
    fi
    log "-- kubectl apply failed ($err_context), attempt $attempt/$max_attempts (retry in 5s) --"
    [[ "$attempt" -lt "$max_attempts" ]] && sleep 5
  done
  handle_error "Failed to $err_context"
}

# Print every Ready=True node that is NOT cordoned (spec.unschedulable!=true) for the given context.
# The DaemonSet controller adds default tolerations for node.kubernetes.io/unschedulable and
# node.kubernetes.io/not-ready, so DS pods would otherwise land on cordoned / not-ready nodes.
# We restrict scheduling via nodeAffinity on kubernetes.io/hostname instead.
list_ready_schedulable_nodes() {
  local context="$1"
  kubectl --context "$context" get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.unschedulable}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    2>/dev/null \
    | awk -F'\t' '$2 != "true" && $3 == "True" {print $1}'
}

# Inject a kubernetes.io/hostname In (...) nodeAffinity into a DaemonSet/Pod manifest so it does
# not get scheduled on NotReady or SchedulingDisabled nodes. Falls back to the original manifest
# if node discovery returns nothing (fail-open).
render_manifest_for_ready_nodes() {
  local context="$1"
  local input_manifest="$2"
  local output_manifest="$3"
  local helper="${SCRIPT_DIR}/../utils/setup/render_daemonset_node_affinity.py"
  local ready_nodes_csv ready_node_count

  if [[ ! -f "$helper" ]]; then
    log "-- Warning: nodeAffinity helper not found at $helper; applying manifest as-is --"
    cp "$input_manifest" "$output_manifest"
    return 0
  fi

  local -a ready_nodes=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && ready_nodes+=("$n")
  done < <(list_ready_schedulable_nodes "$context")
  ready_node_count="${#ready_nodes[@]}"

  if [[ "$ready_node_count" -eq 0 ]]; then
    log "-- Warning: Could not detect any Ready+schedulable nodes on context $context; applying manifest without nodeAffinity restriction --"
    cp "$input_manifest" "$output_manifest"
    return 0
  fi

  ready_nodes_csv=$(IFS=','; echo "${ready_nodes[*]}")
  log "-- Restricting daemonset scheduling on $context to Ready+schedulable nodes ($ready_node_count): $ready_nodes_csv --"

  if ! python3 "$helper" "$input_manifest" "$output_manifest" "${ready_nodes[@]}" >> "$log_file" 2>&1; then
    log "-- Warning: nodeAffinity helper failed; applying manifest as-is --"
    cp "$input_manifest" "$output_manifest"
  fi
}

kubectl_delete_dest_best_effort() {
  local manifest="$1"
  local label="$2"
  local attempt
  for attempt in 1 2 3; do
    if kubectl delete --request-timeout="$KUBECTL_DEST_TIMEOUT" -f "$manifest" --ignore-not-found=true >> "$log_file" 2>&1; then
      return 0
    fi
    log "-- kubectl delete failed ($label), attempt $attempt/3 (retry in 5s) --"
    sleep 5
  done
  log "-- Warning: Failed to delete after retries ($label) --"
  return 0
}

prepull_image_on_destination() {
  local image_ref="$1"
  local run_id="$2"
  local step_name="$3"
  local attempt="${4:-1}"
  local template="${SCRIPT_DIR}/yaml/prepull-base-image-daemonset.yaml"
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

  local ds_manifest_ready="${ds_manifest%.yaml}.ready-nodes.yaml"
  render_manifest_for_ready_nodes "$destCluster" "$ds_manifest" "$ds_manifest_ready"
  ds_manifest="$ds_manifest_ready"

  log "-- Pre-pulling image \"$image_ref\" on destination cluster using daemonset \"$ds_name\" --"
  kubectl_apply_dest "$ds_manifest" "apply pre-pull daemonset"

  # Best-effort wait: give kubelet time to pull the image on destination nodes.
  sleep 20
  kubectl -n kube-system get events --field-selector reason=Pulled >> "$log_file" 2>&1 || true

  # Detect the common HTTP/HTTPS mismatch from kubelet event text.
  if kubectl -n kube-system describe pods -l "app=${ds_name}" 2>/dev/null | grep -q "http: server gave HTTP response to HTTPS client"; then
    log "-- Detected registry TLS mismatch while pre-pulling $image_ref --"
    kubectl_delete_dest_best_effort "$ds_manifest" "pre-pull daemonset (registry retry path)"

    if [[ "$attempt" -eq 1 ]]; then
      ensure_insecure_registry_on_destination
      prepull_image_on_destination "$image_ref" "$run_id" "$step_name" 2
      return $?
    fi

    handle_error "Pre-pull failed after insecure-registry setup attempt for image: $image_ref"
  fi

  kubectl_delete_dest_best_effort "$ds_manifest" "pre-pull daemonset cleanup"
  log "-- Pre-pull daemonset cleanup complete for $image_ref --"
}

ensure_insecure_registry_on_destination() {
  local setup_manifest="${SCRIPT_DIR}/../utils/setup/insecure-registry-daemonset.yaml"

  if [[ "$insecure_registry_setup_attempted" == true ]]; then
    log "-- Insecure-registry setup already attempted in this migration run; skipping --"
    return 0
  fi

  if [[ ! -f "$setup_manifest" ]]; then
    handle_error "Insecure-registry setup manifest not found: $setup_manifest"
  fi

  insecure_registry_setup_attempted=true
  log "-- Applying on-demand insecure-registry daemonset (destination cluster) --"
  local rendered_manifest="${log_dir}/insecure-registry-daemonset.ready-nodes.yaml"
  render_manifest_for_ready_nodes "$destCluster" "$setup_manifest" "$rendered_manifest"
  kubectl_apply_dest "$rendered_manifest" "apply insecure-registry daemonset"

  # Give daemonset time to write config/restart CRI-O where needed.
  sleep 20
  kubectl -n kube-system get pods -l app=setup-insecure-registry -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l app=setup-insecure-registry --tail=50 >> "$log_file" 2>&1 || true

  # The setup is only needed on demand; do not keep it running permanently.
  kubectl_delete_dest_best_effort "$rendered_manifest" "insecure-registry daemonset"
  log "-- On-demand insecure-registry setup completed and cleaned up --"
}

ensure_criu_tcp_close_on_destination() {
  local setup_manifest="${SCRIPT_DIR}/../utils/setup/criu-tcp-close-daemonset.yaml"

  if [[ "$criu_tcp_close_setup_attempted" == true ]]; then
    log "-- CRIU tcp-close setup already attempted in this migration run; skipping --"
    return 0
  fi

  if [[ ! -f "$setup_manifest" ]]; then
    handle_error "CRIU tcp-close setup manifest not found: $setup_manifest"
  fi

  criu_tcp_close_setup_attempted=true
  log "-- Applying preflight CRIU tcp-close daemonset (destination cluster) --"
  local rendered_manifest="${log_dir}/criu-tcp-close-daemonset.ready-nodes.yaml"
  render_manifest_for_ready_nodes "$destCluster" "$setup_manifest" "$rendered_manifest"
  kubectl_apply_dest "$rendered_manifest" "apply CRIU tcp-close daemonset"

  sleep 10
  kubectl -n kube-system get pods -l app=setup-criu-tcp-close -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l app=setup-criu-tcp-close --tail=50 >> "$log_file" 2>&1 || true

  kubectl_delete_dest_best_effort "$rendered_manifest" "criu-tcp-close daemonset"
  log "-- Preflight CRIU tcp-close setup completed and cleaned up --"
}

# Configure / remove cpu-cap in /etc/criu/runc.conf on every node of the active cluster context.
# enabled=true  -> enforce exactly one "cpu-cap <mode>" line.
# enabled=false -> remove all cpu-cap lines (and legacy CubeMig marker comments).
ensure_criu_cpu_cap_on_active_context() {
  local cpu_cap_mode="$1"
  local enabled="$2"
  local context_label="$3"
  local template="${SCRIPT_DIR}/../utils/setup/criu-cpu-cap-daemonset.yaml"
  local manifest="${log_dir}/criu-cpu-cap-${context_label}.yaml"

  if [[ "$criu_cpu_cap_setup_attempted" == "$context_label" ]]; then
    log "-- CRIU cpu-cap setup already applied for $context_label; skipping --"
    return 0
  fi

  if [[ ! -f "$template" ]]; then
    handle_error "CRIU cpu-cap setup manifest not found: $template"
  fi

  sed -e "s|__CPU_CAP_MODE__|${cpu_cap_mode}|g" \
      -e "s|__CPU_CAP_ENABLED__|${enabled}|g" \
      "$template" > "$manifest" \
    || handle_error "Failed to render CRIU cpu-cap daemonset manifest for $context_label"

  # The active context here is always the cluster receiving the daemonset (set by callers).
  local active_context
  active_context=$(kubectl config current-context 2>/dev/null || echo "")
  local rendered_manifest="${manifest%.yaml}.ready-nodes.yaml"
  if [[ -n "$active_context" ]]; then
    render_manifest_for_ready_nodes "$active_context" "$manifest" "$rendered_manifest"
  else
    cp "$manifest" "$rendered_manifest"
  fi

  if [[ "$enabled" == "true" ]]; then
    log "-- Applying CRIU cpu-cap daemonset (cluster: $context_label, mode: $cpu_cap_mode) --"
  else
    log "-- Applying CRIU cpu-cap cleanup daemonset (cluster: $context_label; removing cpu-cap from /etc/criu/runc.conf) --"
  fi
  if ! kubectl apply --request-timeout="$KUBECTL_DEST_TIMEOUT" --validate=false -f "$rendered_manifest" >> "$log_file" 2>&1; then
    handle_error "Failed to apply CRIU cpu-cap daemonset on cluster $context_label"
  fi

  sleep 10
  kubectl -n kube-system get pods -l app=setup-criu-cpu-cap -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l app=setup-criu-cpu-cap --tail=50 >> "$log_file" 2>&1 || true

  kubectl delete --request-timeout="$KUBECTL_DEST_TIMEOUT" -f "$rendered_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || true
  criu_cpu_cap_setup_attempted="$context_label"
  if [[ "$enabled" == "true" ]]; then
    log "-- CRIU cpu-cap setup completed on cluster $context_label (mode: $cpu_cap_mode) --"
  else
    log "-- CRIU cpu-cap cleanup completed on cluster $context_label (cpu-cap removed) --"
  fi
}

# Run a daemonset on every Ready+schedulable node of the source cluster that, for the named pod,
# unmounts /sys/devices/virtual/powercap from the running container's mount namespace. CRIU restore
# fails on PNET / SEV-SNP destinations because those nodes do not expose the powercap path the
# checkpoint expects to bind-mount back in. Removing the mount before the checkpoint makes the
# restore succeed on heterogeneous targets.
cleanup_incompatible_mounts_on_source() {
  local target_pod_name="$1"
  local target_namespace="$2"
  local template="${SCRIPT_DIR}/../utils/setup/cleanup-incompatible-mounts-daemonset.yaml"
  local ds_name manifest rendered_manifest run_id wait_total wait_max
  local pod_count fail_count

  if [[ ! -f "$template" ]]; then
    log "-- Warning: cleanup-incompatible-mounts daemonset template not found at $template; skipping --"
    return 0
  fi

  if [[ "$incompatible_mounts_cleanup_done" == true ]]; then
    log "-- cleanup-incompatible-mounts already executed in this run; skipping --"
    return 0
  fi

  run_id=$(date +%s)-$RANDOM
  ds_name="cleanup-incompatible-mounts-${run_id}"
  ds_name="${ds_name:0:63}"
  manifest="${log_dir}/${ds_name}.yaml"
  rendered_manifest="${log_dir}/${ds_name}.ready-nodes.yaml"

  sed -e "s|__DS_NAME__|${ds_name}|g" \
      -e "s|__TARGET_POD_NAME__|${target_pod_name}|g" \
      -e "s|__TARGET_NAMESPACE__|${target_namespace}|g" \
      "$template" > "$manifest" \
    || handle_error "Failed to render cleanup-incompatible-mounts daemonset manifest"

  kubectl config use-context "$sourceCluster" >> "$log_file" 2>&1 \
    || handle_error "Failed to switch context to $sourceCluster for incompatible mount cleanup"
  kubectl config set-context --current --namespace="$namespace" >> "$log_file" 2>&1 || true
  render_manifest_for_ready_nodes "$sourceCluster" "$manifest" "$rendered_manifest"

  log "-- Applying cleanup-incompatible-mounts daemonset on source cluster $sourceCluster (pod: $target_namespace/$target_pod_name, ds: $ds_name) --"
  if ! kubectl apply --request-timeout="$KUBECTL_DEST_TIMEOUT" --validate=false -f "$rendered_manifest" >> "$log_file" 2>&1; then
    log "-- Warning: failed to apply cleanup-incompatible-mounts daemonset; continuing without cleanup --"
    return 0
  fi

  # Wait for the daemonset to roll out across the targeted nodes; abort if cleanup containers report errors.
  wait_total=0
  wait_max="${CLEANUP_INCOMPATIBLE_MOUNTS_TIMEOUT:-90}"
  while (( wait_total < wait_max )); do
    pod_count=$(kubectl -n kube-system get pods -l "app=${ds_name}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Running\|Succeeded\|Failed" || true)
    if [[ "$pod_count" =~ ^[0-9]+$ ]] && (( pod_count > 0 )); then
      break
    fi
    sleep 3
    wait_total=$((wait_total + 3))
  done

  # Surface logs for visibility before tearing the DS down.
  kubectl -n kube-system get pods -l "app=${ds_name}" -o wide >> "$log_file" 2>&1 || true
  kubectl -n kube-system logs -l "app=${ds_name}" --tail=100 --prefix=true >> "$log_file" 2>&1 || true

  fail_count=$(kubectl -n kube-system logs -l "app=${ds_name}" --tail=200 2>/dev/null | grep -c "\[ERROR\] powercap mount still present" || true)
  if [[ "$fail_count" =~ ^[0-9]+$ ]] && (( fail_count > 0 )); then
    log "-- Warning: cleanup-incompatible-mounts reported $fail_count container(s) where powercap could not be unmounted --"
  fi

  kubectl delete --request-timeout="$KUBECTL_DEST_TIMEOUT" -f "$rendered_manifest" --ignore-not-found=true >> "$log_file" 2>&1 || true
  incompatible_mounts_cleanup_done=true
  log "-- cleanup-incompatible-mounts daemonset finished and removed --"
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
  local source_image_id_ref="${2:-}"
  local fallback_default="${BASE_IMAGE_PREPULL_FALLBACK:-}"

  # Prefer the exact runtime image digest from source pod status for CRIU restore compatibility.
  if [[ -n "$source_image_id_ref" ]]; then
    echo "$source_image_id_ref"
    return
  fi

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

normalize_image_id_for_pull() {
  local raw_image_id="${1:-}"
  raw_image_id="${raw_image_id#docker-pullable://}"
  raw_image_id="${raw_image_id#docker://}"
  echo "$raw_image_id"
}

rewrite_registry_for_pnet_destination() {
  local image_ref="${1:-}"
  local pnet_target_registry="$PNET_WIREGUARD_MIGRATION_REGISTRY"

  if [[ -z "$image_ref" ]]; then
    echo "$image_ref"
    return
  fi

  case "$image_ref" in
    10.0.0.180:5000/*|10.0.0.1:5000/*|160.85.255.146:5000/*)
      echo "${pnet_target_registry}/${image_ref#*/}"
      ;;
    *)
      echo "$image_ref"
      ;;
  esac
}

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

run_criu_cpu_compat_check() {
  local checkpoint_archive="$1"
  local cpu_cap_mode="$2"
  local source_node="$3"
  local target_cluster="$4"
  local extract_dir
  local cpuinfo_path
  local images_dir
  local validator_pod_template="${SCRIPT_DIR}/../utils/setup/criu-cpu-validator-pod.yaml"
  local run_id pod_name configmap_name validator_manifest
  local prev_context phase exit_code logs target_node
  local saved_context

  if [[ ! -f "$validator_pod_template" ]]; then
    handle_error "CRIU CPU validator pod template not found: $validator_pod_template"
  fi

  extract_dir=$(mktemp -d) || handle_error "Failed to create temporary directory for CRIU CPU check"
  if ! sudo tar -xf "$checkpoint_archive" -C "$extract_dir" >>"$log_file" 2>&1; then
    sudo rm -rf "$extract_dir" || true
    handle_error "Failed to extract checkpoint archive for CPU compatibility validation (source node: $source_node, target cluster: $target_cluster, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode)"
  fi

  cpuinfo_path=$(sudo find "$extract_dir" -type f -name "cpuinfo.img" 2>/dev/null | head -n 1)
  if [[ -z "$cpuinfo_path" ]]; then
    sudo rm -rf "$extract_dir" || true
    handle_error "Checkpoint archive does not contain CRIU cpuinfo image; cannot validate target CPU compatibility before restore. CRIU dump must run with --cpu-cap (set 'cpu-cap <mode>' in /etc/criu/runc.conf on source nodes — see criu-cpu-cap-daemonset.yaml). source node: $source_node, target cluster: $target_cluster, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode"
  fi
  images_dir=$(dirname "$cpuinfo_path")

  # Extracted CRIU images are root-owned with restrictive perms; make file readable AND
  # parent dirs traversable so 'kubectl create configmap --from-file=...' (running as the
  # invoking user) can stat and read the cpuinfo.img.
  sudo chmod -R a+rX "$extract_dir" || true

  run_id=$(date +%s)-$RANDOM
  pod_name="criu-cpu-check-${run_id}"
  pod_name="${pod_name:0:63}"
  configmap_name="${pod_name}-cpuinfo"
  validator_manifest="${log_dir}/${pod_name}.yaml"

  saved_context=$(kubectl config current-context 2>/dev/null || true)
  kubectl config use-context "$target_cluster" >>"$log_file" 2>&1 \
    || handle_error "Failed to switch context to $target_cluster for CPU compatibility validation"

  log "-- Running pre-restore CRIU CPU compatibility check on destination cluster $target_cluster (mode: $cpu_cap_mode) --"

  if ! kubectl -n kube-system create configmap "$configmap_name" --from-file=cpuinfo.img="$cpuinfo_path" >>"$log_file" 2>&1; then
    [[ -n "$saved_context" ]] && kubectl config use-context "$saved_context" >>"$log_file" 2>&1 || true
    sudo rm -rf "$extract_dir" || true
    handle_error "Failed to create cpuinfo ConfigMap on destination cluster (source node: $source_node, target cluster: $target_cluster, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode)"
  fi

  sed -e "s|__POD_NAME__|${pod_name}|g" \
      -e "s|__CONFIGMAP_NAME__|${configmap_name}|g" \
      -e "s|__CPU_CAP_MODE__|${cpu_cap_mode}|g" \
      -e "s|__RUN_ID__|${run_id}|g" \
      "$validator_pod_template" > "$validator_manifest" \
    || { kubectl -n kube-system delete configmap "$configmap_name" --ignore-not-found=true >>"$log_file" 2>&1 || true
         [[ -n "$saved_context" ]] && kubectl config use-context "$saved_context" >>"$log_file" 2>&1 || true
         sudo rm -rf "$extract_dir" || true
         handle_error "Failed to render CRIU CPU validator pod manifest"; }

  if ! kubectl apply --request-timeout="$KUBECTL_DEST_TIMEOUT" --validate=false -f "$validator_manifest" >>"$log_file" 2>&1; then
    kubectl -n kube-system delete pod "$pod_name" --ignore-not-found=true >>"$log_file" 2>&1 || true
    kubectl -n kube-system delete configmap "$configmap_name" --ignore-not-found=true >>"$log_file" 2>&1 || true
    [[ -n "$saved_context" ]] && kubectl config use-context "$saved_context" >>"$log_file" 2>&1 || true
    sudo rm -rf "$extract_dir" || true
    handle_error "Failed to apply CRIU CPU validator pod on destination cluster (source node: $source_node, target cluster: $target_cluster, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode)"
  fi

  local wait_total=0
  local wait_max="${CRIU_CPU_CHECK_TIMEOUT:-180}"
  phase=""
  while (( wait_total < wait_max )); do
    phase=$(kubectl -n kube-system get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
      break
    fi
    sleep 3
    wait_total=$((wait_total + 3))
  done

  target_node=$(kubectl -n kube-system get pod "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
  exit_code=$(kubectl -n kube-system get pod "$pod_name" -o jsonpath='{.status.containerStatuses[?(@.name=="check")].state.terminated.exitCode}' 2>/dev/null || echo "")
  logs=$(kubectl -n kube-system logs "$pod_name" --all-containers=true --tail=200 2>/dev/null || true)

  log "-- CRIU CPU validator pod \"$pod_name\" landed on destination node: $target_node --"
  if [[ -n "$logs" ]]; then
    log "-- CRIU CPU validator logs (begin) --"
    printf '%s\n' "$logs" >> "$log_file"
    log "-- CRIU CPU validator logs (end) --"
  fi

  kubectl -n kube-system delete pod "$pod_name" --ignore-not-found=true >>"$log_file" 2>&1 || true
  kubectl -n kube-system delete configmap "$configmap_name" --ignore-not-found=true >>"$log_file" 2>&1 || true
  [[ -n "$saved_context" ]] && kubectl config use-context "$saved_context" >>"$log_file" 2>&1 || true
  sudo rm -rf "$extract_dir" || true

  if [[ "$phase" != "Succeeded" && "$phase" != "Failed" ]]; then
    handle_error "Timed out waiting for CRIU CPU validator pod (timeout=${wait_max}s). source node: $source_node, target cluster: $target_cluster, target node: $target_node, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode"
  fi

  if [[ -z "$exit_code" ]]; then
    handle_error "CRIU CPU validator pod did not produce a terminated exit code (phase=$phase). source node: $source_node, target cluster: $target_cluster, target node: $target_node, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode"
  fi

  if [[ "$exit_code" != "0" ]]; then
    handle_error "Target CPU is incompatible with checkpoint CPU requirements (missing CPU/instruction-set features). source node: $source_node, target cluster: $target_cluster, target node: $target_node, checkpoint: $checkpoint_archive, cpu-cap mode: $cpu_cap_mode, validator exit code: $exit_code"
  fi

  log "-- CRIU CPU compatibility check passed (source node: $source_node → target node: $target_node, mode: $cpu_cap_mode) --"
}

if [[ "$skipCpuCompatCheck" != true ]]; then
  if ! validate_criu_cpu_cap_mode "$criuCpuCapMode"; then
    handle_error "Unsupported CRIU cpu-cap mode: $criuCpuCapMode (allowed: cpu, fpu, ins, cpu,fpu, cpu,ins, fpu,ins, cpu,fpu,ins, all, none)"
  fi
  if [[ "$criuCpuCapMode" == "none" ]]; then
    handle_error "CRIU cpu-cap mode 'none' is unsafe and not allowed by default. Use cpu or all (or another strict mode)."
  fi
else
  log "-- skip-cpu-compat-check=true: skipping CRIU cpu-cap mode validation and cpuinfo compatibility enforcement --"
fi

# Basic/cold: no requests on source after durable checkpoint .tar is on NFS — call after chmod, before buildah.
stop_source_workload_after_checkpoint() {
  log "--- Stopping source workload (scale to 0 when possible, else pod delete) ---"
  kubectl config use-context "$sourceCluster" || handle_error "Failed to switch context to $sourceCluster"
  kubectl config set-context --current --namespace="$namespace"

  local source_deploy_local=""
  local source_sts_local=""
  local rs_name_local
  rs_name_local=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}' 2>/dev/null || true)
  if [[ -n "$rs_name_local" ]]; then
    source_deploy_local=$(kubectl get rs "$rs_name_local" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
  fi
  if [[ -z "$source_deploy_local" ]]; then
    source_sts_local=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}' 2>/dev/null || true)
  fi

  if [[ -n "$source_deploy_local" ]]; then
    kubectl scale deploy "$source_deploy_local" -n "$namespace" --replicas=0 || handle_error "Failed to scale deployment $source_deploy_local to 0"
    log "-- Scaled deployment \"$source_deploy_local\" to 0 replicas (immediately after checkpoint; source no longer serves) --"
  elif [[ -n "$source_sts_local" ]]; then
    kubectl scale sts "$source_sts_local" -n "$namespace" --replicas=0 || handle_error "Failed to scale statefulset $source_sts_local to 0"
    log "-- Scaled statefulset \"$source_sts_local\" to 0 replicas (immediately after checkpoint) --"
  else
    log "-- No Deployment/StatefulSet owner for \"$podName\"; deleting pod after checkpoint --"
    kubectl delete pod "$podName" -n "$namespace" || handle_error "Failed to delete pod"
    log "-- Pod \"$podName\" deleted (immediately after checkpoint) --"
  fi
  source_workload_stopped=true
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
Checkpoint Normalization: $checkpointNormalizationTime ms
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
destClusterNormalized="$(echo "$destCluster" | tr '[:upper:]' '[:lower:]')"
if [[ "$destClusterNormalized" == "cluster-pnet" || "$destClusterNormalized" == "pnet" ]]; then
  migrationRegistry="$PNET_WIREGUARD_MIGRATION_REGISTRY"
  enableCheckpointPrepull=true
  log "-- PNET destination detected: overriding migration image registry to $migrationRegistry (WireGuard route) --"
  log "-- PNET destination detected: forcing checkpoint image pre-pull --"
fi
log "Namespace: $namespace"
log "Destination registry: $migrationRegistry"
log "Disable Istio sidecar: $disableIstioSidecar"
log "Enable checkpoint pre-pull: $enableCheckpointPrepull"
log "Preflight destination setup: $preflightDestinationSetup"
log "Preflight cluster checks: $preflightClusterChecks"
log "Pre-checkpoint Istio 503 (routing-demo): $preCheckpointIstio503"
log "CRIU cpu-cap mode: $criuCpuCapMode"
log "Skip CRIU CPU compatibility check: $skipCpuCompatCheck"
log "Cleanup incompatible mounts before checkpoint: $cleanupIncompatibleMounts"

log "Forensic analysis: $forensicAnalysis"
log "AI suggestion: $AISuggestion"

if [[ "$preflightClusterChecks" == true ]]; then
  run_global_cluster_checks
else
  log "-- Global preflight checks skipped by feature flag --"
  log "-- Set PREFLIGHT_CLUSTER_CHECKS=true to enable global cluster checks --"
fi


# Pod / container / image metadata (source cluster; context set at script start)
containerName=$(kubectl get pods $podName -o jsonpath='{.spec.containers[0].name}') || handle_error "Failed to get container name"
nodename=$(kubectl get pods $podName -o jsonpath='{.spec.nodeName}') || handle_error "Failed to get node name"
source_image_ref=$(kubectl get pod $podName -o jsonpath='{.spec.containers[0].image}') || handle_error "Failed to get image name"
# Important for Istio-injected pods: select imageID by container name, not by index,
# because containerStatuses ordering can differ and pick istio-proxy by mistake.
source_image_id_raw=$(kubectl get pod "$podName" -o jsonpath="{.status.containerStatuses[?(@.name==\"$containerName\")].imageID}" 2>/dev/null || true)
source_image_id_ref="$(normalize_image_id_for_pull "$source_image_id_raw")"

templateContainerName="$containerName"
if [[ "$templateContainerName" == *"-restore-"* ]]; then
  templateContainerName="${templateContainerName%%-restore-*}"
elif [[ "$templateContainerName" == *"-restore" ]]; then
  templateContainerName="${templateContainerName%-restore}"
fi

# Single timestamp for pre-pull daemonset names and restore pod name (stable for this run)
timestampSuffix=$(date +"%Y%m%d-%H%M%S")
prepull_run_id="$(echo "$timestampSuffix" | tr -d '-')"
newPodName="${templateContainerName}-restore-${timestampSuffix}"
newPodName="${newPodName:0:63}"
restoreTemplate="${SCRIPT_DIR}/yaml/restore_${templateContainerName}.yaml"
restoreManifest="${log_dir}/restore_${newPodName}.yaml"

if [[ ! -f "$restoreTemplate" ]]; then
  handle_error "Restore template not found: $restoreTemplate"
fi

# --- Destination preparation BEFORE checkpoint (minimize time from dump to restore) ---
migrationStartTime=$(date +%s%3N)
log "-- Destination preparation (pre-checkpoint) started --"
log "-- Order: prepare target cluster → CRIU checkpoint on source → image push → optional checkpoint pre-pull → restore → traffic → source cleanup --"

kubectl config use-context "$destCluster" || handle_error "Failed to switch context to $destCluster"
kubectl config set-context --current --namespace="$namespace"

if [[ "$preflightDestinationSetup" == true ]]; then
  log "-- Destination runtime preflight (insecure-registry + CRIU tcp-close) --"
  ensure_insecure_registry_on_destination
  ensure_criu_tcp_close_on_destination
  log "-- Destination runtime preflight completed --"
else
  log "-- Destination runtime preflight skipped by feature flag --"
  log "-- Set PREFLIGHT_DESTINATION_SETUP=true to enable destination setup --"
fi

if [[ -n "$source_image_id_ref" ]]; then
  log "-- Source runtime imageID detected for pre-pull: $source_image_id_ref --"
else
  log "-- Warning: Source runtime imageID unavailable; falling back to image ref for pre-pull: $source_image_ref --"
fi
prepull_base_image_ref="$(resolve_base_image_for_prepull "$source_image_ref" "$source_image_id_ref")"
if [[ "$destClusterNormalized" == "cluster-pnet" || "$destClusterNormalized" == "pnet" ]]; then
  prepull_base_image_ref="$(rewrite_registry_for_pnet_destination "$prepull_base_image_ref")"
fi
log "-- Pre-pull step (base image) started --"
log "-- Base image chosen for pre-pull: $prepull_base_image_ref --"
prepull_image_on_destination "$prepull_base_image_ref" "$prepull_run_id" "base"
log "-- Pre-pull step (base image) completed --"

# Without a Service on the destination cluster, no Endpoints exist for routing-demo → Istio subset v2 has no backends.
if [[ "$namespace" == "istio-enabled" && "$templateContainerName" == "routing-demo" ]]; then
  log "-- Ensuring routing-demo Service + DestinationRule on destination (before checkpoint) --"
  rd_svc="${SCRIPT_DIR}/../../apps/kubernetes/routing_demo/routing-demo-service.yaml"
  rd_dr="${SCRIPT_DIR}/../../apps/kubernetes/routing_demo/routing-demo-destination-rule.yaml"
  if [[ -f "$rd_svc" && -f "$rd_dr" ]]; then
    kubectl_apply_dest "$rd_svc" "apply routing-demo Service on destination"
    kubectl_apply_dest "$rd_dr" "apply routing-demo DestinationRule on destination"
  else
    log "-- Warning: Missing $rd_svc or $rd_dr — skip Service/DR on destination --"
  fi
fi

log "-- Destination preparation (pre-checkpoint) completed --"

# --- CRIU checkpoint on source (kubelet client certs must match source context name) ---
kubectl config use-context "$sourceCluster" || handle_error "Failed to switch context to $sourceCluster for checkpoint"
kubectl config set-context --current --namespace="$namespace"
currentCluster="$sourceCluster"

# Ensure CRIU on source nodes writes cpuinfo.img during dump (so target compatibility can be validated before restore).
if [[ "$skipCpuCompatCheck" == true ]]; then
  ensure_criu_cpu_cap_on_active_context "$criuCpuCapMode" "false" "source"
else
  ensure_criu_cpu_cap_on_active_context "$criuCpuCapMode" "true" "source"
fi

# NFS mirror: each node's kubelet checkpoint dir is exported as <CHECKPOINT_NFS_ROOT>/<nodeName>/.
checkpoint_nfs_root="${CHECKPOINT_NFS_ROOT:-/home/ubuntu/nfs/checkpoints}"
nodename=$(kubectl get pods "$podName" -o jsonpath='{.spec.nodeName}') || handle_error "Failed to get node name (before checkpoint; after dest prep)"
checkpoint_dir="${checkpoint_nfs_root}/${nodename}"
log "-- Checkpoint (source cluster only): NFS mirror $checkpoint_nfs_root/<source-node>/; pod $podName runs on source node \"$nodename\" → expect .tar under $checkpoint_dir (unrelated to dest cluster \"$destCluster\") --"

# Variant A: explicit 503 before checkpoint so v1 does not serve new requests while dumping / waiting on NFS.
if [[ "$preCheckpointIstio503" == true && "$namespace" == "istio-enabled" && "$templateContainerName" == "routing-demo" ]]; then
  if kubectl get virtualservice routing-demo >/dev/null 2>&1; then
    log "-- Pre-checkpoint: Istio fault.abort HTTP 503 on VirtualService routing-demo (stops v1 state advancing until restore) --"
    if kubectl patch virtualservice routing-demo --type=json -p='[
      {"op":"add","path":"/spec/http/0/fault","value":{"abort":{"httpStatus":503,"percentage":{"value":100}}}}
    ]' >>"$log_file" 2>&1; then
      istio_pre_checkpoint_503_applied=true
    elif kubectl patch virtualservice routing-demo --type=json -p='[
      {"op":"replace","path":"/spec/http/0/fault","value":{"abort":{"httpStatus":503,"percentage":{"value":100}}}}
    ]' >>"$log_file" 2>&1; then
      istio_pre_checkpoint_503_applied=true
    else
      log "-- Warning: Could not inject pre-checkpoint 503 on VirtualService routing-demo --"
    fi
  else
    log "-- Pre-checkpoint 503 skipped: VirtualService routing-demo not found --"
  fi
fi

if [[ "$cleanupIncompatibleMounts" == true ]]; then
  cleanup_incompatible_mounts_on_source "$podName" "$namespace"
else
  log "-- cleanup-incompatible-mounts skipped by feature flag (--cleanup-incompatible-mounts) --"
fi

log "-- Creating checkpoint for $podName on $nodename --"

checkpoint_epoch_before_curl=$(($(date +%s) - 3))
startTime=$(date +%s%3N)
_checkpoint_body_tmp=$(mktemp)
proxy_port="$KUBECTL_PROXY_PORT"
proxy_healthz_url="http://127.0.0.1:${proxy_port}/healthz"
proxy_checkpoint_path="/api/v1/nodes/${nodename}/proxy/checkpoint/${namespace}/${podName}/${containerName}"
proxy_checkpoint_url="http://127.0.0.1:${proxy_port}${proxy_checkpoint_path}"
KUBECTL_PROXY_PID=""
started_kubectl_proxy=false

if curl -sS --connect-timeout 2 --max-time 5 "$proxy_healthz_url" >/dev/null 2>&1 \
  && kubectl_proxy_serves_source_node "$proxy_port" "$nodename"; then
  log "-- Reusing existing kubectl proxy on 127.0.0.1:${proxy_port} (source cluster ${sourceCluster}; node ${nodename} found) --"
else
  if curl -sS --connect-timeout 2 --max-time 5 "$proxy_healthz_url" >/dev/null 2>&1; then
    log "-- Existing kubectl proxy on 127.0.0.1:${proxy_port} is not for source cluster ${sourceCluster} (node ${nodename} not found via proxy API); restarting proxy --"
    stop_kubectl_proxy_on_port "$proxy_port"
  else
    log "-- kubectl proxy on 127.0.0.1:${proxy_port} is not reachable; starting new proxy for source context ${sourceCluster} --"
  fi
  kubectl --context "$sourceCluster" proxy --address=127.0.0.1 --port="$proxy_port" >>"$log_file" 2>&1 &
  KUBECTL_PROXY_PID=$!
  started_kubectl_proxy=true
  sleep 1
  if ! curl -sS --connect-timeout 2 --max-time 5 "$proxy_healthz_url" >/dev/null 2>&1; then
    log "-- kubectl proxy did not become reachable on 127.0.0.1:${proxy_port} --"
    if [[ "$started_kubectl_proxy" == true && -n "$KUBECTL_PROXY_PID" ]] && kill -0 "$KUBECTL_PROXY_PID" 2>/dev/null; then
      kill "$KUBECTL_PROXY_PID" 2>/dev/null || true
      wait "$KUBECTL_PROXY_PID" 2>/dev/null || true
    fi
    handle_error "Failed to start kubectl proxy on 127.0.0.1:${proxy_port} for source context ${sourceCluster}"
  fi
  if ! kubectl_proxy_serves_source_node "$proxy_port" "$nodename"; then
    if [[ "$started_kubectl_proxy" == true && -n "$KUBECTL_PROXY_PID" ]] && kill -0 "$KUBECTL_PROXY_PID" 2>/dev/null; then
      kill "$KUBECTL_PROXY_PID" 2>/dev/null || true
      wait "$KUBECTL_PROXY_PID" 2>/dev/null || true
    fi
    handle_error "kubectl proxy on 127.0.0.1:${proxy_port} started but node ${nodename} is not visible in source cluster ${sourceCluster}"
  fi
fi

log "-- Calling checkpoint API via apiserver proxy path: ${proxy_checkpoint_path} (curl --max-time=${CHECKPOINT_HTTP_MAX_TIME}s) --"
checkpoint_http=$(curl -sS -X POST "$proxy_checkpoint_url" \
  --connect-timeout 10 \
  --max-time "$CHECKPOINT_HTTP_MAX_TIME" \
  -o "$_checkpoint_body_tmp" \
  -w '%{http_code}' \
  2>>"$log_file")
curl_rc=$?
if [[ "$started_kubectl_proxy" == true && -n "$KUBECTL_PROXY_PID" ]] && kill -0 "$KUBECTL_PROXY_PID" 2>/dev/null; then
  kill "$KUBECTL_PROXY_PID" 2>/dev/null || true
  wait "$KUBECTL_PROXY_PID" 2>/dev/null || true
fi
if [[ "$curl_rc" -ne 0 ]]; then
  rm -f "$_checkpoint_body_tmp"
  handle_error "Failed to invoke kubelet checkpoint API via apiserver proxy (curl rc=$curl_rc)"
fi
checkpoint_output=$(cat "$_checkpoint_body_tmp")
rm -f "$_checkpoint_body_tmp"
checkpointTime=$(($(date +%s%3N) - $startTime))
log "kubelet checkpoint HTTP status: $checkpoint_http"
log "checkpoint output: $checkpoint_output"
if [[ "$checkpoint_http" =~ ^[45][0-9][0-9]$ ]]; then
  handle_error "Kubelet checkpoint API returned HTTP $checkpoint_http (no archive expected). Body: $checkpoint_output"
fi
log "-- Checkpoint request accepted (HTTP $checkpoint_http); waiting for .tar on NFS --"

# Kubelet JSON lists the node path; NFS export on this host uses the same basename under .../checkpoints/<nodename>/
checkpoint_basename=""
if command -v jq >/dev/null 2>&1; then
  _ck_item=$(echo "$checkpoint_output" | jq -r '.items[0] // empty' 2>/dev/null || true)
  if [[ -n "$_ck_item" && "$_ck_item" != "null" ]]; then
    checkpoint_basename=$(basename "$_ck_item")
    log "-- Expected checkpoint basename from kubelet: $checkpoint_basename --"
  fi
fi

log "------------------------------------------------------------------"

log "-- Waiting for checkpoint archive on NFS for ${podName} (pod still up until file visible; then scale to 0) --"

startTime=$(date +%s%3N)
checkpoint_glob="checkpoint-${podName}_${namespace}-${containerName}-*.tar"
checkpointfile=""
checkpoint_wait_max_seconds="${CHECKPOINT_NFS_WAIT_SECONDS:-180}"
checkpoint_wait_interval_seconds="${CHECKPOINT_NFS_WAIT_INTERVAL:-2}"
elapsed_wait=0
while [[ "$elapsed_wait" -lt "$checkpoint_wait_max_seconds" ]]; do
  if [[ -d "$checkpoint_dir" ]]; then
    if [[ -n "$checkpoint_basename" && -f "$checkpoint_dir/$checkpoint_basename" ]]; then
      checkpointfile="$checkpoint_dir/$checkpoint_basename"
      break
    fi
    # shellcheck disable=SC2012
    checkpointfile=$(ls -1t "$checkpoint_dir"/$checkpoint_glob 2>/dev/null | head -n 1)
    if [[ -n "$checkpointfile" && -f "$checkpointfile" ]]; then
      break
    fi
    checkpointfile=""
  fi
  sleep "$checkpoint_wait_interval_seconds"
  elapsed_wait=$((elapsed_wait + checkpoint_wait_interval_seconds))
  if (( elapsed_wait % 20 == 0 )); then
    log "-- Still waiting for checkpoint .tar on NFS (${elapsed_wait}s / ${checkpoint_wait_max_seconds}s, dir=${checkpoint_dir}) --"
  fi
done
latestCheckpointTime=$(($(date +%s%3N) - $startTime))

if [[ -z "$checkpointfile" || ! -f "$checkpointfile" ]]; then
  log "-- Checkpoint file not found under $checkpoint_dir (glob: $checkpoint_glob) after ${checkpoint_wait_max_seconds}s --"
  log "-- Same workload on this node (any pod replica, newest first) — if your pod is missing, kubelet did not write this pod's archive: --"
  # shellcheck disable=SC2012
  ls -1t "$checkpoint_dir"/checkpoint-*_"${namespace}-${containerName}-"*.tar 2>/dev/null | head -15 >>"$log_file" || true
  log "-- Scanning all nodes under $checkpoint_nfs_root for $checkpoint_glob newer than checkpoint request (stale node name / export layout): --"
  _fb_line=""
  if command -v find >/dev/null 2>&1; then
    # shellcheck disable=SC2012
    _fb_line=$(find "$checkpoint_nfs_root" -mindepth 2 -maxdepth 2 -type f -newermt "@${checkpoint_epoch_before_curl}" \
      -name "checkpoint-${podName}_${namespace}-${containerName}-*.tar" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1)
  fi
  if [[ -n "$_fb_line" ]]; then
    checkpointfile="${_fb_line#*$'\t'}"
    if [[ -n "$checkpointfile" && -f "$checkpointfile" ]]; then
      log "-- Using checkpoint from fallback path (not under expected node dir): $checkpointfile --"
    fi
  fi
fi

if [[ -z "$checkpointfile" || ! -f "$checkpointfile" ]]; then
  log "-- Directory listing (diagnostics): --"
  ls -la "$checkpoint_dir" >> "$log_file" 2>&1 || log "-- Cannot list $checkpoint_dir --"
  handle_error "Checkpoint archive not found on NFS for pod ${podName} (glob: $checkpoint_glob). Listing shows other replicas but not this pod — inspect kubelet/CRIU on node ${nodename} and checkpoint output above."
fi

log "-- Latest checkpoint found: $checkpointfile --"

log "------------------------------------------------------------------"

# Belt-and-braces: also enforce cpu-cap during runc-driven CRIU restore on destination nodes.
if [[ "$skipCpuCompatCheck" == true ]]; then
  kubectl config use-context "$destCluster" >>"$log_file" 2>&1 || handle_error "Failed to switch context to $destCluster for cpu-cap cleanup"
  ensure_criu_cpu_cap_on_active_context "$criuCpuCapMode" "false" "destination"
  kubectl config use-context "$sourceCluster" >>"$log_file" 2>&1 || handle_error "Failed to switch context back to $sourceCluster after cpu-cap cleanup"
else
  kubectl config use-context "$destCluster" >>"$log_file" 2>&1 || handle_error "Failed to switch context to $destCluster for cpu-cap setup"
  ensure_criu_cpu_cap_on_active_context "$criuCpuCapMode" "true" "destination"
  kubectl config use-context "$sourceCluster" >>"$log_file" 2>&1 || handle_error "Failed to switch context back to $sourceCluster after cpu-cap setup"
fi

log "-- Changing permissions for checkpoint file --"

startTime=$(date +%s%3N)
sudo chmod a+rwx "$checkpointfile" || handle_error "Failed to change permissions of checkpoint file"
permissionTime=$(($(date +%s%3N) - $startTime))

log "-- Permissions changed --"
if [[ "$skipCpuCompatCheck" == true ]]; then
  log "-- CRIU CPU compatibility check skipped by feature flag (--skip-cpu-compat-check) --"
else
  run_criu_cpu_compat_check "$checkpointfile" "$criuCpuCapMode" "$nodename" "$destCluster"
fi

log "------------------------------------------------------------------"

log "-- Post-checkpoint: stop source workload (replicas=0 / pod delete) — archive is on NFS --"
podDeletionStartTime=$(date +%s%3N)
stop_source_workload_after_checkpoint
podDeletionTime=$(($(date +%s%3N) - $podDeletionStartTime))

log "------------------------------------------------------------------"

checkpointfile_for_image="$checkpointfile"
normalized_checkpointfile="$log_dir/$(basename "${checkpointfile%.tar}").normalized.tar"
checkpoint_normalization_log="$log_dir/checkpoint_normalization.log"
if [[ -n "$checkpointNormalizeMounts" ]]; then
  checkpoint_normalization_bad_mounts="$checkpointNormalizeMounts"
else
  checkpoint_normalization_bad_mounts="normalizer default list"
fi

if [[ "$normalizeCheckpointMounts" == true ]]; then
  log "-- Checkpoint mount normalization enabled --"
  log "-- Checkpoint normalization bad mount list: $checkpoint_normalization_bad_mounts --"
  log "-- Checkpoint normalization input tar: $checkpointfile --"
  log "-- Checkpoint normalization output tar: $normalized_checkpointfile --"
  log "-- criu --version (migration host) --"
  criu --version >>"$log_file" 2>&1 || true
  log "-- crit --help (migration host) --"
  crit --help >>"$log_file" 2>&1 || true

  if ! command -v crit >/dev/null 2>&1; then
    handle_error "Checkpoint normalization is enabled but crit is not installed. Install CRIU/crit 4.2 on podmanvm or set NORMALIZE_CHECKPOINT_MOUNTS=false."
  fi

  checkpoint_normalizer="${SCRIPT_DIR}/../utils/setup/normalize_criu_checkpoint.py"
  if [[ ! -f "$checkpoint_normalizer" ]]; then
    handle_error "Checkpoint normalization utility not found: $checkpoint_normalizer"
  fi

  checkpoint_normalizer_args=(
    python3 "$checkpoint_normalizer"
    --checkpoint-tar "$checkpointfile"
    --output "$normalized_checkpointfile"
    --log-file "$checkpoint_normalization_log"
    --strict true
  )

  if [[ -n "$checkpointNormalizeMounts" ]]; then
    IFS=',' read -r -a checkpoint_normalization_mount_array <<< "$checkpointNormalizeMounts"
    for bad_mount in "${checkpoint_normalization_mount_array[@]}"; do
      bad_mount="${bad_mount#"${bad_mount%%[![:space:]]*}"}"
      bad_mount="${bad_mount%"${bad_mount##*[![:space:]]}"}"
      if [[ -n "$bad_mount" ]]; then
        checkpoint_normalizer_args+=(--bad-mount "$bad_mount")
      fi
    done
  fi

  startTime=$(date +%s%3N)
  : > "$checkpoint_normalization_log" || handle_error "Failed to create checkpoint normalization log"
  if ! "${checkpoint_normalizer_args[@]}" >>"$log_file" 2>&1; then
    checkpointNormalizationTime=$(($(date +%s%3N) - startTime))
    handle_error "Checkpoint normalization failed; refusing to build checkpoint image from unnormalized tar"
  fi
  checkpointNormalizationTime=$(($(date +%s%3N) - startTime))
  sudo chmod a+r "$normalized_checkpointfile" || handle_error "Failed to make normalized checkpoint file readable"
  checkpointfile_for_image="$normalized_checkpointfile"
  log "-- Checkpoint normalization completed in ${checkpointNormalizationTime} ms --"
else
  checkpointNormalizationTime=0
  log "-- Checkpoint mount normalization disabled; building checkpoint image from original tar --"
fi

log "------------------------------------------------------------------"

log "-- Convert checkpoint into image --"

startTime=$(date +%s%3N)
log "Checkpoint image name: $source_image_ref"
log "Checkpoint file: $checkpointfile"
log "Checkpoint file used for image: $checkpointfile_for_image"
newcontainer=$(buildah from --tls-verify=false "$source_image_ref") || handle_error "Failed to create new container"
buildah add "$newcontainer" "$checkpointfile_for_image" / || handle_error "Failed to add checkpoint file to container"
buildah config --annotation="io.kubernetes.cri-o.annotations.checkpoint.name=${containerName}" "$newcontainer" || handle_error "Failed to add checkpoint annotation to container"
if [[ "$skipCpuCompatCheck" == true ]]; then
  log "-- Skipping CRIU checkpoint.options cpu-cap annotation because --skip-cpu-compat-check is enabled --"
else
  buildah config --annotation="io.kubernetes.cri-o.annotations.checkpoint.options=--cpu-cap=${criuCpuCapMode}" "$newcontainer" || handle_error "Failed to add CRIU cpu-cap restore annotation to container"
fi
buildah config --annotation=io.container.manager=crio "$newcontainer" || handle_error "Failed to add crio annotation to container"
newImageTime=$(($(date +%s%3N) - $startTime))

checkpoint_image_name=$(image="$source_image_ref" && image=${image##*/} && image=${image%%:*} && echo "$image") || handle_error "Failed to get image name"
checkpoint_image_tag="checkpoint-$(date +%Y%m%d%H%M%S)-${RANDOM}"
local_checkpoint_image_ref="${checkpoint_image_name}:${checkpoint_image_tag}"
registry_checkpoint_image_ref="${migrationRegistry}/${checkpoint_image_name}:${checkpoint_image_tag}"

log "Checkpoint image name: $checkpoint_image_name"
log "Checkpoint image tag: $checkpoint_image_tag"
log "-- Commiting new image --"

startTime=$(date +%s%3N)
buildah commit "$newcontainer" "$local_checkpoint_image_ref" || handle_error "Failed to commit new image"
buildah rm "$newcontainer" || handle_error "Failed to remove new container"

log "-- Pushing image \"$registry_checkpoint_image_ref\" to local registry --"
buildah push --tls-verify=false "localhost/$local_checkpoint_image_ref" "$registry_checkpoint_image_ref" || handle_error "Failed to push image to local registry"
pushImageTime=$(($(date +%s%3N) - $startTime))

log "-- Image pushed onto local registy --"

log "------------------------------------------------------------------"

kubectl config use-context "$destCluster" || handle_error "Failed to switch context to $destCluster"
kubectl config set-context --current --namespace="$namespace"

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
export DEST_CLUSTER="$destCluster"
log "-- Restore pod label cluster (DEST_CLUSTER): $DEST_CLUSTER --"

sed -e "s/${templateContainerName}-restore/${newPodName}/g" \
    -e "s|^\([[:space:]]*image:[[:space:]]*\).*|\1${registry_checkpoint_image_ref}|g" \
    "$restoreTemplate" | envsubst '${DEST_CLUSTER}' > "$restoreManifest" || handle_error "Failed to generate restore yaml file"

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

kubectl_apply_dest "$restoreManifest" "apply restore yaml file"

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
  kubectl config use-context "$sourceCluster" || handle_error "Failed to switch context to $sourceCluster for traffic switch"
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
      if [[ "$istio_pre_checkpoint_503_applied" == true && "$selected_virtualservice" == "routing-demo" ]]; then
        kubectl patch virtualservice "$selected_virtualservice" --type=json -p='[
          {"op":"remove","path":"/spec/http/0/fault"},
          {"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v2"}
        ]' >>"$log_file" 2>&1 || {
          log "-- Warning: combined remove fault + route v2 failed; removing fault then patching subset --"
          kubectl patch virtualservice "$selected_virtualservice" --type=json -p='[{"op":"remove","path":"/spec/http/0/fault"}]' >>"$log_file" 2>&1 || true
          kubectl patch virtualservice "$selected_virtualservice" --type=json -p='[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v2"}]' || handle_error "Failed to redirect traffic to new app"
        }
      else
        kubectl patch virtualservice "$selected_virtualservice" --type='json' -p='[
          {
            "op": "replace",
            "path": "/spec/http/0/route/0/destination/subset",
            "value": "v2"
          }
        ]' || handle_error "Failed to redirect traffic to new app"
      fi
    else
      log "-- Warning: No VirtualService found (expected \"$appName\" or \"routing-demo\"); skipping traffic switch --"
    fi
  else
    log "-- No Istio VirtualService patch for this workload (not mmt-probe, namespace not istio-enabled) --"
  fi
  log "-- Traffic switch step completed --"
else
  log "-- Warning: $newPodName did not start within 5 minutes, but migration artifacts are in place --"
  log "-- You may need to check the pod status manually --"
  podReadyTime=$(($(date +%s%3N) - $startTime))
  log "-- Traffic switch skipped (restore pod not running) --"
fi

migrationTotalTime=$(($(date +%s%3N) - $migrationStartTime))

log "------------------------------------------------------------------"

if [[ "$source_workload_stopped" != true ]]; then
  log "-- Warning: Source workload was not stopped after checkpoint; stopping now --"
  podDeletionStartTime=$(date +%s%3N)
  stop_source_workload_after_checkpoint
  podDeletionTime=$(($(date +%s%3N) - $podDeletionStartTime))
else
  log "-- Source workload already stopped immediately after checkpoint (no duplicate scale-down) --"
fi
log "-- Source workload cleanup completed --"

log "------------------------------------------------------------------"

log "-- Summarizing migration performance --"
summarize_performance
log "-- Performance summary created --"


if [ "$forensicAnalysis" == true ]; then
  log "-- Performing forensic analysis --"
  sudo chmod 770 "${SCRIPT_DIR}/../utils/forensic_analysis/forensic_analysis.sh"
  "${SCRIPT_DIR}/../utils/forensic_analysis/forensic_analysis.sh" "$checkpointfile" "$log_dir" || handle_error "Failed to perform forensic analysis"
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
checkpoint_nfs_root="${CHECKPOINT_NFS_ROOT:-/home/ubuntu/nfs/checkpoints}"
checkpointDir="${checkpoint_nfs_root}/${nodename}/checkpoint-*_${namespace}-${baseAppName}-*.tar"
log "-- Deleting old checkpoints for application ${baseAppName} if more than 5 are saved --"

checkpointCount=$(ls $checkpointDir 2>/dev/null | wc -l)
if [ "$checkpointCount" -gt 5 ]; then
  excessCount=$((checkpointCount - 5))
  log "-- $checkpointCount checkpoint files for ${baseAppName} on source node $nodename detected. Deleting oldest $excessCount files... --"
  
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
  log "-- $checkpointCount checkpoint files for ${baseAppName} on source node $nodename detected (within limit) --"
fi

log "------------------------------------------------------------------"
log "-- Migration complete --"

exit 0
