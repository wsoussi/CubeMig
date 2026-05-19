#!/usr/bin/env bash
# Evaluation wrapper around an existing migration command.
#
# Goals:
#   - Capture environment context (k8s, istio, wg0, host metrics, checkpoint
#     metadata) around a single migration run.
#   - Never modify state; never hide the original migration exit code.
#   - Best-effort diagnostics: each collector failure is logged but never
#     aborts the wrapper.
#   - Refuse to copy/exfiltrate secrets: no kubeconfig files, .env files,
#     service-account tokens, WireGuard private keys or full checkpoint
#     archives are read or written by this script. Memory inspection
#     (checkpointctl memparse / gdb) is intentionally not run by default.
#
# See README.md in this directory for the design context and the
# cluster-pnet -> cluster-sev-snp / cluster1 -> cluster-sev-snp scenarios.

set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage:
  run_eval_migration.sh \
    --run-id <id> \
    --source <kubectl-context> \
    --dest <kubectl-context> \
    --namespace <namespace> \
    --workload <routing-demo|mmt-probe|vuln-spring> \
    --pod <pod-name> \
    --load-rps <number> \
    --concurrency <number> \
    --trigger <manual|falco|simulate> \
    [--out-root <path>]          (default: /home/ubuntu/evaluation-runs) \
    [--checkpoint-root <path>]   (default: /home/ubuntu/nfs/checkpoints) \
    [--probe-url <url>] \
    [--probe-interval-ms <ms>]   (default: 500) \
    [--probe-pre-seconds <s>]    (default: 30) \
    [--probe-post-seconds <s>]   (default: 60) \
    [--istio-routing-context <kubectl-context>] (default: cluster1) \
    [--expected-initial-subset <subset>]  (default: v1) \
    [--allow-existing-fault]     (default: abort if Istio fault present) \
    -- <migration command and its arguments>
USAGE
}

readonly WRAPPER_VERSION="1.1.0"
readonly CUBEMIG_ROOT="/home/ubuntu/teemig/CubeMig"
readonly CONT_MIGRATION_LOG_ROOT="/home/ubuntu/contMigration_logs"

# Argument parsing

OUT_ROOT="/home/ubuntu/evaluation-runs"
CHECKPOINT_ROOT="/home/ubuntu/nfs/checkpoints"

RUN_ID=""
SOURCE_CTX=""
DEST_CTX=""
NAMESPACE=""
WORKLOAD=""
POD=""
LOAD_RPS=""
CONCURRENCY=""
TRIGGER=""
PROBE_URL=""
PROBE_INTERVAL_MS=500
PROBE_PRE_SECONDS=30
PROBE_POST_SECONDS=60
EXPECTED_INITIAL_SUBSET="v1"
ISTIO_ROUTING_CONTEXT="${ISTIO_ROUTING_CONTEXT:-cluster1}"
ALLOW_EXISTING_FAULT=false
MIGRATION_CMD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)          RUN_ID="${2:-}";          shift 2 ;;
        --source)          SOURCE_CTX="${2:-}";      shift 2 ;;
        --dest)            DEST_CTX="${2:-}";        shift 2 ;;
        --namespace)       NAMESPACE="${2:-}";       shift 2 ;;
        --workload)        WORKLOAD="${2:-}";        shift 2 ;;
        --pod)             POD="${2:-}";             shift 2 ;;
        --load-rps)        LOAD_RPS="${2:-}";        shift 2 ;;
        --concurrency)     CONCURRENCY="${2:-}";     shift 2 ;;
        --trigger)         TRIGGER="${2:-}";         shift 2 ;;
        --out-root)        OUT_ROOT="${2:-}";        shift 2 ;;
        --checkpoint-root) CHECKPOINT_ROOT="${2:-}"; shift 2 ;;
        --probe-url)              PROBE_URL="${2:-}";              shift 2 ;;
        --probe-interval-ms)      PROBE_INTERVAL_MS="${2:-}";      shift 2 ;;
        --probe-pre-seconds)      PROBE_PRE_SECONDS="${2:-}";      shift 2 ;;
        --probe-post-seconds)     PROBE_POST_SECONDS="${2:-}";     shift 2 ;;
        --istio-routing-context)  ISTIO_ROUTING_CONTEXT="${2:-}";  shift 2 ;;
        --expected-initial-subset) EXPECTED_INITIAL_SUBSET="${2:-}"; shift 2 ;;
        --allow-existing-fault)   ALLOW_EXISTING_FAULT=true;       shift ;;
        --allow-existing-fault=*) ALLOW_EXISTING_FAULT="${1#*=}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; MIGRATION_CMD=("$@"); break ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done
ISTIO_ROUTING_CONTEXT="${ISTIO_ROUTING_CONTEXT:-cluster1}"

missing=()
for var in RUN_ID SOURCE_CTX DEST_CTX NAMESPACE WORKLOAD POD LOAD_RPS CONCURRENCY TRIGGER; do
    # shellcheck disable=SC1083
    if [[ -z "${!var:-}" ]]; then
        missing+=("$var")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required arguments: ${missing[*]}" >&2
    usage >&2
    exit 2
fi
if [[ ${#MIGRATION_CMD[@]} -eq 0 ]]; then
    echo "Missing migration command after '--'" >&2
    usage >&2
    exit 2
fi

case "$WORKLOAD" in
    routing-demo|mmt-probe|vuln-spring) ;;
    *) echo "Invalid --workload value: $WORKLOAD (expected routing-demo|mmt-probe|vuln-spring)" >&2; exit 2 ;;
esac

case "$TRIGGER" in
    manual|falco|simulate) ;;
    *) echo "Invalid --trigger value: $TRIGGER (expected manual|falco|simulate)" >&2; exit 2 ;;
esac

# Run directory layout

DATE_DIR="$(date -u +%F)"
RUN_DIR="$OUT_ROOT/$DATE_DIR/$RUN_ID"
CKPT_DIR="$RUN_DIR/checkpoint"
mkdir -p "$RUN_DIR" "$CKPT_DIR"

START_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_TIME_UTC=""
MIGRATION_EXIT=-1
CHECKPOINT_FILE=""
METRICS_PID=""
PROBE_PID=""
FULL_COMMAND=""
GIT_COMMIT=""
PRE_EXISTING_FAULT_DETECTED=false
MIGRATION_LOG_FOUND=false
HTTP_PROBE_EXISTS=false

# Helpers

log() {
    printf '[eval %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

# Render a value as a JSON number if it parses as int/float, otherwise null.
# Used for metadata.json so non-numeric input never produces invalid JSON.
json_num() {
    local v="${1:-}"
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$v"
    else
        printf 'null'
    fi
}

# Minimal JSON string escaping (quotes + backslashes + newlines).
json_str() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    printf '"%s"' "$v"
}

write_metadata() {
    local git_val="${GIT_COMMIT:-}"
    local probe_meta="false"
    local fault_meta="false"
    local log_meta="false"
    [[ -z "$git_val" ]] && git_val="null" || git_val="$(json_str "$git_val")"
    [[ "$HTTP_PROBE_EXISTS" == true || "$HTTP_PROBE_EXISTS" == "true" ]] && probe_meta="true"
    [[ "$PRE_EXISTING_FAULT_DETECTED" == true || "$PRE_EXISTING_FAULT_DETECTED" == "true" ]] && fault_meta="true"
    [[ "$MIGRATION_LOG_FOUND" == true || "$MIGRATION_LOG_FOUND" == "true" ]] && log_meta="true"
    {
        printf '{\n'
        printf '  "run_id": %s,\n'         "$(json_str "$RUN_ID")"
        printf '  "source": %s,\n'         "$(json_str "$SOURCE_CTX")"
        printf '  "dest": %s,\n'           "$(json_str "$DEST_CTX")"
        printf '  "namespace": %s,\n'      "$(json_str "$NAMESPACE")"
        printf '  "workload": %s,\n'       "$(json_str "$WORKLOAD")"
        printf '  "pod": %s,\n'            "$(json_str "$POD")"
        printf '  "load_rps": %s,\n'       "$(json_num "$LOAD_RPS")"
        printf '  "concurrency": %s,\n'    "$(json_num "$CONCURRENCY")"
        printf '  "trigger": %s,\n'        "$(json_str "$TRIGGER")"
        printf '  "istio_routing_context": %s,\n' "$(json_str "$ISTIO_ROUTING_CONTEXT")"
        printf '  "start_time_utc": %s,\n' "$(json_str "$START_TIME_UTC")"
        printf '  "end_time_utc": %s,\n'   "$(json_str "$END_TIME_UTC")"
        printf '  "exit_code": %s,\n'      "$(json_num "$MIGRATION_EXIT")"
        printf '  "run_dir": %s,\n'         "$(json_str "$RUN_DIR")"
        printf '  "wrapper_version": %s,\n' "$(json_str "$WRAPPER_VERSION")"
        printf '  "git_commit": %s,\n'      "$git_val"
        printf '  "full_command": %s,\n'    "$(json_str "$FULL_COMMAND")"
        printf '  "http_probe_csv": %s,\n'  "$(json_str "$probe_meta")"
        printf '  "pre_existing_fault_detected": %s,\n' "$(json_str "$fault_meta")"
        printf '  "migration_log_found": %s\n' "$(json_str "$log_meta")"
        printf '}\n'
    } > "$RUN_DIR/metadata.json"
}

stop_metrics_loop() {
    if [[ -n "${METRICS_PID:-}" ]] && kill -0 "$METRICS_PID" 2>/dev/null; then
        kill "$METRICS_PID" 2>/dev/null || true
        wait "$METRICS_PID" 2>/dev/null || true
    fi
    METRICS_PID=""
}

stop_http_probe_loop() {
    if [[ -n "${PROBE_PID:-}" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
        kill "$PROBE_PID" 2>/dev/null || true
        wait "$PROBE_PID" 2>/dev/null || true
    fi
    PROBE_PID=""
}

on_exit() {
    stop_http_probe_loop
    stop_metrics_loop
}
trap on_exit EXIT

# Escape a value for http_probe.csv (always quoted).
probe_csv_field() {
    local v="${1:-}"
    v="${v//$'\r'/}"
    v="${v//$'\n'/ }"
    v="${v//\"/\"\"}"
    printf '"%s"' "$v"
}

# Inject or replace --log-dir so single-migration.sh writes timestamped lines into RUN_DIR.
inject_migration_log_dir() {
    local -a new_cmd=()
    local i=0
    local has_log_dir=false
    while (( i < ${#MIGRATION_CMD[@]} )); do
        if [[ "${MIGRATION_CMD[i]}" == "--log-dir" ]]; then
            has_log_dir=true
            new_cmd+=("--log-dir" "$RUN_DIR")
            i=$((i + 2))
            continue
        fi
        new_cmd+=("${MIGRATION_CMD[i]}")
        i=$((i + 1))
    done
    if [[ "$has_log_dir" == false ]]; then
        new_cmd+=("--log-dir" "$RUN_DIR")
    fi
    MIGRATION_CMD=("${new_cmd[@]}")
}

# True when the file has ISO8601 lines from single-migration.sh log().
migration_log_looks_timestamped() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    head -n 30 "$f" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
}

# Copy single-migration.sh migration_log.txt into migration.log (search fallback if needed).
collect_migration_log() {
    if [[ -f "$RUN_DIR/migration_log.txt" ]] && migration_log_looks_timestamped "$RUN_DIR/migration_log.txt"; then
        cp "$RUN_DIR/migration_log.txt" "$RUN_DIR/migration.log"
        MIGRATION_LOG_FOUND=true
        return 0
    fi
    if [[ -f "$RUN_DIR/migration.log" ]] && migration_log_looks_timestamped "$RUN_DIR/migration.log"; then
        cp "$RUN_DIR/migration.log" "$RUN_DIR/migration_log.txt"
        MIGRATION_LOG_FOUND=true
        return 0
    fi
    if [[ -f "$RUN_DIR/migration.log" ]] && ! migration_log_looks_timestamped "$RUN_DIR/migration.log"; then
        rm -f "$RUN_DIR/migration.log"
    fi
    local found=""
    if [[ -d "$CONT_MIGRATION_LOG_ROOT" ]]; then
        # Match only this pod's log dir (e.g. …/routing-demo/2026-…_routing-demo-xxx/migration_log.txt).
        found=$(find "$CONT_MIGRATION_LOG_ROOT" -type f -name 'migration_log.txt' -newermt "$START_TIME_UTC" \
            -path "*${POD}*" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
    fi
    if [[ -n "$found" && -f "$found" ]]; then
        cp "$found" "$RUN_DIR/migration_log.txt"
        cp "$found" "$RUN_DIR/migration.log"
        MIGRATION_LOG_FOUND=true
        log "Copied timestamped migration log from $found -> migration_log.txt"
    fi
}

# Pre-migration Istio / pod sanity (may abort before migration).
run_pre_migration_sanity() {
    local out="$RUN_DIR/pre_run_sanity.txt"
    local vs_yaml=""
    local current_subset=""
    local fault_present=false

    : > "$out"
    {
        echo "# pre-run sanity ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
        echo
        echo "## kubectl --context $ISTIO_ROUTING_CONTEXT -n istio-enabled get virtualservice routing-demo -o yaml"
        vs_yaml=$(kubectl --context "$ISTIO_ROUTING_CONTEXT" -n istio-enabled get virtualservice routing-demo -o yaml 2>&1) || vs_yaml="(failed)"
        printf '%s\n' "$vs_yaml"
        echo
        echo "## kubectl --context $SOURCE_CTX -n $NAMESPACE get pod $POD -o wide"
        kubectl --context "$SOURCE_CTX" -n "$NAMESPACE" get pod "$POD" -o wide 2>&1 || echo "(failed)"
        echo
        if [[ -n "$PROBE_URL" ]]; then
            echo "## curl -sS -i $PROBE_URL (single probe)"
            curl -sS -i --connect-timeout 5 --max-time 15 "$PROBE_URL" 2>&1 || echo "(curl failed)"
            echo
        fi
    } >> "$out" 2>/dev/null || true

    if kubectl --context "$ISTIO_ROUTING_CONTEXT" -n istio-enabled get virtualservice routing-demo \
        -o jsonpath='{.spec.http[0].fault}' 2>/dev/null | grep -q .; then
        fault_present=true
    fi

    if [[ "$fault_present" == true ]]; then
        PRE_EXISTING_FAULT_DETECTED=true
        echo "pre-existing Istio fault detected on routing-demo VirtualService ($ISTIO_ROUTING_CONTEXT)" >> "$out"
        if [[ "$ALLOW_EXISTING_FAULT" != true && "$ALLOW_EXISTING_FAULT" != "true" && "$ALLOW_EXISTING_FAULT" != "1" ]]; then
            echo "pre-existing Istio fault detected; clear fault before evaluation run" >> "$out"
            log "ABORT: pre-existing Istio fault detected; clear fault before evaluation run"
            return 1
        fi
        log "Warning: pre-existing Istio fault present (--allow-existing-fault enabled)"
    fi

    current_subset=$(kubectl --context "$ISTIO_ROUTING_CONTEXT" -n istio-enabled get virtualservice routing-demo \
        -o jsonpath='{.spec.http[0].route[0].destination.subset}' 2>/dev/null || true)
    if [[ -n "$current_subset" && "$current_subset" != "$EXPECTED_INITIAL_SUBSET" ]]; then
        log "Warning: routing-demo subset is '$current_subset', expected '$EXPECTED_INITIAL_SUBSET'"
        echo "subset mismatch: current=$current_subset expected=$EXPECTED_INITIAL_SUBSET" >> "$out"
    elif [[ -n "$current_subset" ]]; then
        echo "subset ok: $current_subset" >> "$out"
    fi
    return 0
}

# Background HTTP probe -> http_probe.csv
start_http_probe_loop() {
    local out="$RUN_DIR/http_probe.csv"
    local interval_s
    interval_s=$(awk -v ms="$PROBE_INTERVAL_MS" 'BEGIN { printf "%.3f", ms/1000 }')
    echo "timestamp_utc,request_id,http_status,latency_ms,counter,cluster,version,body,error" > "$out"
    HTTP_PROBE_EXISTS=true
    (
        local req_id=0
        while true; do
            req_id=$((req_id + 1))
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            t0=$(date +%s%3N 2>/dev/null || date +%s)
            resp_file=$(mktemp)
            http_status=$(curl -sS -o "$resp_file" -w '%{http_code}' \
                --connect-timeout 5 --max-time 15 "$PROBE_URL" 2>"${resp_file}.err") || http_status="000"
            t1=$(date +%s%3N 2>/dev/null || date +%s)
            latency_ms=$((t1 - t0))
            body=$(head -c 4096 "$resp_file" 2>/dev/null | tr -d '\r' || true)
            err=$(head -c 512 "${resp_file}.err" 2>/dev/null | tr '\n' ' ' || true)
            rm -f "$resp_file" "${resp_file}.err"
            counter=""; cluster=""; version=""
            if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
                counter=$(printf '%s' "$body" | jq -r '.counter // empty' 2>/dev/null || true)
                cluster=$(printf '%s' "$body" | jq -r '.cluster // empty' 2>/dev/null || true)
                version=$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null || true)
            fi
            {
                probe_csv_field "$ts"; printf ','
                probe_csv_field "$req_id"; printf ','
                probe_csv_field "$http_status"; printf ','
                probe_csv_field "$latency_ms"; printf ','
                probe_csv_field "$counter"; printf ','
                probe_csv_field "$cluster"; printf ','
                probe_csv_field "$version"; printf ','
                probe_csv_field "$body"; printf ','
                probe_csv_field "$err"
                printf '\n'
            } >> "$out" 2>/dev/null || break
            sleep "$interval_s"
        done
    ) &
    PROBE_PID=$!
}

# Per-context k8s snapshot used both before and after migration.
collect_k8s_snapshot() {
    local out="$1"
    : > "$out"
    local ctx
    for ctx in "$SOURCE_CTX" "$DEST_CTX"; do
        {
            echo "================================================================"
            echo "# context: $ctx | namespace: $NAMESPACE"
            echo "================================================================"
            echo
            echo "## kubectl --context $ctx -n $NAMESPACE get pods -o wide"
            kubectl --context "$ctx" -n "$NAMESPACE" get pods -o wide 2>&1 || echo "(failed)"
            echo
            echo "## kubectl --context $ctx -n $NAMESPACE get svc,endpoints,endpointslices -o wide"
            kubectl --context "$ctx" -n "$NAMESPACE" get svc,endpoints,endpointslices -o wide 2>&1 || echo "(failed)"
            echo
            echo "## kubectl --context $ctx -n $NAMESPACE get events --sort-by=.lastTimestamp | tail -80"
            kubectl --context "$ctx" -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -80 || echo "(failed)"
            echo
            echo "## kubectl --context $ctx get nodes -o wide"
            kubectl --context "$ctx" get nodes -o wide 2>&1 || echo "(failed)"
            echo
        } >> "$out" 2>/dev/null || true
    done
}

# Istio control plane snapshot from the selected central routing context.
collect_istio_snapshot() {
    local out="$1"
    {
        echo "# best-effort istio snapshot from $ISTIO_ROUTING_CONTEXT"
        echo "## kubectl --context $ISTIO_ROUTING_CONTEXT -n istio-enabled get virtualservice,destinationrule,gateway -o yaml"
        kubectl --context "$ISTIO_ROUTING_CONTEXT" -n istio-enabled get virtualservice,destinationrule,gateway -o yaml 2>&1 \
            || echo "(failed)"
    } > "$out" 2>/dev/null || true
}

# WireGuard interface snapshot. We never read the private key — wg show outputs
# the public keys, endpoints and transfer counters but redacts the secret material
# we do not request. ip -s adds the per-direction byte/packet counters that are
# useful for the cluster-pnet evaluation runs.
collect_wg_snapshot() {
    local out="$1"
    if ip link show wg0 >/dev/null 2>&1; then
        {
            echo "## wg show"
            wg show 2>&1 || echo "(failed: wg show — is wireguard-tools installed and accessible?)"
            echo
            echo "## ip -s link show wg0"
            ip -s link show wg0 2>&1 || echo "(failed)"
        } > "$out" 2>/dev/null || true
    else
        echo "wg0 not present on this host" > "$out"
    fi
}

# Lightweight per-second host metrics loop. Reads from /proc and /sys only;
# never touches secrets or kubeconfig data.
start_host_metrics_loop() {
    local out="$1"
    echo "timestamp_utc,loadavg_1,mem_available_kb,ens3_rx_bytes,ens3_tx_bytes,wg0_rx_bytes,wg0_tx_bytes" > "$out"
    (
        while true; do
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            loadavg="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
            mem="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
            if [[ -r /sys/class/net/ens3/statistics/rx_bytes ]]; then
                ens3_rx="$(cat /sys/class/net/ens3/statistics/rx_bytes 2>/dev/null || true)"
                ens3_tx="$(cat /sys/class/net/ens3/statistics/tx_bytes 2>/dev/null || true)"
            else
                ens3_rx=""; ens3_tx=""
            fi
            if [[ -r /sys/class/net/wg0/statistics/rx_bytes ]]; then
                wg_rx="$(cat /sys/class/net/wg0/statistics/rx_bytes 2>/dev/null || true)"
                wg_tx="$(cat /sys/class/net/wg0/statistics/tx_bytes 2>/dev/null || true)"
            else
                wg_rx=""; wg_tx=""
            fi
            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$ts" "${loadavg:-}" "${mem:-}" \
                "${ens3_rx:-}" "${ens3_tx:-}" \
                "${wg_rx:-}" "${wg_tx:-}" \
                >> "$out" 2>/dev/null || break
            sleep 1
        done
    ) &
    METRICS_PID=$!
}

# Extract a checkpoint .tar path that the migration may have logged.
# Patterns we accept include the typical NFS layout used in this thesis.
find_checkpoint_in_log() {
    local found=""
    local f
    for f in "$RUN_DIR/migration.log" "$RUN_DIR/migration.stdout.log"; do
        if [[ -f "$f" ]]; then
            found=$(grep -Eo '/home/ubuntu/nfs/checkpoints/[^[:space:]"]*checkpoint-[^[:space:]"]*\.tar' "$f" 2>/dev/null \
                | tail -n 1 || true)
            [[ -n "$found" ]] && break
        fi
    done
    printf '%s' "$found"
}

# Fallback: newest checkpoint .tar under the configured root since the run started.
find_checkpoint_by_mtime() {
    local root="$1"
    local since="$2"
    if [[ ! -d "$root" ]]; then
        return 0
    fi
    find "$root" -type f -name 'checkpoint-*.tar' -newermt "$since" -printf '%T@\t%s\t%p\n' 2>/dev/null \
        | sort -n | tail -1 | awk -F'\t' '{print $3}'
}

# Checkpoint metadata only — never copy the archive itself, never inspect process memory.
inspect_checkpoint() {
    local ckpt="$1"

    echo "$ckpt" > "$CKPT_DIR/checkpoint_path.txt"

    stat "$ckpt" > "$CKPT_DIR/checkpoint_stat.txt" 2>&1 \
        || echo "(stat failed for $ckpt)" > "$CKPT_DIR/checkpoint_stat.txt"

    sha256sum "$ckpt" > "$CKPT_DIR/checkpoint_sha256.txt" 2>&1 \
        || echo "(sha256sum failed for $ckpt)" > "$CKPT_DIR/checkpoint_sha256.txt"

    # tar -t lists archive members only (no extraction); safe to keep next to metadata.
    tar -tf "$ckpt" > "$CKPT_DIR/checkpoint_tar_listing.txt" 2>&1 \
        || echo "(tar -tf failed for $ckpt)" > "$CKPT_DIR/checkpoint_tar_listing.txt"

    if command -v checkpointctl >/dev/null 2>&1; then
        # 'show' = summary, 'inspect' = process tree. We deliberately do NOT call
        # 'checkpointctl memparse' or run gdb here: those can expose secrets from
        # the running process memory (env vars, request bodies, keys).
        checkpointctl show "$ckpt" > "$CKPT_DIR/checkpointctl_show.txt" 2>&1 \
            || echo "(checkpointctl show failed for $ckpt)" >> "$CKPT_DIR/checkpointctl_show.txt"
        checkpointctl inspect "$ckpt" > "$CKPT_DIR/checkpointctl_inspect.txt" 2>&1 \
            || echo "(checkpointctl inspect failed for $ckpt)" >> "$CKPT_DIR/checkpointctl_inspect.txt"
    else
        echo "checkpointctl not installed" > "$CKPT_DIR/checkpointctl_show.txt"
        echo "checkpointctl not installed" > "$CKPT_DIR/checkpointctl_inspect.txt"
    fi
}

write_artifact_sizes() {
    local out="$RUN_DIR/artifact_sizes.txt"
    {
        echo "## newest checkpoint files under $CHECKPOINT_ROOT (last 20 minutes; mtime epoch, size bytes, path)"
        if [[ -d "$CHECKPOINT_ROOT" ]]; then
            find "$CHECKPOINT_ROOT" -type f -name 'checkpoint-*.tar' -newermt '-20 minutes' \
                -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn | head -20 || true
        else
            echo "(checkpoint root $CHECKPOINT_ROOT not readable)"
        fi
        echo
        echo "## du -sh $CHECKPOINT_ROOT"
        du -sh "$CHECKPOINT_ROOT" 2>&1 || echo "(du failed)"
    } > "$out" 2>/dev/null || true
}

collect_failure_diagnostics() {
    local out="$RUN_DIR/failure_diagnostics.txt"
    : > "$out"
    local ctx
    for ctx in "$SOURCE_CTX" "$DEST_CTX"; do
        {
            echo "================================================================"
            echo "# context: $ctx — describe + recent events (namespace: $NAMESPACE)"
            echo "================================================================"
            echo
            echo "## kubectl --context $ctx -n $NAMESPACE describe pods"
            kubectl --context "$ctx" -n "$NAMESPACE" describe pods 2>&1 || echo "(failed)"
            echo
            echo "## kubectl --context $ctx -n $NAMESPACE get events --sort-by=.lastTimestamp | tail -120"
            kubectl --context "$ctx" -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -120 \
                || echo "(failed)"
            echo
        } >> "$out" 2>/dev/null || true
    done
    if [[ "$DEST_CTX" == "cluster-sev-snp" ]]; then
        {
            echo "================================================================"
            echo "# destination is cluster-sev-snp — local kubelet / cri-o journals"
            echo "================================================================"
            echo
            echo "## sudo journalctl -u snap.microk8s.daemon-kubelite --since '20 minutes ago'"
            sudo -n journalctl -u snap.microk8s.daemon-kubelite --since "20 minutes ago" 2>&1 \
                || echo "(failed or sudo not available without password)"
            echo
            echo "## sudo journalctl -u crio --since '20 minutes ago'"
            sudo -n journalctl -u crio --since "20 minutes ago" 2>&1 \
                || echo "(failed or sudo not available without password)"
        } >> "$out" 2>/dev/null || true
    fi
}

# Quote a CSV field with double quotes if it contains a comma, quote or newline.
csv_field() {
    local v="${1:-}"
    if [[ "$v" == *,* || "$v" == *\"* || "$v" == *$'\n'* ]]; then
        v="${v//\"/\"\"}"
        printf '"%s"' "$v"
    else
        printf '%s' "$v"
    fi
}

append_results_row() {
    local csv="$OUT_ROOT/evaluation_results.csv"
    local probe_flag="false"
    local fault_flag="false"
    local log_flag="false"
    [[ "$HTTP_PROBE_EXISTS" == true || "$HTTP_PROBE_EXISTS" == "true" ]] && probe_flag="true"
    [[ "$PRE_EXISTING_FAULT_DETECTED" == true || "$PRE_EXISTING_FAULT_DETECTED" == "true" ]] && fault_flag="true"
    [[ "$MIGRATION_LOG_FOUND" == true || "$MIGRATION_LOG_FOUND" == "true" ]] && log_flag="true"
    if [[ ! -f "$csv" ]]; then
        echo "run_id,source,dest,namespace,workload,pod,load_rps,concurrency,trigger,start_time_utc,end_time_utc,exit_code,run_dir,checkpoint_file,http_probe_csv,pre_existing_fault_detected,migration_log_found" > "$csv"
    fi
    {
        csv_field "$RUN_ID";         printf ','
        csv_field "$SOURCE_CTX";     printf ','
        csv_field "$DEST_CTX";       printf ','
        csv_field "$NAMESPACE";      printf ','
        csv_field "$WORKLOAD";       printf ','
        csv_field "$POD";            printf ','
        csv_field "$LOAD_RPS";       printf ','
        csv_field "$CONCURRENCY";    printf ','
        csv_field "$TRIGGER";        printf ','
        csv_field "$START_TIME_UTC"; printf ','
        csv_field "$END_TIME_UTC";   printf ','
        csv_field "$MIGRATION_EXIT"; printf ','
        csv_field "$RUN_DIR";        printf ','
        csv_field "$CHECKPOINT_FILE"; printf ','
        csv_field "$probe_flag";     printf ','
        csv_field "$fault_flag";     printf ','
        csv_field "$log_flag"
        printf '\n'
    } >> "$csv" || true
}

# Main flow

if command -v git >/dev/null 2>&1; then
    GIT_COMMIT=$(git -C "$CUBEMIG_ROOT" rev-parse HEAD 2>/dev/null || true)
fi

# Initial metadata (exit_code is still -1 = running).
write_metadata

log "Run $RUN_ID starting (source=$SOURCE_CTX, dest=$DEST_CTX, workload=$WORKLOAD, trigger=$TRIGGER)"
log "Run directory: $RUN_DIR"
log "Using Istio routing context: $ISTIO_ROUTING_CONTEXT"

# Pre-migration snapshots.
log "Collecting k8s_before.txt"
collect_k8s_snapshot "$RUN_DIR/k8s_before.txt" || true

log "Collecting istio_before.yaml (best-effort against $ISTIO_ROUTING_CONTEXT)"
collect_istio_snapshot "$RUN_DIR/istio_before.yaml" || true

log "Collecting wg_before.txt (if wg0 exists)"
collect_wg_snapshot "$RUN_DIR/wg_before.txt" || true

log "Running pre-migration sanity checks"
if ! run_pre_migration_sanity; then
    MIGRATION_EXIT=2
    END_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_metadata
    append_results_row
    log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): pre-existing Istio fault"
    exit "$MIGRATION_EXIT"
fi

# Host metrics loop runs across the entire migration window.
log "Starting host metrics loop"
start_host_metrics_loop "$RUN_DIR/host_metrics.csv"

if [[ -n "$PROBE_URL" ]]; then
    log "Starting HTTP probe loop (url=$PROBE_URL, interval=${PROBE_INTERVAL_MS}ms)"
    start_http_probe_loop
    if [[ "$PROBE_PRE_SECONDS" =~ ^[0-9]+$ ]] && (( PROBE_PRE_SECONDS > 0 )); then
        log "HTTP probe pre-migration baseline (${PROBE_PRE_SECONDS}s)"
        sleep "$PROBE_PRE_SECONDS"
    fi
fi

inject_migration_log_dir
FULL_COMMAND="${MIGRATION_CMD[*]}"

# Run migration: stdout/stderr -> migration.stdout.log; timestamped log via --log-dir.
log "Running migration: ${MIGRATION_CMD[*]}"
set +e
set +o pipefail
"${MIGRATION_CMD[@]}" 2>&1 | tee "$RUN_DIR/migration.stdout.log"
MIGRATION_EXIT="${PIPESTATUS[0]}"
set -e
set -o pipefail
log "Migration exited with code $MIGRATION_EXIT"

if [[ -n "$PROBE_URL" && "$PROBE_POST_SECONDS" =~ ^[0-9]+$ ]] && (( PROBE_POST_SECONDS > 0 )); then
    log "HTTP probe post-migration (${PROBE_POST_SECONDS}s)"
    sleep "$PROBE_POST_SECONDS"
fi
stop_http_probe_loop

collect_migration_log || true
if [[ "$MIGRATION_LOG_FOUND" != true ]]; then
    log "Warning: timestamped migration.log not found (checked migration_log.txt and $CONT_MIGRATION_LOG_ROOT)"
fi

# Stop metrics loop before post-migration collection so the CSV does not
# grow further while we run kubectl calls.
log "Stopping host metrics loop"
stop_metrics_loop

# Post-migration snapshots.
log "Collecting k8s_after.txt"
collect_k8s_snapshot "$RUN_DIR/k8s_after.txt" || true

log "Collecting istio_after.yaml"
collect_istio_snapshot "$RUN_DIR/istio_after.yaml" || true

log "Collecting wg_after.txt (if wg0 exists)"
collect_wg_snapshot "$RUN_DIR/wg_after.txt" || true

# Locate the checkpoint .tar produced by the migration.
log "Locating checkpoint archive"
CHECKPOINT_FILE="$(find_checkpoint_in_log "$RUN_DIR/migration.log" || true)"
if [[ -z "$CHECKPOINT_FILE" || ! -f "$CHECKPOINT_FILE" ]]; then
    CHECKPOINT_FILE="$(find_checkpoint_by_mtime "$CHECKPOINT_ROOT" "$START_TIME_UTC" || true)"
fi
if [[ -n "$CHECKPOINT_FILE" && ! -f "$CHECKPOINT_FILE" ]]; then
    CHECKPOINT_FILE=""
fi

# Checkpoint inventory + per-archive metadata (no copy, no memparse, no gdb).
write_artifact_sizes
if [[ -n "$CHECKPOINT_FILE" ]]; then
    log "Inspecting checkpoint: $CHECKPOINT_FILE"
    inspect_checkpoint "$CHECKPOINT_FILE" || true
else
    log "No checkpoint .tar located (neither in migration.log nor under $CHECKPOINT_ROOT since $START_TIME_UTC)"
    echo "(no checkpoint file located)" > "$CKPT_DIR/checkpoint_path.txt"
fi

# Failure diagnostics only on non-zero migration exit.
if [[ "$MIGRATION_EXIT" -ne 0 ]]; then
    log "Migration failed — collecting failure_diagnostics.txt"
    collect_failure_diagnostics || true
fi

END_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Final metadata + CSV row.
write_metadata
append_results_row

log "Run $RUN_ID complete. exit_code=$MIGRATION_EXIT, run_dir=$RUN_DIR"

exit "$MIGRATION_EXIT"
