#!/usr/bin/env bash
# Evaluation wrapper around an existing migration command.
#
# Goals:
#   - Capture environment context (k8s, istio, wg0, host metrics, checkpoint
#     metadata) around a single migration run.
#   - Never modify state; never hide the original migration exit code.
#   - Best-effort diagnostics: each collector failure is logged but never
#     aborts the wrapper, except for the explicit routing-demo reset step.
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
    --workload <routing-demo|mmt-probe|vuln-spring|vuln-redis> \
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
    [--probe-timeout-ms <ms>]    (default: 3000) \
    [--require-routing-demo-probe|--no-require-routing-demo-probe] \
    [--istio-routing-context <kubectl-context>] (default: cluster1) \
    [--expected-initial-subset <subset>]  (default: v1) \
    [--allow-existing-fault[=true|false]] (default: false) \
    [--reset-after-run|--no-reset-after-run] (default: enabled for routing-demo) \
    [--reset-routing-context <context>]    (default: cluster1) \
    [--reset-virtualservice <name>]        (default: routing-demo) \
    [--reset-deployment <name>]            (default: routing-demo) \
    [--reset-service <name>]               (default: routing-demo) \
    [--reset-subset <subset>]              (default: v1) \
    [--reset-source-context <context>]      (default: --source) \
    [--reset-delete-restore-pods|--no-reset-delete-restore-pods] \
    [--reset-timeout-seconds <s>]          (default: 120) \
    [--reset-verify-url <url>]             (default: --probe-url when set) \
    [--falco-trigger-kafka-bootstrap <host:port>] (default: 192.168.200.11:30094) \
    [--falco-trigger-topic <topic>]        (default: mmt-falco-events) \
    [--falco-trigger-timeout-seconds <s>]  (default: 60) \
    [--falco-trigger-nonce <nonce>] \
    [--simulation-attack-type <type>]      (reverse_shell|data_destruction|log_removal) \
    [--simulation-expected-rule <rule>] \
    [--simulation-alert-timeout-seconds <s>] (default: 60) \
    [--simulation-api-url <url>]            (default: http://127.0.0.1:8000/simulate) \
    -- <migration command and its arguments>
USAGE
}

readonly WRAPPER_VERSION="1.2.0"
readonly CUBEMIG_ROOT="/home/ubuntu/teemig/CubeMig"
readonly CONT_MIGRATION_LOG_ROOT="/home/ubuntu/contMigration_logs"
readonly HTTP_PROBE_PARSER="$CUBEMIG_ROOT/scripts/utils/evaluation/parse_http_probe.py"

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
PROBE_TIMEOUT_MS=3000
REQUIRE_ROUTING_DEMO_PROBE=true
EXPECTED_INITIAL_SUBSET="v1"
ISTIO_ROUTING_CONTEXT="${ISTIO_ROUTING_CONTEXT:-cluster1}"
ALLOW_EXISTING_FAULT=false
RESET_AFTER_RUN=true
RESET_ROUTING_CONTEXT=""
RESET_VIRTUALSERVICE="routing-demo"
RESET_DEPLOYMENT="routing-demo"
RESET_SERVICE="routing-demo"
RESET_SUBSET="v1"
RESET_SOURCE_CONTEXT=""
RESET_DELETE_RESTORE_PODS=true
RESET_TIMEOUT_SECONDS=120
RESET_VERIFY_URL=""
FALCO_TRIGGER_KAFKA_BOOTSTRAP="192.168.200.11:30094"
FALCO_TRIGGER_TOPIC="mmt-falco-events"
FALCO_TRIGGER_TIMEOUT_SECONDS=60
FALCO_TRIGGER_NONCE=""
FALCO_TRIGGER_RULE="MMT Attack Candidate From Kafka"
FALCO_TRIGGER_KCAT_IMAGE="docker.io/edenhill/kcat:1.7.1"
FALCO_TRIGGER_PRODUCER_CONTEXT=""
FALCO_TRIGGER_PRODUCER_NAMESPACE=""
SIMULATION_ATTACK_TYPE=""
SIMULATION_EXPECTED_RULE=""
SIMULATION_ALERT_TIMEOUT_SECONDS=60
SIMULATION_API_URL="http://127.0.0.1:8000/simulate"
SIMULATION_TRIGGERED_AT_UTC=""
SIMULATION_HTTP_STATUS=""
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
        --probe-timeout-ms)       PROBE_TIMEOUT_MS="${2:-}";       shift 2 ;;
        --require-routing-demo-probe) REQUIRE_ROUTING_DEMO_PROBE=true; shift ;;
        --no-require-routing-demo-probe) REQUIRE_ROUTING_DEMO_PROBE=false; shift ;;
        --istio-routing-context)  ISTIO_ROUTING_CONTEXT="${2:-}";  shift 2 ;;
        --expected-initial-subset) EXPECTED_INITIAL_SUBSET="${2:-}"; shift 2 ;;
        --allow-existing-fault)   ALLOW_EXISTING_FAULT=true;       shift ;;
        --allow-existing-fault=*) ALLOW_EXISTING_FAULT="${1#*=}"; shift ;;
        --reset-after-run)        RESET_AFTER_RUN=true;            shift ;;
        --no-reset-after-run)     RESET_AFTER_RUN=false;           shift ;;
        --reset-routing-context)  RESET_ROUTING_CONTEXT="${2:-}";  shift 2 ;;
        --reset-virtualservice)   RESET_VIRTUALSERVICE="${2:-}";   shift 2 ;;
        --reset-deployment)       RESET_DEPLOYMENT="${2:-}";       shift 2 ;;
        --reset-service)          RESET_SERVICE="${2:-}";          shift 2 ;;
        --reset-subset)           RESET_SUBSET="${2:-}";           shift 2 ;;
        --reset-source-context)   RESET_SOURCE_CONTEXT="${2:-}";   shift 2 ;;
        --reset-delete-restore-pods) RESET_DELETE_RESTORE_PODS=true; shift ;;
        --no-reset-delete-restore-pods) RESET_DELETE_RESTORE_PODS=false; shift ;;
        --reset-timeout-seconds)  RESET_TIMEOUT_SECONDS="${2:-}";  shift 2 ;;
        --reset-verify-url)       RESET_VERIFY_URL="${2:-}";       shift 2 ;;
        --falco-trigger-kafka-bootstrap) FALCO_TRIGGER_KAFKA_BOOTSTRAP="${2:-}"; shift 2 ;;
        --falco-trigger-topic) FALCO_TRIGGER_TOPIC="${2:-}"; shift 2 ;;
        --falco-trigger-timeout-seconds) FALCO_TRIGGER_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        --falco-trigger-nonce) FALCO_TRIGGER_NONCE="${2:-}"; shift 2 ;;
        --falco-trigger-kcat-image) FALCO_TRIGGER_KCAT_IMAGE="${2:-}"; shift 2 ;;
        --falco-trigger-producer-context) FALCO_TRIGGER_PRODUCER_CONTEXT="${2:-}"; shift 2 ;;
        --falco-trigger-producer-namespace) FALCO_TRIGGER_PRODUCER_NAMESPACE="${2:-}"; shift 2 ;;
        --simulation-attack-type) SIMULATION_ATTACK_TYPE="${2:-}"; shift 2 ;;
        --simulation-expected-rule) SIMULATION_EXPECTED_RULE="${2:-}"; shift 2 ;;
        --simulation-alert-timeout-seconds) SIMULATION_ALERT_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        --simulation-api-url) SIMULATION_API_URL="${2:-}"; shift 2 ;;
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
RESET_ROUTING_CONTEXT="${RESET_ROUTING_CONTEXT:-cluster1}"
RESET_SOURCE_CONTEXT="${RESET_SOURCE_CONTEXT:-$SOURCE_CTX}"
FALCO_TRIGGER_PRODUCER_CONTEXT="${FALCO_TRIGGER_PRODUCER_CONTEXT:-$SOURCE_CTX}"
FALCO_TRIGGER_PRODUCER_NAMESPACE="${FALCO_TRIGGER_PRODUCER_NAMESPACE:-$NAMESPACE}"
if [[ -z "$RESET_VERIFY_URL" && -n "$PROBE_URL" ]]; then
    RESET_VERIFY_URL="$PROBE_URL"
fi

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
    routing-demo|mmt-probe|vuln-spring|vuln-redis) ;;
    *) echo "Invalid --workload value: $WORKLOAD (expected routing-demo|mmt-probe|vuln-spring|vuln-redis)" >&2; exit 2 ;;
esac

case "$TRIGGER" in
    manual|falco|simulate) ;;
    *) echo "Invalid --trigger value: $TRIGGER (expected manual|falco|simulate)" >&2; exit 2 ;;
esac

ROUTING_DEMO_MODE=false
if [[ "$WORKLOAD" == "routing-demo" ]]; then
    ROUTING_DEMO_MODE=true
fi
FALCO_EVAL_MODE=false
if [[ "$TRIGGER" == "falco" && "$WORKLOAD" == "routing-demo" && "$SOURCE_CTX" == "cluster-pnet" && "$DEST_CTX" == "cluster-sev-snp" ]]; then
    FALCO_EVAL_MODE=true
fi
SIMULATION_EVAL_MODE=false
if [[ "$TRIGGER" == "simulate" && ( "$WORKLOAD" == "vuln-spring" || "$WORKLOAD" == "vuln-redis" ) ]]; then
    SIMULATION_EVAL_MODE=true
fi
if [[ "$TRIGGER" == "simulate" && "$SIMULATION_EVAL_MODE" != true ]]; then
    echo "trigger=simulate is only supported for workload=vuln-spring or workload=vuln-redis" >&2
    exit 2
fi
if [[ "$SIMULATION_EVAL_MODE" == true ]]; then
    case "$SIMULATION_ATTACK_TYPE" in
        reverse_shell|data_destruction|log_removal) ;;
        *) echo "Missing or invalid --simulation-attack-type (expected reverse_shell|data_destruction|log_removal)" >&2; exit 2 ;;
    esac
fi

# Run directory layout

DATE_DIR="$(date -u +%F)"
RUN_DIR="$OUT_ROOT/$DATE_DIR/$RUN_ID"
CKPT_DIR="$RUN_DIR/checkpoint"
mkdir -p "$RUN_DIR" "$CKPT_DIR"

START_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_TIME_UTC=""
MIGRATION_COMMAND_START_TIME_UTC=""
MIGRATION_COMMAND_END_TIME_UTC=""
MIGRATION_EXIT=-1
CHECKPOINT_FILE=""
METRICS_PID=""
PROBE_PID=""
HTTP_PROBE_STOP_FILE="$RUN_DIR/.stop_http_probe"
FULL_COMMAND=""
GIT_COMMIT=""
PRE_EXISTING_FAULT_DETECTED=false
MIGRATION_LOG_FOUND=false
HTTP_PROBE_EXISTS=false
HTTP_PROBE_SKIP_REASON=""
HTTP_PROBE_SUMMARY_JSON=""
RESET_STARTED_AT_UTC=""
RESET_FINISHED_AT_UTC=""
RESET_EXIT_CODE=""
RESET_FAILED=false
RESET_HTTP_STATUS=""
RESET_RAN=false
FALCO_EVENT_PUBLISHED_AT_UTC=""
FALCO_ALERT_RECEIVED=false
FALCO_ALERT_RECEIVED_AT_UTC=""
FALCO_ALERT_LATENCY_MS=""

# Helpers

log() {
    printf '[eval %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

is_true() {
    case "${1:-}" in
        true|TRUE|1|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

utc_now_ms() {
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
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

json_bool() {
    if is_true "${1:-}"; then
        printf 'true'
    else
        printf 'false'
    fi
}

json_maybe_str() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then
        printf 'null'
    else
        json_str "$v"
    fi
}

write_metadata() {
    local git_val="${GIT_COMMIT:-}"
    local effective_reset=false
    if [[ "$ROUTING_DEMO_MODE" == true ]] && is_true "$RESET_AFTER_RUN"; then
        effective_reset=true
    fi
    [[ -z "$git_val" ]] && git_val="null" || git_val="$(json_str "$git_val")"
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
        printf '  "routing_demo_mode": %s,\n' "$(json_bool "$ROUTING_DEMO_MODE")"
        printf '  "probe_url": %s,\n'      "$(json_maybe_str "$PROBE_URL")"
        printf '  "probe_interval_ms": %s,\n' "$(json_num "$PROBE_INTERVAL_MS")"
        printf '  "probe_pre_seconds": %s,\n' "$(json_num "$PROBE_PRE_SECONDS")"
        printf '  "probe_post_seconds": %s,\n' "$(json_num "$PROBE_POST_SECONDS")"
        printf '  "probe_timeout_ms": %s,\n' "$(json_num "$PROBE_TIMEOUT_MS")"
        printf '  "start_time_utc": %s,\n' "$(json_str "$START_TIME_UTC")"
        printf '  "end_time_utc": %s,\n'   "$(json_str "$END_TIME_UTC")"
        printf '  "migration_command_start_time_utc": %s,\n' "$(json_maybe_str "$MIGRATION_COMMAND_START_TIME_UTC")"
        printf '  "migration_command_end_time_utc": %s,\n' "$(json_maybe_str "$MIGRATION_COMMAND_END_TIME_UTC")"
        printf '  "exit_code": %s,\n'      "$(json_num "$MIGRATION_EXIT")"
        printf '  "run_dir": %s,\n'         "$(json_str "$RUN_DIR")"
        printf '  "wrapper_version": %s,\n' "$(json_str "$WRAPPER_VERSION")"
        printf '  "git_commit": %s,\n'      "$git_val"
        printf '  "full_command": %s,\n'    "$(json_str "$FULL_COMMAND")"
        printf '  "http_probe_csv": %s,\n'  "$(json_bool "$HTTP_PROBE_EXISTS")"
        printf '  "http_probe_skip_reason": %s,\n' "$(json_maybe_str "$HTTP_PROBE_SKIP_REASON")"
        printf '  "http_probe_summary_json": %s,\n' "$(json_maybe_str "$HTTP_PROBE_SUMMARY_JSON")"
        printf '  "pre_existing_fault_detected": %s,\n' "$(json_bool "$PRE_EXISTING_FAULT_DETECTED")"
        printf '  "migration_log_found": %s,\n' "$(json_bool "$MIGRATION_LOG_FOUND")"
        printf '  "reset_after_run": %s,\n' "$(json_bool "$effective_reset")"
        printf '  "reset_routing_context": %s,\n' "$(json_str "$RESET_ROUTING_CONTEXT")"
        printf '  "reset_source_context": %s,\n' "$(json_str "$RESET_SOURCE_CONTEXT")"
        printf '  "reset_subset": %s,\n' "$(json_str "$RESET_SUBSET")"
        printf '  "reset_started_at_utc": %s,\n' "$(json_maybe_str "$RESET_STARTED_AT_UTC")"
        printf '  "reset_finished_at_utc": %s,\n' "$(json_maybe_str "$RESET_FINISHED_AT_UTC")"
        printf '  "reset_exit_code": %s,\n' "$(json_num "$RESET_EXIT_CODE")"
        printf '  "reset_failed": %s,\n' "$(json_bool "$RESET_FAILED")"
        printf '  "reset_verify_url": %s,\n' "$(json_maybe_str "$RESET_VERIFY_URL")"
        printf '  "reset_http_status": %s,\n' "$(json_maybe_str "$RESET_HTTP_STATUS")"
        printf '  "falco_kafka_topic": %s,\n' "$(json_maybe_str "$FALCO_TRIGGER_TOPIC")"
        printf '  "falco_kafka_bootstrap": %s,\n' "$(json_maybe_str "$FALCO_TRIGGER_KAFKA_BOOTSTRAP")"
        printf '  "falco_event_nonce": %s,\n' "$(json_maybe_str "$FALCO_TRIGGER_NONCE")"
        printf '  "falco_event_published_at_utc": %s,\n' "$(json_maybe_str "$FALCO_EVENT_PUBLISHED_AT_UTC")"
        printf '  "mmt_falco_rule": %s,\n' "$(json_maybe_str "$FALCO_TRIGGER_RULE")"
        printf '  "mmt_falco_alert_received": %s,\n' "$(json_bool "$FALCO_ALERT_RECEIVED")"
        printf '  "mmt_falco_alert_received_at_utc": %s,\n' "$(json_maybe_str "$FALCO_ALERT_RECEIVED_AT_UTC")"
        printf '  "mmt_falco_alert_latency_ms": %s,\n' "$(json_num "$FALCO_ALERT_LATENCY_MS")"
        printf '  "mmt_falco_alert_timeout_seconds": %s,\n' "$(json_num "$FALCO_TRIGGER_TIMEOUT_SECONDS")"
        printf '  "simulation_attack_type": %s,\n' "$(json_maybe_str "$SIMULATION_ATTACK_TYPE")"
        printf '  "simulation_expected_falco_rule": %s,\n' "$(json_maybe_str "$SIMULATION_EXPECTED_RULE")"
        printf '  "simulation_api_url": %s,\n' "$(json_maybe_str "$SIMULATION_API_URL")"
        printf '  "simulation_triggered_at_utc": %s,\n' "$(json_maybe_str "$SIMULATION_TRIGGERED_AT_UTC")"
        printf '  "simulation_alert_timeout_seconds": %s,\n' "$(json_num "$SIMULATION_ALERT_TIMEOUT_SECONDS")"
        printf '  "simulation_http_status": %s\n' "$(json_maybe_str "$SIMULATION_HTTP_STATUS")"
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
    if [[ -n "${PROBE_PID:-}" ]]; then
        touch "$HTTP_PROBE_STOP_FILE" 2>/dev/null || true
        if kill -0 "$PROBE_PID" 2>/dev/null; then
            wait "$PROBE_PID" 2>/dev/null || true
        fi
    fi
    PROBE_PID=""
}

on_exit() {
    stop_http_probe_loop
    stop_metrics_loop
}
trap on_exit EXIT

# Escape a value for CSV (always quoted).
csv_escape() {
    local v="${1:-}"
    v="${v//$'\r'/ }"
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

    if [[ "$ROUTING_DEMO_MODE" != true ]]; then
        return 0
    fi

    : > "$out"
    {
        echo "# pre-run sanity ($(utc_now))"
        echo
        echo "## kubectl --context $RESET_ROUTING_CONTEXT -n $NAMESPACE get virtualservice routing-demo -o yaml"
        vs_yaml=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice routing-demo -o yaml 2>&1) || vs_yaml="(failed)"
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

    if kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice routing-demo \
        -o jsonpath='{.spec.http[0].fault}' 2>/dev/null | grep -q .; then
        fault_present=true
    fi

    if [[ "$fault_present" == true ]]; then
        PRE_EXISTING_FAULT_DETECTED=true
        echo "pre-existing Istio fault detected on routing-demo VirtualService ($RESET_ROUTING_CONTEXT)" >> "$out"
        if ! is_true "$ALLOW_EXISTING_FAULT"; then
            echo "pre-existing Istio fault detected in cluster1 VirtualService; clear fault before evaluation run" >> "$out"
            log "ABORT: pre-existing Istio fault detected in cluster1 VirtualService; clear fault before evaluation run"
            return 1
        fi
        log "Warning: pre-existing Istio fault present (--allow-existing-fault enabled)"
    fi

    current_subset=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice routing-demo \
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
start_http_probe() {
    local out="$RUN_DIR/http_probe.csv"
    local interval_s
    local timeout_s
    interval_s=$(awk -v ms="$PROBE_INTERVAL_MS" 'BEGIN { printf "%.3f", ms/1000 }')
    timeout_s=$(awk -v ms="$PROBE_TIMEOUT_MS" 'BEGIN { printf "%.3f", ms/1000 }')
    rm -f "$HTTP_PROBE_STOP_FILE"
    echo "timestamp_utc,request_id,http_status,latency_ms,counter,cluster,version,body,error" > "$out"
    HTTP_PROBE_EXISTS=true
    (
        local req_id=0
        local ts t0 t1 resp_file err_file meta http_status time_total latency_ms body err counter cluster version
        while [[ ! -f "$HTTP_PROBE_STOP_FILE" ]]; do
            req_id=$((req_id + 1))
            ts="$(utc_now_ms)"
            t0=$(date +%s%3N 2>/dev/null || date +%s)
            resp_file=$(mktemp)
            err_file="${resp_file}.err"
            set +e
            meta=$(curl -sS --connect-timeout 1 --max-time "$timeout_s" \
                -w "%{http_code},%{time_total}" \
                -o "$resp_file" "$PROBE_URL" 2>"$err_file")
            curl_exit=$?
            set -e
            t1=$(date +%s%3N 2>/dev/null || date +%s)
            if [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]]; then
                latency_ms=$((t1 - t0))
            else
                latency_ms=""
            fi
            body=$(cat "$resp_file" 2>/dev/null || true)
            err=$(cat "$err_file" 2>/dev/null || true)
            if [[ "$curl_exit" -eq 0 ]]; then
                http_status="${meta%%,*}"
                time_total="${meta#*,}"
                if [[ "$time_total" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    latency_ms=$(awk -v s="$time_total" 'BEGIN { printf "%.0f", s * 1000 }')
                fi
            else
                http_status="000"
            fi
            rm -f "$resp_file" "$err_file"
            counter=""; cluster=""; version=""
            if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
                counter=$(printf '%s' "$body" | jq -r '.counter // empty' 2>/dev/null || true)
                cluster=$(printf '%s' "$body" | jq -r '.cluster // .cluster_name // .pod_cluster // empty' 2>/dev/null || true)
                version=$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null || true)
            fi
            {
                csv_escape "$ts"; printf ','
                csv_escape "$req_id"; printf ','
                csv_escape "$http_status"; printf ','
                csv_escape "$latency_ms"; printf ','
                csv_escape "$counter"; printf ','
                csv_escape "$cluster"; printf ','
                csv_escape "$version"; printf ','
                csv_escape "$body"; printf ','
                csv_escape "$err"
                printf '\n'
            } >> "$out" 2>/dev/null || break
            local slept="0.000"
            while [[ ! -f "$HTTP_PROBE_STOP_FILE" ]] && awk -v a="$slept" -v b="$interval_s" 'BEGIN { exit !(a < b) }'; do
                sleep 0.1
                slept=$(awk -v s="$slept" 'BEGIN { printf "%.3f", s + 0.1 }')
            done
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
        echo "## kubectl --context $ISTIO_ROUTING_CONTEXT -n $NAMESPACE get virtualservice,destinationrule,gateway -o yaml"
        kubectl --context "$ISTIO_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice,destinationrule,gateway -o yaml 2>&1 \
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
            if command -v wg >/dev/null 2>&1; then
                if timeout 5s wg show 2>&1; then
                    true
                elif command -v sudo >/dev/null 2>&1; then
                    echo "(plain wg show failed; retrying with sudo -n)"
                    timeout 5s sudo -n wg show 2>&1 \
                        || echo "(failed: wg show requires privileges or sudo without password is unavailable)"
                else
                    echo "(failed: wg show requires privileges and sudo is unavailable)"
                fi
            else
                echo "(failed: wireguard-tools wg command is not installed)"
            fi
            echo
            echo "## ip -s link show wg0"
            timeout 5s ip -s link show wg0 2>&1 || echo "(failed)"
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

falco_log() {
    printf '%s\n' "$*" >> "$RUN_DIR/falco_trigger.txt"
}

simulation_log() {
    printf '%s\n' "$*" >> "$RUN_DIR/simulation_trigger.txt"
}

write_falco_event_json() {
    local out="$RUN_DIR/falco_event.json"
    FALCO_EVENT_PUBLISHED_AT_UTC="$(utc_now_ms)"
    {
        printf '{'
        printf '"event_type":%s,' "$(json_str "mmt_attack_candidate")"
        printf '"source_cluster":%s,' "$(json_str "$SOURCE_CTX")"
        printf '"workload":%s,' "$(json_str "$WORKLOAD")"
        printf '"namespace":%s,' "$(json_str "$NAMESPACE")"
        printf '"pod":%s,' "$(json_str "$POD")"
        printf '"pod_name":%s,' "$(json_str "$POD")"
        printf '"reason":%s,' "$(json_str "evaluation-falco-trigger")"
        printf '"run_id":%s,' "$(json_str "$RUN_ID")"
        printf '"nonce":%s,' "$(json_str "$FALCO_TRIGGER_NONCE")"
        printf '"emitted_at_utc":%s' "$(json_str "$FALCO_EVENT_PUBLISHED_AT_UTC")"
        printf '}\n'
    } > "$out"
}

update_falco_trigger_from_file() {
    local f="$RUN_DIR/falco_trigger.json"
    [[ -f "$f" ]] || return 1
    FALCO_ALERT_RECEIVED=true
    if command -v jq >/dev/null 2>&1; then
        FALCO_ALERT_RECEIVED_AT_UTC="$(jq -r '.alert_received_at_utc // ""' "$f" 2>/dev/null || true)"
    else
        FALCO_ALERT_RECEIVED_AT_UTC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("alert_received_at_utc",""))' "$f" 2>/dev/null || true)"
    fi
    if [[ -n "$FALCO_EVENT_PUBLISHED_AT_UTC" && -n "$FALCO_ALERT_RECEIVED_AT_UTC" ]]; then
        FALCO_ALERT_LATENCY_MS="$(python3 -c 'import datetime,sys
def parse(v):
    return datetime.datetime.fromisoformat(v.replace("Z","+00:00"))
print(int((parse(sys.argv[2]) - parse(sys.argv[1])).total_seconds() * 1000))' "$FALCO_EVENT_PUBLISHED_AT_UTC" "$FALCO_ALERT_RECEIVED_AT_UTC" 2>/dev/null || true)"
    fi
}

trigger_simulation_attack() {
    local out="$RUN_DIR/simulation_trigger.txt"
    local json_out="$RUN_DIR/simulation_trigger.json"
    local body_file="$RUN_DIR/.simulation_response_body"
    local err_file="$RUN_DIR/.simulation_curl_stderr"
    local request_json=""
    local response_body=""
    local error_text=""
    local rc=0

    if [[ "$SIMULATION_EVAL_MODE" != true ]]; then
        return 0
    fi

    : > "$out"
    SIMULATION_TRIGGERED_AT_UTC="$(utc_now_ms)"
    FALCO_EVENT_PUBLISHED_AT_UTC="$SIMULATION_TRIGGERED_AT_UTC"
    request_json="$(printf '{"appName":%s,"attackType":%s,"cluster":%s,"namespace":%s}' \
        "$(json_str "$WORKLOAD")" \
        "$(json_str "$SIMULATION_ATTACK_TYPE")" \
        "$(json_str "$SOURCE_CTX")" \
        "$(json_str "$NAMESPACE")")"

    simulation_log "# Vulnerability simulation trigger ($(utc_now))"
    simulation_log "api_url=$SIMULATION_API_URL"
    simulation_log "attack_type=$SIMULATION_ATTACK_TYPE"
    simulation_log "expected_rule=$SIMULATION_EXPECTED_RULE"
    simulation_log "source_context=$SOURCE_CTX"
    simulation_log "namespace=$NAMESPACE"
    simulation_log "pod=$POD"
    simulation_log "request=$request_json"
    simulation_log

    set +e
    SIMULATION_HTTP_STATUS="$(curl -sS -X POST \
        -H "Content-Type: application/json" \
        --connect-timeout 2 \
        --max-time 30 \
        -d "$request_json" \
        -w "%{http_code}" \
        -o "$body_file" \
        "$SIMULATION_API_URL" 2>"$err_file")"
    rc=$?
    set -e

    response_body="$(cat "$body_file" 2>/dev/null || true)"
    error_text="$(cat "$err_file" 2>/dev/null || true)"
    rm -f "$body_file" "$err_file"

    {
        printf '{\n'
        printf '  "api_url": %s,\n' "$(json_str "$SIMULATION_API_URL")"
        printf '  "attack_type": %s,\n' "$(json_str "$SIMULATION_ATTACK_TYPE")"
        printf '  "expected_falco_rule": %s,\n' "$(json_maybe_str "$SIMULATION_EXPECTED_RULE")"
        printf '  "source_cluster": %s,\n' "$(json_str "$SOURCE_CTX")"
        printf '  "namespace": %s,\n' "$(json_str "$NAMESPACE")"
        printf '  "pod": %s,\n' "$(json_str "$POD")"
        printf '  "triggered_at_utc": %s,\n' "$(json_str "$SIMULATION_TRIGGERED_AT_UTC")"
        printf '  "http_status": %s,\n' "$(json_maybe_str "$SIMULATION_HTTP_STATUS")"
        printf '  "request": %s,\n' "$(json_str "$request_json")"
        printf '  "response_body": %s,\n' "$(json_str "$response_body")"
        printf '  "error": %s\n' "$(json_maybe_str "$error_text")"
        printf '}\n'
    } > "$json_out"

    simulation_log "http_status=${SIMULATION_HTTP_STATUS:-unknown}"
    if [[ -n "$response_body" ]]; then
        simulation_log "response=$response_body"
    fi
    if [[ -n "$error_text" ]]; then
        simulation_log "curl_error=$error_text"
    fi

    if [[ "$rc" -ne 0 ]]; then
        simulation_log "Simulation trigger failed with curl rc=$rc"
        return "$rc"
    fi
    if [[ ! "$SIMULATION_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
        simulation_log "Simulation trigger returned non-2xx HTTP status: ${SIMULATION_HTTP_STATUS:-unknown}"
        return 1
    fi

    simulation_log "Simulation attack requested at $SIMULATION_TRIGGERED_AT_UTC"
    return 0
}

publish_falco_trigger_event() {
    local out="$RUN_DIR/falco_trigger.txt"
    local event_file="$RUN_DIR/falco_event.json"
    local event_json=""
    local producer_pod=""
    local safe_run=""
    local rc=0

    if [[ "$FALCO_EVAL_MODE" != true ]]; then
        return 0
    fi

    : > "$out"
    if [[ -z "$FALCO_TRIGGER_NONCE" ]]; then
        FALCO_TRIGGER_NONCE="${RUN_ID}-$(date +%s%N)"
        falco_log "Warning: no --falco-trigger-nonce supplied; generated local nonce. Backend correlation requires this same nonce to be registered."
    fi

    write_falco_event_json
    event_json="$(tr -d '\n' < "$event_file")"
    safe_run="$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-24)"
    producer_pod="eval-falco-kcat-${safe_run}-$(date +%s)"

    falco_log "# Falco/MMT Kafka trigger ($(utc_now))"
    falco_log "rule=$FALCO_TRIGGER_RULE"
    falco_log "bootstrap=$FALCO_TRIGGER_KAFKA_BOOTSTRAP"
    falco_log "topic=$FALCO_TRIGGER_TOPIC"
    falco_log "producer_context=$FALCO_TRIGGER_PRODUCER_CONTEXT"
    falco_log "producer_namespace=$FALCO_TRIGGER_PRODUCER_NAMESPACE"
    falco_log "producer_pod=$producer_pod"
    falco_log "nonce=$FALCO_TRIGGER_NONCE"
    falco_log
    falco_log "event=$event_json"
    falco_log

    {
        echo "## kubectl --context $FALCO_TRIGGER_PRODUCER_CONTEXT -n $FALCO_TRIGGER_PRODUCER_NAMESPACE run $producer_pod --image=$FALCO_TRIGGER_KCAT_IMAGE ..."
        set +e
        kubectl --context "$FALCO_TRIGGER_PRODUCER_CONTEXT" -n "$FALCO_TRIGGER_PRODUCER_NAMESPACE" run "$producer_pod" \
            --image="$FALCO_TRIGGER_KCAT_IMAGE" \
            --restart=Never \
            --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
            --env="EVENT=$event_json" \
            --env="BOOTSTRAP=$FALCO_TRIGGER_KAFKA_BOOTSTRAP" \
            --env="TOPIC=$FALCO_TRIGGER_TOPIC" \
            --command -- sh -lc 'printf "%s\n" "$EVENT" | kcat -P -b "$BOOTSTRAP" -t "$TOPIC"'
        rc=$?
        set -e
        echo
    } >> "$out" 2>&1
    if [[ "$rc" -ne 0 ]]; then
        falco_log "Kafka producer pod creation failed with rc=$rc"
        return "$rc"
    fi

    {
        echo "## wait for producer pod to complete"
        set +e
        kubectl --context "$FALCO_TRIGGER_PRODUCER_CONTEXT" -n "$FALCO_TRIGGER_PRODUCER_NAMESPACE" wait \
            --for=jsonpath='{.status.phase}'=Succeeded "pod/$producer_pod" --timeout=90s
        rc=$?
        echo
        echo "## producer pod logs"
        kubectl --context "$FALCO_TRIGGER_PRODUCER_CONTEXT" -n "$FALCO_TRIGGER_PRODUCER_NAMESPACE" logs "$producer_pod" || true
        echo
        if [[ "$rc" -ne 0 ]]; then
            echo "## producer pod describe"
            kubectl --context "$FALCO_TRIGGER_PRODUCER_CONTEXT" -n "$FALCO_TRIGGER_PRODUCER_NAMESPACE" describe pod "$producer_pod" || true
        fi
        echo
        echo "## cleanup producer pod"
        kubectl --context "$FALCO_TRIGGER_PRODUCER_CONTEXT" -n "$FALCO_TRIGGER_PRODUCER_NAMESPACE" delete pod "$producer_pod" --wait=false --ignore-not-found=true || true
        set -e
    } >> "$out" 2>&1
    if [[ "$rc" -ne 0 ]]; then
        falco_log "Kafka producer pod did not complete successfully with rc=$rc"
        return "$rc"
    fi
    falco_log "Kafka event published at $FALCO_EVENT_PUBLISHED_AT_UTC"
    return 0
}

wait_for_falco_trigger_alert() {
    local timeout="${FALCO_TRIGGER_TIMEOUT_SECONDS:-60}"
    local elapsed=0
    if [[ "$SIMULATION_EVAL_MODE" == true ]]; then
        timeout="${SIMULATION_ALERT_TIMEOUT_SECONDS:-60}"
    fi
    if [[ "$FALCO_EVAL_MODE" != true && "$SIMULATION_EVAL_MODE" != true ]]; then
        return 0
    fi
    falco_log
    falco_log "Waiting up to ${timeout}s for backend /alert correlation file: $RUN_DIR/falco_trigger.json"
    while (( elapsed < timeout )); do
        if [[ -f "$RUN_DIR/falco_trigger.json" ]]; then
            update_falco_trigger_from_file || true
            falco_log "Matched MMT/Falco alert at ${FALCO_ALERT_RECEIVED_AT_UTC:-unknown}; latency_ms=${FALCO_ALERT_LATENCY_MS:-unknown}"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    falco_log "Timed out waiting for MMT/Falco alert after ${timeout}s"
    return 1
}

reset_log() {
    printf '%s\n' "$*" >> "$RUN_DIR/reset_after.txt"
}

run_reset_cmd() {
    local rc=0
    {
        printf '##'
        printf ' %q' "$@"
        printf '\n'
        "$@" || rc=$?
        printf '\n'
    } >> "$RUN_DIR/reset_after.txt" 2>&1
    return "$rc"
}

reset_routing_demo_environment() {
    local out="$RUN_DIR/reset_after.txt"
    local reset_failed=false
    local force=false
    local endpoints=""
    local vs_json=""
    local has_fault=""
    local current_subset=""
    local weight=""
    local status=""
    local verify_tmp=""

    RESET_RAN=true
    RESET_STARTED_AT_UTC="$(utc_now)"
    : > "$out"
    reset_log "# routing-demo reset ($(utc_now))"
    reset_log "reset routing context: $RESET_ROUTING_CONTEXT"
    reset_log "reset source context: $RESET_SOURCE_CONTEXT"
    reset_log "destination context: $DEST_CTX"
    reset_log

    if is_true "${EVAL_RESET_FORCE:-false}"; then
        force=true
        reset_log "EVAL_RESET_FORCE=true; reset will patch VirtualService even if source readiness checks fail"
    fi

    reset_log "## kubectl --context $RESET_SOURCE_CONTEXT -n $NAMESPACE get deploy $RESET_DEPLOYMENT"
    if ! kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" get deploy "$RESET_DEPLOYMENT" >> "$out" 2>&1; then
        reset_log "reset source deployment missing; cannot safely reset VirtualService to v1"
        reset_failed=true
    else
        run_reset_cmd kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" scale deploy "$RESET_DEPLOYMENT" --replicas=1 \
            || reset_failed=true
        run_reset_cmd kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" rollout status deploy "$RESET_DEPLOYMENT" --timeout="${RESET_TIMEOUT_SECONDS}s" \
            || reset_failed=true
        run_reset_cmd kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" get pods -l "app=$RESET_DEPLOYMENT" -o wide \
            || reset_failed=true
        run_reset_cmd kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" get endpoints "$RESET_SERVICE" -o wide \
            || reset_failed=true
    fi

    reset_log "## kubectl --context $RESET_SOURCE_CONTEXT -n $NAMESPACE get endpoints $RESET_SERVICE -o jsonpath={.subsets[*].addresses[*].ip}"
    endpoints=$(kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" get endpoints "$RESET_SERVICE" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>>"$out" || true)
    printf '%s\n\n' "$endpoints" >> "$out"
    if [[ -z "$endpoints" ]]; then
        reset_log "reset source service has no ready endpoints"
        reset_failed=true
    fi

    reset_log "## kubectl --context $RESET_ROUTING_CONTEXT -n $NAMESPACE get virtualservice $RESET_VIRTUALSERVICE -o yaml"
    if ! kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" -o yaml >> "$out" 2>&1; then
        reset_log "routing-demo VirtualService not found in reset routing context"
        reset_failed=true
    else
        if [[ "$reset_failed" == true && "$force" != true ]]; then
            reset_log "source readiness checks failed; skipping VirtualService patch because EVAL_RESET_FORCE is not true"
        else
            vs_json=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" -o json 2>>"$out" || true)
            if command -v jq >/dev/null 2>&1 && [[ -n "$vs_json" ]]; then
                has_fault=$(printf '%s' "$vs_json" | jq -r '(.spec.http[0].fault? != null)' 2>/dev/null || true)
                current_subset=$(printf '%s' "$vs_json" | jq -r '.spec.http[0].route[0].destination.subset // ""' 2>/dev/null || true)
                weight=$(printf '%s' "$vs_json" | jq -r '.spec.http[0].route[0].weight // ""' 2>/dev/null || true)
            else
                has_fault=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" \
                    -o jsonpath='{.spec.http[0].fault}' 2>/dev/null | grep -q . && printf 'true' || printf 'false')
                current_subset=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" \
                    -o jsonpath='{.spec.http[0].route[0].destination.subset}' 2>/dev/null || true)
                weight=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" \
                    -o jsonpath='{.spec.http[0].route[0].weight}' 2>/dev/null || true)
            fi
            reset_log "current subset before reset: ${current_subset:-<empty>}"

            if [[ "$has_fault" == true ]]; then
                run_reset_cmd kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" patch virtualservice "$RESET_VIRTUALSERVICE" --type=json \
                    -p='[{"op":"remove","path":"/spec/http/0/fault"}]' || reset_failed=true
            fi

            run_reset_cmd kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" patch virtualservice "$RESET_VIRTUALSERVICE" --type=json \
                -p="[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/destination/subset\",\"value\":\"$RESET_SUBSET\"}]" \
                || reset_failed=true

            if [[ -n "$weight" ]]; then
                run_reset_cmd kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" patch virtualservice "$RESET_VIRTUALSERVICE" --type=json \
                    -p='[{"op":"replace","path":"/spec/http/0/route/0/weight","value":100}]' \
                    || reset_failed=true
            fi
        fi
    fi

    if is_true "$RESET_DELETE_RESTORE_PODS"; then
        reset_log "## delete destination routing-demo restore pods"
        while IFS= read -r pod_name; do
            case "$pod_name" in
                pod/routing-demo-restore-*)
                    run_reset_cmd kubectl --context "$DEST_CTX" -n "$NAMESPACE" delete "$pod_name" --wait=false \
                        || reset_failed=true
                    ;;
            esac
        done < <(kubectl --context "$DEST_CTX" -n "$NAMESPACE" get pods -o name 2>>"$out" || true)
        reset_log
    fi

    kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" -o yaml \
        > "$RUN_DIR/reset_after_istio.yaml" 2>&1 || reset_failed=true
    kubectl --context "$RESET_SOURCE_CONTEXT" -n "$NAMESPACE" get pods,svc,endpoints,endpointslices -o wide \
        > "$RUN_DIR/reset_after_k8s.txt" 2>&1 || reset_failed=true

    vs_json=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" -o json 2>>"$out" || true)
    if command -v jq >/dev/null 2>&1 && [[ -n "$vs_json" ]]; then
        has_fault=$(printf '%s' "$vs_json" | jq -r '(.spec.http[0].fault? != null)' 2>/dev/null || true)
        current_subset=$(printf '%s' "$vs_json" | jq -r '.spec.http[0].route[0].destination.subset // ""' 2>/dev/null || true)
    else
        has_fault=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" \
            -o jsonpath='{.spec.http[0].fault}' 2>/dev/null | grep -q . && printf 'true' || printf 'false')
        current_subset=$(kubectl --context "$RESET_ROUTING_CONTEXT" -n "$NAMESPACE" get virtualservice "$RESET_VIRTUALSERVICE" \
            -o jsonpath='{.spec.http[0].route[0].destination.subset}' 2>/dev/null || true)
    fi
    if [[ "$has_fault" == true ]]; then
        reset_log "reset verification failed: fault block still present"
        reset_failed=true
    fi
    if [[ "$current_subset" != "$RESET_SUBSET" ]]; then
        reset_log "reset verification failed: subset=${current_subset:-<empty>} expected=$RESET_SUBSET"
        reset_failed=true
    fi

    if [[ -n "$RESET_VERIFY_URL" ]]; then
        verify_tmp=$(mktemp)
        reset_log "## curl -sS -i $RESET_VERIFY_URL"
        status=$(curl -sS -i --connect-timeout 1 --max-time 10 -o "$verify_tmp" -w '%{http_code}' "$RESET_VERIFY_URL" 2>>"$out" || printf '000')
        cat "$verify_tmp" >> "$out" 2>/dev/null || true
        rm -f "$verify_tmp"
        RESET_HTTP_STATUS="$status"
        reset_log
        reset_log "reset HTTP status: $status"
        if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
            reset_failed=true
        fi
    fi

    RESET_FINISHED_AT_UTC="$(utc_now)"
    if [[ "$reset_failed" == true ]]; then
        RESET_FAILED=true
        RESET_EXIT_CODE=1
        reset_log "reset_failed=true"
        return 1
    fi
    RESET_FAILED=false
    RESET_EXIT_CODE=0
    reset_log "reset_failed=false"
    return 0
}

parse_http_probe_summary() {
    if [[ "$HTTP_PROBE_EXISTS" != true || ! -f "$RUN_DIR/http_probe.csv" ]]; then
        return 0
    fi
    if [[ ! -f "$HTTP_PROBE_PARSER" ]]; then
        log "Warning: HTTP probe parser not found: $HTTP_PROBE_PARSER"
        return 0
    fi
    local out="$RUN_DIR/http_probe_summary.json"
    if python3 "$HTTP_PROBE_PARSER" --probe-csv "$RUN_DIR/http_probe.csv" --metadata-json "$RUN_DIR/metadata.json" --out-json "$out"; then
        HTTP_PROBE_SUMMARY_JSON="$out"
    else
        log "Warning: failed to parse HTTP probe summary"
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
    local reset_flag="false"
    local expected_header="run_id,source,dest,namespace,workload,pod,load_rps,concurrency,trigger,start_time_utc,end_time_utc,exit_code,run_dir,checkpoint_file,http_probe_csv,pre_existing_fault_detected,migration_log_found,reset_after_run,reset_failed,reset_exit_code"
    [[ "$HTTP_PROBE_EXISTS" == true || "$HTTP_PROBE_EXISTS" == "true" ]] && probe_flag="true"
    [[ "$PRE_EXISTING_FAULT_DETECTED" == true || "$PRE_EXISTING_FAULT_DETECTED" == "true" ]] && fault_flag="true"
    [[ "$MIGRATION_LOG_FOUND" == true || "$MIGRATION_LOG_FOUND" == "true" ]] && log_flag="true"
    [[ "$RESET_RAN" == true || "$RESET_RAN" == "true" ]] && reset_flag="true"
    if [[ -f "$csv" ]]; then
        local current_header
        current_header="$(head -n 1 "$csv" 2>/dev/null || true)"
        if [[ "$current_header" != "$expected_header" ]]; then
            mv "$csv" "${csv}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        fi
    fi
    if [[ ! -f "$csv" ]]; then
        echo "$expected_header" > "$csv"
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
        csv_field "$log_flag";       printf ','
        csv_field "$reset_flag";     printf ','
        csv_field "$RESET_FAILED";   printf ','
        csv_field "$RESET_EXIT_CODE"
        printf '\n'
    } >> "$csv" || true
}

# Main flow

if command -v git >/dev/null 2>&1; then
    GIT_COMMIT=$(git -C "$CUBEMIG_ROOT" rev-parse HEAD 2>/dev/null || true)
fi

# Initial metadata (exit_code is still -1 = running).
if [[ "$ROUTING_DEMO_MODE" == true ]]; then
    if [[ -n "$PROBE_URL" ]]; then
        HTTP_PROBE_SKIP_REASON=""
    elif is_true "$REQUIRE_ROUTING_DEMO_PROBE"; then
        HTTP_PROBE_SKIP_REASON="probe_url_missing"
    else
        HTTP_PROBE_SKIP_REASON="probe_url_missing"
    fi
else
    HTTP_PROBE_SKIP_REASON="workload_not_routing_demo"
fi
write_metadata

log "Run $RUN_ID starting (source=$SOURCE_CTX, dest=$DEST_CTX, workload=$WORKLOAD, trigger=$TRIGGER)"
log "Run directory: $RUN_DIR"
log "Using Istio routing context: $ISTIO_ROUTING_CONTEXT"
if [[ "$ROUTING_DEMO_MODE" == true ]]; then
    log "Routing-demo mode enabled; reset routing context: $RESET_ROUTING_CONTEXT"
fi

# Pre-migration snapshots.
log "Collecting k8s_before.txt"
collect_k8s_snapshot "$RUN_DIR/k8s_before.txt" || true

log "Collecting istio_before.yaml (best-effort against $ISTIO_ROUTING_CONTEXT)"
collect_istio_snapshot "$RUN_DIR/istio_before.yaml" || true

log "Collecting wg_before.txt (if wg0 exists)"
collect_wg_snapshot "$RUN_DIR/wg_before.txt" || true

if [[ "$ROUTING_DEMO_MODE" == true && -z "$PROBE_URL" ]] && is_true "$REQUIRE_ROUTING_DEMO_PROBE"; then
    MIGRATION_EXIT=2
    END_TIME_UTC="$(utc_now)"
    write_metadata
    append_results_row
    log "ABORT: routing-demo evaluation requires --probe-url unless --no-require-routing-demo-probe is set"
    echo "routing-demo evaluation requires --probe-url unless --no-require-routing-demo-probe is set" >&2
    exit "$MIGRATION_EXIT"
fi

if [[ "$ROUTING_DEMO_MODE" == true ]]; then
    log "Running routing-demo pre-migration sanity checks"
fi
if ! run_pre_migration_sanity; then
    MIGRATION_EXIT=2
    END_TIME_UTC="$(utc_now)"
    write_metadata
    append_results_row
    log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): pre-existing Istio fault"
    exit "$MIGRATION_EXIT"
fi

# Host metrics loop runs across the entire migration window.
log "Starting host metrics loop"
start_host_metrics_loop "$RUN_DIR/host_metrics.csv"

if [[ "$ROUTING_DEMO_MODE" == true && -n "$PROBE_URL" ]]; then
    log "Starting HTTP probe loop (url=$PROBE_URL, interval=${PROBE_INTERVAL_MS}ms)"
    start_http_probe
    if [[ "$PROBE_PRE_SECONDS" =~ ^[0-9]+$ ]] && (( PROBE_PRE_SECONDS > 0 )); then
        log "HTTP probe pre-migration baseline (${PROBE_PRE_SECONDS}s)"
        sleep "$PROBE_PRE_SECONDS"
    fi
fi

if [[ "$FALCO_EVAL_MODE" == true ]]; then
    log "Publishing MMT/Falco Kafka trigger event (topic=$FALCO_TRIGGER_TOPIC, bootstrap=$FALCO_TRIGGER_KAFKA_BOOTSTRAP)"
    if ! publish_falco_trigger_event; then
        MIGRATION_EXIT=2
        END_TIME_UTC="$(utc_now)"
        write_metadata
        append_results_row
        log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): failed to publish MMT/Falco Kafka event"
        exit "$MIGRATION_EXIT"
    fi
    write_metadata
    log "Waiting for correlated MMT/Falco backend alert"
    if ! wait_for_falco_trigger_alert; then
        MIGRATION_EXIT=2
        END_TIME_UTC="$(utc_now)"
        write_metadata
        append_results_row
        log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): MMT/Falco alert was not observed"
        exit "$MIGRATION_EXIT"
    fi
    write_metadata
fi

if [[ "$SIMULATION_EVAL_MODE" == true ]]; then
    log "Triggering vulnerability simulation attack (attack_type=$SIMULATION_ATTACK_TYPE)"
    if ! trigger_simulation_attack; then
        MIGRATION_EXIT=2
        END_TIME_UTC="$(utc_now)"
        write_metadata
        append_results_row
        log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): failed to trigger vulnerability simulation"
        exit "$MIGRATION_EXIT"
    fi
    write_metadata
    log "Waiting for correlated simulated Falco alert"
    if ! wait_for_falco_trigger_alert; then
        MIGRATION_EXIT=2
        END_TIME_UTC="$(utc_now)"
        write_metadata
        append_results_row
        log "Run $RUN_ID aborted (exit $MIGRATION_EXIT): simulated Falco alert was not observed"
        exit "$MIGRATION_EXIT"
    fi
    write_metadata
fi

inject_migration_log_dir
FULL_COMMAND="${MIGRATION_CMD[*]}"

# Run migration: stdout/stderr -> migration.stdout.log; timestamped log via --log-dir.
log "Running migration: ${MIGRATION_CMD[*]}"
MIGRATION_COMMAND_START_TIME_UTC="$(utc_now)"
set +e
set +o pipefail
"${MIGRATION_CMD[@]}" 2>&1 | tee "$RUN_DIR/migration.stdout.log"
MIGRATION_EXIT="${PIPESTATUS[0]}"
set -e
set -o pipefail
MIGRATION_COMMAND_END_TIME_UTC="$(utc_now)"
log "Migration exited with code $MIGRATION_EXIT"

if [[ "$HTTP_PROBE_EXISTS" == true && "$PROBE_POST_SECONDS" =~ ^[0-9]+$ ]] && (( PROBE_POST_SECONDS > 0 )); then
    log "HTTP probe post-migration (${PROBE_POST_SECONDS}s)"
    sleep "$PROBE_POST_SECONDS"
fi
stop_http_probe_loop
write_metadata
parse_http_probe_summary

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

if [[ "$ROUTING_DEMO_MODE" == true ]] && is_true "$RESET_AFTER_RUN"; then
    log "Running routing-demo reset after evidence collection"
    reset_routing_demo_environment || true
fi

END_TIME_UTC="$(utc_now)"

# Final metadata + CSV row.
write_metadata
append_results_row

log "Run $RUN_ID complete. exit_code=$MIGRATION_EXIT, run_dir=$RUN_DIR"

FINAL_EXIT="$MIGRATION_EXIT"
if is_true "${EVAL_RESET_STRICT:-false}" && is_true "$RESET_FAILED"; then
    FINAL_EXIT="${RESET_EXIT_CODE:-1}"
fi

exit "$FINAL_EXIT"
