# Red Hat Documentation RAG System

An intelligent search and retrieval system for Red Hat system administration documentation, built specifically for RHEL 9 with Python 3.12 and Podman.

## 🎯 Features

- 🔍 **Semantic Search**: Intelligent search through PDF documentation using vector embeddings
- 🎨 **Modern Web Interface**: Beautiful, responsive interface with Red Hat theming
- 🐳 **Podman Native**: Optimized for RHEL 9 with rootless containers and SELinux integration
- 📊 **Real-time Analytics**: Performance metrics and system health monitoring
- 📤 **Document Management**: Upload new PDFs via web interface
- 🔒 **Enterprise Security**: SELinux compatible with proper security contexts

## 📁 Project Structure

```
redhat-rag/
├── main.py                    # FastAPI backend application
├── static/index.html          # Web interface (save frontend code here)
├── requirements.txt           # Python dependencies
├── Containerfile             # Podman container definition  
├── .env                      # Environment configuration
├── deploy-podman.sh          # Main deployment script
├── redhat-rag.service        # Systemd service file
├── backup.sh                 # Backup utility
├── health-check.sh           # Health monitoring
├── documents/                # Place your Red Hat PDFs here
│   └── *.pdf
└── data/                     # Created during deployment
    ├── chromadb/             # Vector database
    ├── logs/                 # Application logs
    └── backups/              # System backups
```

## 🚀 Quick Start

### Prerequisites

- RHEL 9 with Python 3.12
- Podman installed (`dnf install podman`)
- At least 2GB RAM and 5GB disk space

### Installation

1. **Create project directory and save files:**
```bash
mkdir redhat-rag && cd redhat-rag

# Save all the individual files from the artifacts:
# - main.py (backend)
# - static/index.html (frontend - create static/ directory first)
# - requirements.txt
# - Containerfile
# - .env
# - deploy-podman.sh
# - redhat-rag.service
# - backup.sh
# - health-check.sh
```

2. **Make scripts executable:**
```bash
chmod +x deploy-podman.sh backup.sh health-check.sh
```

3. **Add your PDF documents:**
```bash
# Copy your Red Hat documentation to documents/
cp /path/to/your/rhel-*.pdf documents/
```

4. **Deploy the system:**
```bash
./deploy-podman.sh
```

5. **Access the system:**
- **Web Interface**: http://localhost:8080
- **API Documentation**: http://localhost:8080/docs
- **Health Check**: http://localhost:8080/health

## 📋 File Descriptions

### Core Application Files

- **`main.py`**: Complete FastAPI backend with PDF processing, vector search, and REST API
- **`static/index.html`**: Modern web interface with search functionality and document management
- **`requirements.txt`**: Python dependencies optimized for Python 3.12
- **`Containerfile`**: Podman container definition using UBI 9 and Python 3.12

### Configuration Files

- **`.env`**: Environment variables for model settings, paths, and performance tuning
- **`redhat-rag.service`**: Systemd service file for automatic startup and management

### Deployment & Management Scripts

- **`deploy-podman.sh`**: Main deployment script with network optimization and error handling
- **`backup.sh`**: Creates compressed backups of vector database and documents
- **`health-check.sh`**: Comprehensive system health monitoring and diagnostics

## 🔧 Configuration

### Environment Variables (.env)

```bash
# Document storage
DOCUMENTS_DIR=/app/documents
CHROMA_DB_PATH=/app/chromadb

# Model configuration  
EMBEDDING_MODEL=all-MiniLM-L6-v2
CHUNK_SIZE=500
CHUNK_OVERLAP=50

# Search configuration
MAX_RESULTS=20
MIN_CONFIDENCE=0.3

# Logging
LOG_LEVEL=INFO
```

### Network Configuration

The deployment script automatically detects and uses the best network backend:
- **pasta** (RHEL 9 default, preferred)
- **slirp4netns** (fallback option)
- **default** (most compatible)

## 🛠️ Management Commands

### Basic Operations
```bash
# Deploy/Update system
./deploy-podman.sh

# Check system health
./health-check.sh

# Create backup
./backup.sh

# View logs
podman logs redhat-rag

# Restart service
podman restart redhat-rag
```

### Container Management
```bash
# Stop service
podman stop redhat-rag

# Start service  
podman start redhat-rag

# Remove container (keeps data)
podman stop redhat-rag && podman rm redhat-rag

# View resource usage
podman stats redhat-rag
```

### Document Management
```bash
# Add new PDFs (then restart to process)
cp new-document.pdf documents/
podman restart redhat-rag

# Reprocess all documents
curl -X POST http://localhost:8080/api/documents/reprocess

# List processed documents
curl http://localhost:8080/api/documents
```

## 🔄 Systemd Service

### User Service (Recommended)
```bash
# Install user service
mkdir -p ~/.config/systemd/user
cp redhat-rag.service ~/.config/systemd/user/

# Enable and start
systemctl --user daemon-reload
systemctl --user enable redhat-rag
systemctl --user start redhat-rag

# Enable user lingering (start on boot)
sudo loginctl enable-linger $USER
```

### System Service
```bash
# Install system service (requires root)
sudo cp redhat-rag.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable redhat-rag
sudo systemctl start redhat-rag
```

## 📊 API Endpoints

### Search
```bash
# Search documents
curl -X POST http://localhost:8080/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "podman configuration", "max_results": 10}'
```

### System Information
```bash
# Get statistics
curl http://localhost:8080/api/stats

# Health check
curl http://localhost:8080/health

# List documents
curl http://localhost:8080/api/documents
```

### Document Management
```bash
# Upload new PDF
curl -X POST http://localhost:8080/api/documents/upload \
  -F "file=@/path/to/document.pdf"

# Download document
curl http://localhost:8080/api/documents/filename.pdf
```

## 🔒 Security Features

### SELinux Integration
- Automatic container file context labeling with `:Z`
- Compatible with enforcing SELinux policies
- Proper volume mounting with security contexts

### Container Security
- Rootless container execution (user 1001)
- Memory and CPU limits
- Network isolation options
- Health monitoring and restart policies

### Data Protection
- Encrypted vector embeddings storage
- Secure PDF processing pipeline
- Input validation and sanitization
- CORS protection for API endpoints

## 🐛 Troubleshooting

### Common Issues

**Container won't start:**
```bash
# Check logs
podman logs redhat-rag

# Try rebuilding
podman rmi localhost/redhat-rag:latest
./deploy-podman.sh
```

**Network issues:**
```bash
# Check port availability
ss -tuln | grep :8080

# Test container networking
podman exec redhat-rag curl http://localhost:8080/health

# Check firewall
sudo firewall-cmd --list-ports
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --reload
```

**SELinux denials:**
```bash
# Check for denials
sudo ausearch -m avc -ts recent

# Allow container connections (if needed)
sudo setsebool -P container_connect_any 1

# Relabel volumes
sudo restorecon -R ./data ./documents
```

**Performance issues:**
```bash
# Check resource usage
podman stats redhat-rag

# Increase memory limit in deploy script
# Change --memory 2g to --memory 4g

# Check disk space
df -h
du -sh ./data
```

### Health Check Results

The `health-check.sh` script provides comprehensive diagnostics:
- Container status and resource usage
- HTTP endpoint availability
- API functionality verification
- Disk usage analysis
- Network connectivity testing

## 📈 Performance Optimization

### Hardware Recommendations
- **Minimum**: 2GB RAM, 2 CPU cores, 5GB disk
- **Recommended**: 4GB RAM, 4 CPU cores, 20GB disk
- **Optimal**: 8GB RAM, 8 CPU cores, 50GB SSD

### Tuning Parameters
```bash
# Increase chunk size for large documents
CHUNK_SIZE=1000

# Reduce confidence threshold for more results
MIN_CONFIDENCE=0.2

# Use faster embedding model (less accurate)
EMBEDDING_MODEL=all-MiniLM-L12-v2
```

## 🤝 Contributing

This system is designed for Red Hat system administrators. To customize:

1. **Modify categories** in `main.py` `CATEGORY_KEYWORDS`
2. **Adjust chunking** in `.env` `CHUNK_SIZE` and `CHUNK_OVERLAP`
3. **Change theming** in `static/index.html` CSS variables
4. **Add authentication** by uncommenting API key settings in `.env`

## 📝 License

Built for Red Hat Enterprise Linux environments. Uses open-source components under their respective licenses.

---

**Ready to search your Red Hat documentation intelligently!** 🎩
