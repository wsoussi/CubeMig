# CubeMig: Container Migration with CRIU and Kubernetes

A comprehensive container migration platform that enables live migration of Kubernetes pods between clusters using CRIU (Checkpoint/Restore in Userspace) technology. The system includes automated threat detection, forensic analysis, and AI-powered security assessments.

## 🚀 Features

- **Live Container Migration**: Seamless pod migration between Kubernetes clusters with minimal downtime
- **CRIU Integration**: Uses CRIU for checkpoint/restore functionality
- **Web-based Management**: Angular frontend with FastAPI backend for easy migration management
- **Security Monitoring**: Falco integration for threat detection and automated migration triggers
- **Forensic Analysis**: Automated security analysis of migrated containers
- **AI Security Assessment**: AI-powered suggestions for security improvements
- **TEE Support**: Trusted Execution Environment migration capabilities
- **Multi-cluster Support**: Migration between different Kubernetes clusters

## 🏗️ Architecture

```
CubeMig/
├── apps/
│   ├── container_migration/
│   │   ├── frontend/          # Angular web interface
│   │   └── backend/           # FastAPI REST API
│   └── kubernetes/            # Demo applications
│       ├── cpu_intensive/
│       ├── mem_intensive/
│       ├── disk_rw_intensive/
│       ├── nginx/
│       ├── vuln-redis/
│       └── vuln-spring/
├── scripts/
│   ├── migration/             # Migration automation scripts
│   └── utils/                 # Utility scripts for setup and analysis
└── docs/                      # Documentation and meeting notes
```

## 🛠️ Technology Stack

### Backend (FastAPI)
- **Framework**: FastAPI with Python 3.10+
- **Dependencies**: 
  - `fastapi==0.115.2` - Modern web framework
  - `uvicorn==0.32.0` - ASGI server
  - `kubernetes==31.0.0` - Kubernetes Python client
- **Features**:
  - RESTful API for migration operations
  - Kubernetes cluster management
  - Falco alert processing
  - Forensic analysis integration
  - AI-powered security assessments

### Frontend (Angular)
- **Framework**: Angular CLI v17.3.11
- **Features**:
  - Real-time migration monitoring
  - Cluster and pod management interface
  - Migration history and logs
  - Security analysis results display

### Infrastructure
- **Container Runtime**: CRI-O with CRIU support
- **Orchestration**: Kubernetes multi-cluster setup
- **Image Registry**: Local container registry
- **Storage**: NFS for checkpoint persistence
- **Security**: Falco for runtime threat detection

## 🚀 Quick Start

### Prerequisites

- Kubernetes clusters (minimum 2) with CRI-O runtime
- CRIU-enabled nodes
- NFS storage for checkpoint sharing
- Docker/Podman with Buildah
- Node.js 18+ and npm
- Python 3.10+

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd CubeMig
   ```

2. **Setup Backend**
   ```bash
   cd apps/container_migration/backend
   pip install -r requirements.txt
   python3 main.py
   ```
   Backend will be available at `http://localhost:8000`

3. **Setup Frontend**
   ```bash
   cd apps/container_migration/frontend
   npm install
   ng serve
   ```
   Frontend will be available at `http://localhost:4200`

## 📋 Usage

### Manual Migration

1. **Access the Web Interface**: Navigate to `http://localhost:4200`
2. **Select Source Pod**: Choose a pod from the source cluster
3. **Configure Migration**: Select target cluster and migration options
4. **Enable Security Features** (optional):
   - Forensic Analysis: Analyze container for security issues
   - AI Suggestions: Get AI-powered security recommendations
5. **Execute Migration**: Click migrate and monitor progress

### Automated Migration

The system can automatically trigger migrations based on Falco security alerts:

```json
{
    "rule": "Read sensitive file untrusted",
    "cluster": "cluster1", 
    "action": "migrate",
    "targetCluster": "cluster2",
    "forensic_analysis": true,
    "AI_suggestion": true
}
```

### CLI Migration

For direct script execution:

```bash
# Basic migration
./scripts/migration/single-migration.sh <pod-name>

# Migration with forensic analysis
./scripts/migration/single-migration.sh <pod-name> --forensic-analysis

# Migration with AI suggestions
./scripts/migration/single-migration.sh <pod-name> --forensic-analysis --ai-suggestion
```

## 🔧 Migration Process

1. **Checkpoint Creation**: CRIU creates a checkpoint of the running container
2. **Image Building**: Checkpoint is packaged into a new container image
3. **Registry Push**: Image is pushed to the container registry
4. **Cluster Switch**: Context switches to destination cluster
5. **Image Pre-pull**: Ensures original base image is available
6. **Pod Restoration**: New pod is created from the checkpoint image
7. **Validation**: Verifies successful migration and pod health
8. **Cleanup**: Removes old pod and manages checkpoint storage

## 🔒 Security Features

### Threat Detection
- **Falco Integration**: Real-time detection of suspicious activities
- **Configurable Rules**: Custom security rules for different scenarios
- **Automated Response**: Automatic migration triggers on security events

### Forensic Analysis
- **Container Inspection**: Detailed analysis of container state
- **File System Changes**: Detection of modifications and additions
- **Process Analysis**: Examination of running processes and connections

### AI Security Assessment
- **Groq API Integration**: Leverages LLaMA model for security analysis
- **Vulnerability Assessment**: Identifies potential security issues
- **Remediation Suggestions**: Provides actionable security recommendations
- **Attack Hypothesis**: Generates theories about potential attacks

## 🧪 Demo Applications

The repository includes several demo applications for testing:

- **CPU Intensive**: High CPU usage applications
- **Memory Intensive**: Applications with large memory footprints  
- **Disk I/O Intensive**: Applications with heavy disk operations
- **Vulnerable Applications**: 
  - `vuln-redis`: Redis with known vulnerabilities
  - `vuln-spring`: Spring Boot application with security issues
- **Web Services**: Nginx and various web applications

## 📊 Performance Monitoring

The system tracks detailed performance metrics:

- **Checkpoint Creation Time**: Time to create CRIU checkpoint
- **Image Build Time**: Time to build checkpoint image
- **Network Transfer Time**: Time to push/pull images
- **Pod Startup Time**: Time for pod to become ready
- **Total Migration Time**: End-to-end migration duration

Results are logged and available through the web interface.

## 🔧 Configuration

### Backend Configuration (`backend/config.json`)
```json
{
    "config": [
        {
            "rule": "Security Rule Name",
            "cluster": "source-cluster", 
            "action": "migrate|log",
            "targetCluster": "destination-cluster",
            "forensic_analysis": true|false,
            "AI_suggestion": true|false
        }
    ]
}
```

### Environment Variables
Create `.env` file in `scripts/migration/`:
```bash
GROQ_API_KEY=your_groq_api_key
```

## 🚀 Development

### Backend Development
```bash
cd apps/container_migration/backend
# Install dependencies
pip install -r requirements.txt
# Run with auto-reload
python3 main.py
```

### Frontend Development  
```bash
cd apps/container_migration/frontend
# Install dependencies
npm install
# Serve with live reload
ng serve
# Build for production
ng build
```



## 📚 API Documentation

Once the backend is running, visit `http://localhost:8000/docs` for interactive API documentation.

### Key Endpoints
- `POST /migrate` - Trigger manual migration
- `POST /alert` - Process Falco security alerts
- `GET /migration-status/{pod_name}` - Check migration status
- `GET /k8s/pods/{cluster}` - List pods in cluster
- `GET /logs/{type}` - Retrieve system logs

## 👥 Contributors

- **Michael Azhari Meier** - Core Development
- **Rinchen Kolodziejczyk** - Core Development  
- **Anthony John Mamaril** - Core Development
- **Wissem Soussi** - Core Development

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## 🆘 Troubleshooting

### Common Issues

1. **Migration Fails with "Image Not Found"**
   - Ensure original base image is available in destination cluster
   - Check registry connectivity and credentials

2. **CRIU Checkpoint Fails**
   - Verify CRIU is properly installed and configured
   - Check if application is CRIU-compatible
   - Ensure proper permissions on checkpoint storage

3. **Pod Won't Start After Migration**
   - Check resource availability in destination cluster
   - Verify network policies and security contexts
   - Review pod logs for specific errors

### Logs and Debugging
- Backend logs: Check terminal where `python3 main.py` is running
- Frontend logs: Browser developer console
- Migration logs: `/home/ubuntu/contMigration_logs/`
- Kubernetes logs: `kubectl logs <pod-name>`

---

**Note**: This project demonstrates advanced container migration techniques and should be used in controlled environments. Ensure proper security measures are in place before deploying in production scenarios.