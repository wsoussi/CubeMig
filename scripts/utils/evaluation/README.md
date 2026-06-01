# Evaluation wrapper for CubeMig / teeMig migrations

`run_eval_migration.sh` is a thin, **non-destructive** wrapper around an
existing migration command (typically `scripts/migration/single-migration.sh`).
It is meant for the bachelor thesis evaluation runs ("Live Migration of
Containers to TEE-based Virtual Machines for Enhanced Confidentiality") and
captures the per-run context that would otherwise be lost: pod/Service/Istio
state on both clusters, host CPU/memory/network metrics, WireGuard counters
on the migration host, and metadata about the produced checkpoint archive.

## Why a wrapper instead of patching the migration script?

* The migration script must keep working unchanged for production-style runs;
  the wrapper only adds collection around it. The existing migration script
  is invoked exactly as before, after the `--` separator.
* All collectors are **best-effort**: any individual `kubectl`, `wg`, `find`,
  `journalctl`, etc. failure is logged into the run directory but never
  changes the migration's exit code. The wrapper returns the migration's
  own exit code.
* The wrapper never copies checkpoint archives, kubeconfigs, `.env` files,
  WireGuard private keys or service-account tokens. It only stores the
  checkpoint's path, size, sha256 and tar listing plus optional
  `checkpointctl show` / `checkpointctl inspect` output (process tree
  metadata only — see "Secrets in checkpoints" below).

## Two reference scenarios

### Reference run (local control plane to local TEE)

`cluster1 -> cluster-sev-snp` uses the standard public network registry and
does not involve WireGuard.

```bash
scripts/utils/evaluation/run_eval_migration.sh \
  --run-id 010_cluster1_to_sev_1rps \
  --source cluster1 \
  --dest cluster-sev-snp \
  --namespace istio-enabled \
  --workload routing-demo \
  --pod routing-demo-7c8f6c5b6d-abcde \
  --load-rps 1 \
  --concurrency 1 \
  --trigger manual \
  --probe-url http://10.0.0.18:32366/whoami \
  --probe-interval-ms 1000 \
  --probe-pre-seconds 30 \
  --probe-post-seconds 60 \
  --reset-after-run \
  --reset-routing-context cluster1 \
  --reset-source-context cluster1 \
  --reset-subset v1 \
  -- \
  ./scripts/migration/single-migration.sh routing-demo-7c8f6c5b6d-abcde \
    --source-cluster cluster1 \
    --dest-cluster cluster-sev-snp \
    --namespace istio-enabled \
    --istio-routing-context cluster1
```

### Main scenario (remote PNET to TEE over WireGuard)

`cluster-pnet -> cluster-sev-snp` always tunnels through WireGuard (`wg0`).
Any run with `--source cluster-pnet` (or `--dest cluster-pnet`) will pick up
`wg0` and write `wg_before.txt` / `wg_after.txt` automatically. The
per-second `host_metrics.csv` also records `wg0_rx_bytes` / `wg0_tx_bytes`,
so the WireGuard transfer cost of the migration window is visible.
`wg show` may require elevated privileges on this host; the wrapper first tries
plain `wg show`, then `sudo -n wg show`, and always keeps the `ip -s link show
wg0` counters as best-effort fallback.

```bash
scripts/utils/evaluation/run_eval_migration.sh \
  --run-id 020_pnet_to_sev_1rps \
  --source cluster-pnet \
  --dest cluster-sev-snp \
  --namespace istio-enabled \
  --workload routing-demo \
  --pod routing-demo-7c8f6c5b6d-abcde \
  --load-rps 1 \
  --concurrency 1 \
  --trigger manual \
  --probe-url http://10.0.0.18:32366/whoami \
  --probe-interval-ms 1000 \
  --probe-pre-seconds 30 \
  --probe-post-seconds 60 \
  --reset-after-run \
  --reset-routing-context cluster1 \
  --reset-source-context cluster-pnet \
  --reset-subset v1 \
  -- \
  ./scripts/migration/single-migration.sh routing-demo-7c8f6c5b6d-abcde \
    --source-cluster cluster-pnet \
    --dest-cluster cluster-sev-snp \
    --namespace istio-enabled \
    --istio-routing-context cluster1
```

> **PNET security-triggered migrations**: the `--trigger falco` value is only
> meaningful if a Falco daemon is actually installed on the PNET cluster and
> is forwarding alerts to the CubeMig backend's `/alert` endpoint. If Falco
> is **not** running on PNET (the common case in this thesis), then a
> `cluster-pnet -> cluster-sev-snp` run is a manual remote-to-TEE
> relocation; record it as `--trigger manual`. Do not file Falco-triggered
> runs as evidence of "Falco-driven PNET migration" unless the PNET-side
> Falco install can be demonstrated for that run.

For the `routing-demo` PNET security scenario, starting an evaluation with
`--trigger falco`, `--source cluster-pnet` and `--dest cluster-sev-snp`
publishes a correlated MMT event before the measured migration begins. The
event is sent from the PNET/source context to the PNET-reachable cluster1
Kafka listener:

```
topic: mmt-falco-events
bootstrap: 192.168.200.11:30094
```

The event type is `mmt_attack_candidate` and includes `run_id`, `pod_name`
and a unique `nonce`. The backend `/alert` path records the matching
`MMT Attack Candidate From Kafka` alert into the evaluation run directory only
when that nonce appears in the alert payload; it does not start a second
migration for that correlated evaluation alert. Normal/manual MMT candidate
alerts without the active evaluation nonce keep the usual behavior and still
trigger migration according to `config.json`.

### Wrapper-owned vulnerability simulation scenario

Evaluation runs with `--trigger simulate` are reserved for `vuln-spring` and
`vuln-redis`.
The backend/UI chooses a real simulation attack (`reverse_shell`,
`data_destruction` or `log_removal`) and registers the expected Falco rule
before the wrapper starts the attack via `/simulate`. The matching Falco alert
is written to `falco_trigger.json` and is not allowed to start a second,
normal `/alert` migration; the wrapper then runs `single-migration.sh` itself
so migration timing, logs, snapshots and reset evidence remain owned by the
evaluation run.

For this mode, run exactly one selected vulnerable workload pod in the source
namespace. The backend rejects simulation evaluations if multiple running
pods for that workload are present, because `/simulate` targets the Service
rather than a specific pod. `vuln-redis` simulations use the Redis Lua sandbox
escape against the discovered `vuln-redis` NodePort. Manual attacks from the
Simulation tab are unchanged and still follow normal `/alert` / `config.json`
behavior.

### Passive workload example

`mmt-probe` does not participate in the external `/whoami` response path, so
it does not require the routing-demo HTTP probe and does not trigger the
routing-demo reset by default.

```bash
scripts/utils/evaluation/run_eval_migration.sh \
  --run-id 001_mmt_probe_pnet_to_sev \
  --source cluster-pnet \
  --dest cluster-sev-snp \
  --namespace istio-enabled \
  --workload mmt-probe \
  --pod mmt-probe-xxxxx \
  --load-rps 0 \
  --concurrency 0 \
  --trigger manual \
  --no-reset-after-run \
  -- \
  ./scripts/migration/single-migration.sh mmt-probe-xxxxx \
    --source-cluster cluster-pnet \
    --dest-cluster cluster-sev-snp \
    --namespace istio-enabled \
    --istio-routing-context cluster1
```

## Routing-demo HTTP probe and reset flags (v1.2)

| Flag | Default | Purpose |
|------|---------|---------|
| `--probe-url` | required for `routing-demo` | Cluster1 ingress `/whoami` URL |
| `--probe-interval-ms` | 500 | Probe period |
| `--probe-pre-seconds` | 30 | Baseline probing before migration |
| `--probe-post-seconds` | 60 | Continue probing after migration |
| `--probe-timeout-ms` | 3000 | Per-request timeout |
| `--require-routing-demo-probe` | true | Abort routing-demo runs without `--probe-url` |
| `--no-require-routing-demo-probe` | off | Allow routing-demo runs without a probe |
| `--expected-initial-subset` | v1 | Warn if `routing-demo` VS subset differs |
| `--allow-existing-fault` | false | Abort if `.spec.http[0].fault` is already set |
| `--reset-after-run` | true for routing-demo | Reset routing-demo after evidence collection |
| `--no-reset-after-run` | off | Disable routing-demo reset |
| `--reset-routing-context` | cluster1 | Context containing the north-south VirtualService |
| `--reset-source-context` | `--source` | Context where source routing-demo deployment is restored |
| `--reset-subset` | v1 | Subset to route to after reset |
| `--reset-timeout-seconds` | 120 | Source deployment rollout timeout |

The HTTP probe is **routing-demo-only by default**. For routing-demo runs,
`--probe-url` must point at the **cluster1 ingress `/whoami` URL** unless
`--no-require-routing-demo-probe` is set. The probe produces `http_probe.csv`
and, when parsing succeeds, `http_probe_summary.json`; those files are used
for client-visible downtime, latency impact and counter-based state
preservation.

For state-consistency tests, the HTTP probe should be the only client
incrementing the routing-demo counter. If a separate load generator also
calls `/whoami`, then `counter_after == counter_before + 1` is no longer a
valid state-preservation check unless all client requests are logged.

Non-routing-demo workloads such as `mmt-probe` and `vuln-spring` do not
require `--probe-url`, do not create `http_probe.csv` by default, and do not
trigger the routing-demo reset by default. `vuln-spring` security timing is
evaluated from Falco/backend/migration logs rather than the routing-demo
counter.

Reset is also **routing-demo-only by default**. It is a test-harness cleanup
step, not part of migration timing: it runs after the HTTP probe post-window,
after `k8s_after.txt` / `istio_after.yaml`, after checkpoint inspection, and
after failure diagnostics. Reset uses `cluster1` as the Istio routing context
by default; for `cluster-pnet -> cluster-sev-snp`, the routing-demo
VirtualService is still checked and reset in `cluster1`.

Before routing-demo migration the wrapper writes `pre_run_sanity.txt`
(cluster1 VirtualService YAML, source pod, optional single `curl`). If an
Istio fault is present and `--allow-existing-fault` is not set, the run aborts
with exit code `2` and the message:
`pre-existing Istio fault detected in cluster1 VirtualService; clear fault before evaluation run`.

Resetting to `v1` is only safe if the source routing-demo deployment is
Running and its Service has ready endpoints. The wrapper scales the source
deployment to one replica, waits for rollout, checks endpoints, then patches
only the central VirtualService fields needed to remove a fault and point
traffic back to `v1`. It does not rewrite the full VirtualService and does
not delete Services, DestinationRules, Gateways or Deployments. Destination
`routing-demo-restore-*` pods are deleted only after after-snapshots were
collected.

Migration output: `migration.stdout.log` (tee of subprocess stdout). The
timestamped `single-migration.sh` log is copied to `migration.log` via
`--log-dir $RUN_DIR` (or searched under `/home/ubuntu/contMigration_logs`).

## Output layout

For every run a single directory is created (UTC date dir + run id):

```
$OUT_ROOT/YYYY-MM-DD/$RUN_ID/
  metadata.json
  pre_run_sanity.txt
  http_probe.csv              # routing-demo with --probe-url
  http_probe_summary.json     # routing-demo with parseable probe CSV
  falco_event.json            # trigger=falco routing-demo PNET event payload
  falco_trigger.txt           # trigger=falco producer/wait log
  falco_trigger.json          # trigger=falco backend alert evidence
  simulation_trigger.txt      # trigger=simulate /simulate request log
  simulation_trigger.json     # trigger=simulate request/response evidence
  migration.log               # timestamped single-migration.sh log
  migration.stdout.log        # raw subprocess stdout/stderr                 # tee of stdout+stderr from the migration cmd
  k8s_before.txt / k8s_after.txt
  istio_before.yaml / istio_after.yaml
  host_metrics.csv              # 1Hz; host load, mem, ens3 + wg0 byte counters
  wg_before.txt / wg_after.txt  # only meaningful when wg0 exists
  reset_after.txt               # routing-demo reset command log
  reset_after_istio.yaml        # routing-demo reset result
  reset_after_k8s.txt           # routing-demo source readiness result
  artifact_sizes.txt            # newest checkpoint .tar's + du -sh of root
  checkpoint/
    checkpoint_path.txt
    checkpoint_stat.txt
    checkpoint_sha256.txt
    checkpoint_tar_listing.txt
    checkpointctl_show.txt      # written even if checkpointctl is missing
    checkpointctl_inspect.txt
  failure_diagnostics.txt       # only present when migration exit_code != 0
```

A single CSV row per run is appended to:

```
$OUT_ROOT/evaluation_results.csv
```

Columns:

```
run_id,source,dest,namespace,workload,pod,load_rps,concurrency,trigger,
start_time_utc,end_time_utc,exit_code,run_dir,checkpoint_file,
http_probe_csv,pre_existing_fault_detected,migration_log_found,
reset_after_run,reset_failed,reset_exit_code
```

This makes it easy to aggregate runs (`pandas.read_csv` or even `awk`) for
the thesis evaluation tables.

## What `k8s_before` / `k8s_after` capture and why

For **both** source and destination cluster contexts, executed explicitly
with `kubectl --context "$CTX"`:

* `kubectl --context $CTX -n $NS get pods -o wide` — which pod is running on
  which node; this is the only way to see node placement of the
  pre-migration pod vs the restored pod afterwards.
* `kubectl --context $CTX -n $NS get svc,endpoints,endpointslices -o wide` —
  shows whether the Service and Endpoints exist on the destination and which
  pod IPs they point at. Required when debugging Istio traffic switching
  failures.
* `kubectl --context $CTX -n $NS get events --sort-by=.lastTimestamp | tail -80`
  — the last 80 events at the time of the snapshot. Captures `Pulled`,
  `Created`, `Started`, `Killing`, `FailedScheduling`, image-pull errors etc.
* `kubectl --context $CTX get nodes -o wide` — node kernel/runtime versions;
  CRIU restore is sensitive to these mismatches, so they are useful to file
  alongside each run.

`istio_before.yaml` / `istio_after.yaml` are collected from the **central
Istio control plane on cluster1** (the routing-demo and mmt-probe
VirtualServices live there in this thesis). If cluster1 is unreachable the
file will contain a `(failed)` line; the rest of the run continues normally.

## Checkpoint inspection

The wrapper deliberately collects only metadata about the checkpoint archive
and never copies it. It tries two paths to locate the archive:

1. Parse `migration.log` for a `/home/ubuntu/nfs/checkpoints/.../checkpoint-*.tar`
   path that the migration script printed.
2. Fall back to: newest `checkpoint-*.tar` under `--checkpoint-root` with
   `mtime` after the wrapper's start time. Useful when the migration script
   logs the path differently.

For the located archive, the wrapper writes:

* `checkpoint_path.txt` — the resolved absolute path.
* `checkpoint_stat.txt` — `stat` output (size, owner, mtime).
* `checkpoint_sha256.txt` — content hash; cheap reproducibility marker.
* `checkpoint_tar_listing.txt` — `tar -tf` listing (member paths only, no
  extraction).
* `checkpointctl_show.txt` — CRIU container summary, only if `checkpointctl`
  is installed; otherwise the file just says
  `checkpointctl not installed`.
* `checkpointctl_inspect.txt` — process tree / namespace / mounts of the
  checkpoint, only if `checkpointctl` is installed.

If `checkpointctl` is **not** installed, the run still completes
successfully; the two files exist but explain that the tool was missing.

### Secrets in checkpoints — important

CRIU checkpoints **dump full process memory**. That memory commonly
contains:

* environment variables (including ones backed by Kubernetes `Secret`s,
  e.g. database passwords, registry credentials, API tokens),
* request bodies that were in-flight at dump time,
* TLS session keys and other short-lived secrets.

For that reason this wrapper:

* Never copies the checkpoint `.tar` itself outside the NFS path the
  migration already wrote it to.
* Never runs `checkpointctl memparse` and never runs `gdb` / process memory
  inspection by default. Those tools can extract the in-memory strings of
  the dumped process, which would leak the secrets above into the
  evaluation directory. Run them manually only when you have a defensible
  reason and a separate, access-controlled storage location.

If you need to share an evaluation run directory (e.g. as a thesis
appendix), the directory layout above is safe: it contains hashes, paths
and listings but not the archive content nor the dumped memory.

## Failure diagnostics

When the migration command exits non-zero, the wrapper additionally writes
`failure_diagnostics.txt` with:

* `kubectl --context $SOURCE -n $NS describe pods` and the same for
  `$DEST` — captures restart counts, image pull errors,
  `CreateContainerError` and the like.
* `kubectl --context $CTX -n $NS get events --sort-by=.lastTimestamp | tail -120`
  for both contexts.
* If `--dest cluster-sev-snp`, an additional best-effort
  `sudo journalctl -u snap.microk8s.daemon-kubelite --since '20 minutes ago'`
  and `sudo journalctl -u crio --since '20 minutes ago'` on the local host
  (the SEV-SNP node in this thesis). Both are run with `sudo -n` so they
  silently fall back to `(failed or sudo not available without password)` if
  passwordless sudo is not configured — they never block the wrapper.

The wrapper's own exit code is still the migration's exit code; failure
diagnostic collection cannot mask a failure as a success or vice versa.

## What the wrapper deliberately does not do

* It does **not** read or copy `kubeconfig`, `.env`, service-account
  tokens, or WireGuard private key material.
* It does **not** copy checkpoint archives.
* It does **not** run `checkpointctl memparse` or `gdb` against the
  checkpoint.
* It does **not** mutate cluster state (no `kubectl apply`, `kubectl
  delete`, `kubectl patch`).
* It does **not** raise the migration's exit code on collector failure.

If you need a heavier collector later (e.g. CRI-O / kubelet log shipping,
node-level pcap), add a separate script — this wrapper is intentionally
minimal so it is safe to run on every evaluation migration.
