#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZER="${SCRIPT_DIR}/../setup/normalize_criu_checkpoint.py"
CHECKPOINT_TAR="${1:-}"

if [[ -z "$CHECKPOINT_TAR" ]]; then
  cat >&2 <<'EOF'
Usage:
  normalize_criu_checkpoint_manual_test.sh /home/ubuntu/nfs/checkpoints/sev-snp-vm/<checkpoint>.tar

The helper writes a normalized copy to /tmp, decodes mountpoints-*.img with crit,
and verifies that /proc/latency_stats is no longer present.
EOF
  exit 2
fi

if [[ ! -f "$CHECKPOINT_TAR" ]]; then
  echo "ERROR: checkpoint tar not found: $CHECKPOINT_TAR" >&2
  exit 1
fi

for tool in python3 crit jq tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool missing: $tool" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"

normalized_tar="${tmp_dir}/$(basename "${CHECKPOINT_TAR%.tar}").normalized.tar"
normalizer_log="${tmp_dir}/checkpoint_normalization.log"
extract_dir="${tmp_dir}/extract"
mkdir -p "$extract_dir"

echo "Dry-run removable entries:"
python3 "$NORMALIZER" --checkpoint-tar "$CHECKPOINT_TAR" --dry-run --strict true

echo
echo "Writing normalized checkpoint:"
python3 "$NORMALIZER" \
  --checkpoint-tar "$CHECKPOINT_TAR" \
  --output "$normalized_tar" \
  --log-file "$normalizer_log" \
  --strict true

mapfile -t mountpoint_members < <(tar -tf "$normalized_tar" | grep -E '(^|/)mountpoints-[^/]*\.img$' || true)
if [[ "${#mountpoint_members[@]}" -eq 0 ]]; then
  echo "ERROR: normalized tar contains no mountpoints-*.img files" >&2
  exit 1
fi

tar -xf "$normalized_tar" -C "$extract_dir" "${mountpoint_members[@]}"

found_latency_stats=false
for member in "${mountpoint_members[@]}"; do
  decoded_json="${tmp_dir}/$(basename "$member").json"
  chmod u+rw "$extract_dir/$member"
  crit decode --pretty -i "$extract_dir/$member" -o "$decoded_json"
  if jq -e '.entries[]? | select(.mountpoint == "/proc/latency_stats")' "$decoded_json" >/dev/null; then
    found_latency_stats=true
    echo "ERROR: /proc/latency_stats still present in $member" >&2
  fi
done

echo
echo "Verification command:"
echo "  tar -xf \"$normalized_tar\" -C \"$extract_dir\" ${mountpoint_members[*]}"
echo "  crit decode --pretty -i \"$extract_dir/${mountpoint_members[0]}\" | jq -e '.entries[]? | select(.mountpoint == \"/proc/latency_stats\")'"
echo "Expected result: jq finds no entry."

if [[ "$found_latency_stats" == true ]]; then
  exit 1
fi

echo
echo "PASS: /proc/latency_stats is absent from normalized mountpoints metadata."
echo "Normalized checkpoint copy: $normalized_tar"
echo "Normalizer log: $normalizer_log"
echo "Temporary verification directory retained: $tmp_dir"
