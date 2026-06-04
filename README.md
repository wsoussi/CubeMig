# CubeMig: Container live migration in Kubernetes

A container migration demo platform that enables migration of Kubernetes pods between clusters using CRIU (Checkpoint/Restore in Userspace). CubeMig includes a web UI, a FastAPI backend, Istio-aware routing support, Falco alert handling, evaluation tooling, and demo workloads for testing migration scenarios.

This project is intended for controlled research and lab environments. A real migration requires Kubernetes clusters prepared with CRI-O, CRIU, shared checkpoint storage, and a reachable image registry.

## 🚀 Features

- **Live Container Migration**: Move Kubernetes pods between clusters with CRIU checkpoints
- **CRIU Integration**: Checkpoint and restore container state with CRI-O
- **Web-based Management**: Angular frontend with FastAPI backend
- **Istio Routing Demo**: Keep one client-facing endpoint while traffic moves
- **Security Monitoring**: Falco alerts can log events or trigger migration
- **Forensic Analysis**: Optional analysis hooks for migrated containers
- **AI Security Assessment**: Optional AI-assisted security suggestions
- **TEE Support**: Migration workflows for confidential-computing experiments
- **Evaluation Runs**: Capture logs, timing, HTTP probe results, and evidence

## 🏗️ Project Structure

```text
CubeMig/
├── apps/
│   ├── container_migration/
│   │   ├── frontend/          # Angular web interface
│   │   └── backend/           # FastAPI REST API
│   └── kubernetes/            # Demo applications
│       ├── routing_demo/
│       ├── mmt-probe/
│       ├── vuln-redis/
│       ├── vuln-spring/
│       ├── cpu_intensive/
│       ├── mem_intensive/
│       └── disk_rw_intensive/
├── scripts/
│   ├── migration/             # Migration automation scripts
│   └── utils/
│       ├── evaluation/         # Evaluation wrapper and evidence collection
│       └── setup/              # Worker, CRIU, Istio, kube-vip, MetalLB helpers
└── docs/                      # Thesis notes and supporting material
```

## 🛠️ Technology Stack

### Backend

- **Framework**: FastAPI with Python 3.10+
- **Server**: Uvicorn
- **Kubernetes access**: Kubernetes Python client
- **Responsibilities**:
  - Start manual migrations
  - Receive Falco alerts
  - List clusters and pods
  - Store alert/migration configuration
  - Expose logs and evaluation runs

### Frontend

- **Framework**: Angular 17
- **UI Features**:
  - Migration form
  - Cluster and pod selection
  - Migration pipeline monitoring
  - Log browser
  - Attack simulation controls
  - Evaluation run view

### Infrastructure

- **Runtime**: CRI-O with CRIU support
- **Storage**: Shared checkpoint storage, commonly NFS
- **Registry**: Local or lab registry for checkpoint images
- **Routing**: Istio multi-cluster routing for demos
- **Security**: Falco runtime alerts

## 🚀 Quick Start

### Prerequisites

For local development:

- Python 3.10+
- Node.js 18+
- npm
- `kubectl`

For real migrations:

- Kubernetes clusters, minimum 2
- CRI-O runtime with CRIU support
- CRIU-enabled source and destination nodes
- Shared checkpoint storage
- Reachable image registry, e.g. `<registry-host>:5000`
- Kubeconfig contexts matching the cluster names used in the UI/scripts

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd CubeMig
   ```

2. **Start the registry**
   ```bash
   docker start registry
   ```

3. **Start the backend**
   ```bash
   cd apps/container_migration/backend
   pip install -r requirements.txt
   python3 main.py
   ```

   Backend will be available at `http://localhost:8000`.

4. **Start the frontend**
   ```bash
   cd apps/container_migration/frontend
   npm install
   npm start
   ```

   Frontend will be available at `http://localhost:4200`.

5. **Open the API documentation**
   ```text
   http://localhost:8000/docs
   ```

## 📸 Screenshots

Screenshots of the individual parts of the application. Click a thumbnail for the full-size image.

| Screenshot | Description |
| --- | --- |
| <a href="docs/assets/screenshots/overview.png"><img src="docs/assets/screenshots/overview.png" width="150"/></a> | **Overview:** clusters and pods list loaded in the UI. |
| <a href="docs/assets/screenshots/migrationform.png"><img src="docs/assets/screenshots/migrationform.png" width="150"/></a> | **Migration form:** manual migration form before starting a run. |
| <a href="docs/assets/screenshots/migrations-pipeline.png"><img src="docs/assets/screenshots/migrations-pipeline.png" width="150"/></a> | **Migration pipeline:** pipeline status while a migration is executing. |
| <a href="docs/assets/screenshots/simulation.png"><img src="docs/assets/screenshots/simulation.png" width="150"/></a> | **Simulation:** attack simulation / alert generation view. |
| <a href="docs/assets/screenshots/evaluation.png"><img src="docs/assets/screenshots/evaluation.png" width="150"/></a> | **Evaluation:** evaluation run details or HTTP probe results. |

## 🎬 Guided Demo

The recommended demo workload is `routing-demo`:

```text
apps/kubernetes/routing_demo
```

It exposes:

```http
GET /whoami
```

The response includes the serving cluster, version, and in-memory counter. This makes it easy to see when traffic moves after migration.

### Demo Flow

1. **Open the UI**
   - Navigate to `http://localhost:4200`
   - Confirm the backend is reachable

2. **Select the source pod**
   - Go to the migration page
   - Select the source cluster
   - Select the namespace
   - Select the running pod

3. **Configure the migration**
   - Choose the destination cluster
   - Set optional flags such as forensic analysis or AI suggestion
   - Confirm the registry value is correct

4. **Start the migration**
   - Click migrate
   - Watch the pipeline status and backend logs

5. **Verify traffic**
   - Call the stable application endpoint before and after migration:
     ```bash
     curl http://<cluster-ingress-host>:<port>/whoami
     ```
   - The response should show the restored workload or target version, depending on the Istio routing setup

## 📋 Usage

### Manual Migration From The UI

1. Access the web interface at `http://localhost:4200`
2. Select a source cluster and pod
3. Select a target cluster
4. Configure optional migration settings
5. Execute the migration and monitor the pipeline
6. Check logs and verify the application endpoint

### CLI Migration

For direct script execution:

```bash
./scripts/migration/single-migration.sh <pod-name> \
  --source-cluster cluster1 \
  --dest-cluster cluster2 \
  --namespace istio-enabled \
  --registry <registry-host>:5000 \
  --istio-routing-context cluster1
```

Common options:

- `--forensic-analysis`: run forensic analysis hooks
- `--ai-suggestion`: request AI-assisted analysis
- `--disable-istio-sidecar`: restore without Istio sidecar injection
- `--skip-cpu-compat-check`: skip CPU compatibility validation
- `--cleanup-incompatible-mounts`: clean known problematic mounts before checkpoint

Print all options:

```bash
./scripts/migration/single-migration.sh --help
```

### Automated Migration With Falco

Falco can send alerts to the backend:

```text
POST /alert
```

The backend checks `apps/container_migration/backend/config.json` and decides whether to log the alert or trigger migration.

Example configuration shape:

```json
{
  "rule": "Read sensitive file untrusted",
  "cluster": "cluster1",
  "action": "migrate",
  "targetCluster": "cluster2",
  "registry_address": "<registry-host>:5000",
  "forensic_analysis": false,
  "AI_suggestion": false
}
```

You can also demonstrate this from the frontend. Open the **Simulation** page, choose a vulnerable workload/scenario, and start the simulation. The frontend calls the backend simulation route, the simulated attack produces the expected alert path, and the configured rule can trigger an automated migration.

### Evaluation Run

The evaluation wrapper captures migration evidence around a normal migration:

```bash
scripts/utils/evaluation/run_eval_migration.sh \
  --run-id demo_run \
  --source cluster1 \
  --dest cluster2 \
  --namespace istio-enabled \
  --workload routing-demo \
  --pod <routing-demo-pod> \
  --trigger manual \
  --probe-url http://<cluster-ingress-host>:<port>/whoami \
  --reset-after-run \
  -- \
  scripts/migration/single-migration.sh <routing-demo-pod> \
    --source-cluster cluster1 \
    --dest-cluster cluster2 \
    --namespace istio-enabled \
    --registry <registry-host>:5000 \
    --istio-routing-context cluster1
```

The wrapper can collect:

- Kubernetes snapshots before and after migration
- Istio routing state
- migration logs
- checkpoint metadata
- HTTP probe results
- host metrics
- reset evidence for demo workloads

## 🔧 Migration Process

The migration follows this **cold stateful migration** pattern with **8 phases**:

### Phase 1: Destination Preparation
- **Preflight Checks** (optional): Verify Kubernetes versions, node readiness, API health
- **Destination Setup**: Deploy insecure-registry and CRIU daemonsets
- **Base Image Pre-Pull**: Pre-pull the source pod's base image on destination (optional)
- **Routing Setup**: Deploy Service and DestinationRule for routing-demo (if applicable)

### Phase 2: Source Checkpoint
- **Source Preparation**: Configure CRIU, optionally clean incompatible mounts, inject HTTP 503 on routing
- **Checkpoint via API**: Call kubelet checkpoint endpoint; source pod **continues running**
- **Wait for Checkpoint File**: Poll NFS for checkpoint `.tar` to appear (default timeout: 180s)
- **Scale Source to 0**: Only after `.tar` is visible on NFS, scale source deployment to 0 replicas
  - **Critical**: Scaling before checkpoint completion prevents NFS sync
  - Source pod is now shut down

### Phase 3: Source Pod Shutdown
- Source Deployment/StatefulSet is scaled to 0 replicas after checkpoint file is visible
- Original pod is terminated; no further requests are served

### Phase 4: Checkpoint Processing
- **Fix Permissions**: Set readable/writable permissions on checkpoint `.tar`
- **CPU Compatibility Check** (optional): Validate target CPU against checkpoint CPU requirements
- **Mount Normalization** (optional): Remove incompatible mounts from checkpoint

### Phase 5: Image & Registry
- **Build Checkpoint Image**: Use buildah/podman to create OCI image from checkpoint `.tar`
- **Push to Registry**: Push checkpoint image to configured registry

### Phase 6: Checkpoint Image on Destination
- **Switch to Destination Context**: kubectl use-context
- **Pre-Pull Checkpoint Image** (optional): Daemonset pre-pulls checkpoint image on destination nodes

### Phase 7: Pod Restoration
- **Generate Restore YAML**: Create pod spec with checkpoint image, optionally disable Istio sidecar
- **Deploy Restore Pod**: kubectl apply restore pod; CRI-O triggers CRIU restore automatically via annotations
- **Wait for Pod Ready**: Poll pod status (timeout: 300s); fail-fast on `CreateContainerError`, `ErrImagePull`, etc.

### Phase 8: Traffic Switching & Cleanup
- **Switch Traffic** (if Istio): Update VirtualService to route to v2 (destination pod)
- **Cleanup Old Checkpoints**: Keep only last 5 checkpoints per app
- **Log Performance**: Document CRIU timing (freeze, memdump, memwrite), migration duration
- **Optional Analysis**: Run forensic analysis and/or AI security suggestions

## 🧪 Demo Applications

- **routing-demo**: Main Istio migration demo with `/whoami`
- **mmt-probe**: MMT/Kafka-backed event flow workload
- **vuln-redis**: Vulnerable Redis workload for security simulations
- **vuln-spring**: Vulnerable Spring workload for security simulations
- **CPU Intensive**: CPU benchmark workloads
- **Memory Intensive**: Memory benchmark workloads
- **Disk I/O Intensive**: Disk benchmark workloads
- **Nginx / Flask**: Simple web service examples

## ⚙️ Kubernetes Setup Files

Cluster setup examples live in:

```text
scripts/utils/setup/k8s
```

Important folders:

- `cluster1/istio`: primary Istio and routing-demo resources
- `cluster1/kube-vip`: kube-vip setup
- `cluster2/istio`: remote Istio values and gateway Service
- `cluster2/kube-vip`: kube-vip setup
- `cluster-pnet/metallb`: MetalLB pools and L2 advertisements
- `cluster-pnet/network`: PNET routing/NAT helper

These files are examples for a lab topology. Review addresses, node names, namespaces, and Helm values before applying them.

## 🔧 Configuration

### Backend Configuration

Main config file:

```text
apps/container_migration/backend/config.json
```

It maps Falco rules to actions such as `log` or `migrate`.

### Environment Variables

Create `.env` in `scripts/migration/` for local-only values:

```bash
MIGRATION_REGISTRY=<registry-host>:5000
ISTIO_ROUTING_CONTEXT=cluster1
GROQ_API_KEY=<optional-api-key>
```

Do not commit `.env`.

## 🆘 Troubleshooting

### Migration fails with image or pull errors

- Check that the registry is reachable from the migration host and destination cluster
- Confirm the registry address matches `--registry` or `MIGRATION_REGISTRY`
- Check destination pod events with `kubectl describe pod`

### CRIU checkpoint fails

- Verify CRIU is installed
- Verify CRI-O checkpoint support is enabled
- Check source node permissions and checkpoint storage
- Confirm the workload is compatible with CRIU

### Restored pod does not start

- Check CPU, kernel, cgroup, and mount compatibility
- Check image pull errors
- Check destination cluster events and pod logs

### UI cannot load clusters or pods

- Confirm the backend is running
- Confirm kubeconfig contexts are available to the backend process
- Open `http://localhost:8000/docs` and test the Kubernetes endpoints

### Logs and debugging

- Backend logs: terminal running `python3 main.py`
- Frontend logs: browser developer console
- Migration logs: generated by the migration script
- Kubernetes logs: `kubectl logs <pod-name>`

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make a focused change
4. Run the relevant checks
5. Open a pull request with sanitized logs or screenshots if needed

## 👥 Contributors

- **Michael Azhari Meier** - Core Development
- **Rinchen Kolodziejczyk** - Core Development
- **Anthony John Mamaril** - Core Development
- **Wissem Soussi** - Core Development
- **Zino Scalia** - Core Development
- **Harun Ibushoski** - Core Development

## 📝 License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.
