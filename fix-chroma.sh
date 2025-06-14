#!/bin/bash
# Script to fix ChromaDB permissions and SELinux issues
# Run this before deploying the container

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_header() { echo -e "${CYAN}🎩 $1${NC}"; }

# Configuration
CONTAINER_NAME="redhat-rag"
CHROMADB_DIR="./data/chromadb"

log_header "ChromaDB Directory Fix"

# Stop any running container
if podman ps | grep -q "$CONTAINER_NAME"; then
    log_info "Stopping container..."
    podman stop "$CONTAINER_NAME"
fi

# Remove container if it exists
if podman ps -a | grep -q "$CONTAINER_NAME"; then
    log_info "Removing container..."
    podman rm -f "$CONTAINER_NAME"
fi

# Ensure the ChromaDB directory exists
mkdir -p "$CHROMADB_DIR"

# Reset the ChromaDB directory
log_info "Resetting ChromaDB directory..."
rm -rf "${CHROMADB_DIR:?}"/* 2>/dev/null || true

# Create necessary subdirectories
mkdir -p "$CHROMADB_DIR/index"
mkdir -p "$CHROMADB_DIR/data"

# Fix permissions (make fully accessible)
log_info "Setting permissions..."
chmod -R 777 "$CHROMADB_DIR"

# Fix SELinux contexts if SELinux is enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    log_info "Setting SELinux contexts..."
    
    if command -v chcon >/dev/null 2>&1; then
        # Set container_file_t context recursively
        chcon -Rt container_file_t "$CHROMADB_DIR" || true
    else
        log_warning "chcon not available - using alternative approach"
        # Alternative: create a .dockerignore file to signal special handling
        touch "$CHROMADB_DIR/.podmanignore"
    fi
    
    # Additional permissive handling if needed
    if command -v semanage >/dev/null 2>&1; then
        log_info "Setting additional SELinux policies..."
        # Allow container to write to mounted volumes
        sudo semanage fcontext -a -t container_file_t "$CHROMADB_DIR(/.*)?" || true
        sudo restorecon -R "$CHROMADB_DIR" || true
    fi
fi

# Create a placeholder to ensure proper permissions
log_info "Creating placeholder files..."
echo "# ChromaDB data directory - DO NOT DELETE" > "$CHROMADB_DIR/README.txt"
chmod 666 "$CHROMADB_DIR/README.txt"

# Create a modified .env file for ChromaDB
log_info "Creating updated .env file..."
cat > .env.chromadb << 'EOF'
DOCUMENTS_DIR=/app/documents
CHROMA_DB_PATH=/app/chromadb
EMBEDDING_MODEL=all-MiniLM-L6-v2
CHUNK_SIZE=500
CHUNK_OVERLAP=50
MAX_RESULTS=20
MIN_CONFIDENCE=0.3
LOG_LEVEL=INFO

# Added for ChromaDB stability
PERSIST_DIRECTORY=/app/chromadb
ANONYMIZED_TELEMETRY=False
ALLOW_RESET=True
EOF

# Move the new .env file in place
mv .env.chromadb .env

log_success "ChromaDB directory prepared successfully!"
log_info "Now run your deployment script to start the container"
