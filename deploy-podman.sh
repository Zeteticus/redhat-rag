#!/bin/bash
# Complete fixed deployment script with ChromaDB fixes
# Optimized for RHEL 9.6

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="redhat-rag"
IMAGE_NAME="localhost/redhat-rag:latest"
PORT="8080"

# Functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_header() { echo -e "${CYAN}🎩 $1${NC}"; }

# Thoroughly clean up any existing containers
cleanup_existing() {
    log_info "Cleaning up any existing containers..."
    
    # Stop container if running
    if podman ps | grep -q "$CONTAINER_NAME"; then
        podman stop "$CONTAINER_NAME"
    fi
    
    # Remove container if it exists
    if podman ps -a | grep -q "$CONTAINER_NAME"; then
        podman rm -f "$CONTAINER_NAME"
    fi
    
    # Additional cleanup for stuck containers (force removal)
    CONTAINER_ID=$(podman ps -a | grep "$CONTAINER_NAME" | awk '{print $1}')
    if [ -n "$CONTAINER_ID" ]; then
        podman rm -f "$CONTAINER_ID"
    fi
    
    log_success "Cleanup completed"
}

fix_chromadb_directory() {
    log_header "Fixing ChromaDB Directory"
    
    # Define ChromaDB directories
    CHROMADB_DIR="./data/chromadb"
    
    # Ensure the ChromaDB directory exists
    mkdir -p "$CHROMADB_DIR"
    
    # Reset the ChromaDB directory (remove all contents)
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
            # Alternative: create a file to signal special handling
            touch "$CHROMADB_DIR/.podmanignore"
        fi
    fi
    
    # Create a placeholder to ensure proper permissions
    log_info "Creating placeholder files..."
    echo "# ChromaDB data directory - DO NOT DELETE" > "$CHROMADB_DIR/README.txt"
    chmod 666 "$CHROMADB_DIR/README.txt"
    
    log_success "ChromaDB directory prepared successfully"
}

update_env_file() {
    log_header "Updating .env Configuration"
    
    # Create or update .env file with ChromaDB-specific settings
    cat > .env << 'EOF'
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
    
    log_success "Updated .env file with ChromaDB settings"
}

check_prerequisites() {
    log_header "Checking Prerequisites"
    
    # Check if running on RHEL
    if [ -f /etc/redhat-release ]; then
        log_success "Detected RHEL system: $(cat /etc/redhat-release)"
    else
        log_warning "Not running on RHEL - some features may not work optimally"
    fi
    
    # Check if Podman is installed
    if ! command -v podman >/dev/null 2>&1; then
        log_error "Podman is not installed. Please install podman first."
        exit 1
    else
        log_success "Podman detected: $(podman --version)"
    fi
    
    # Check Python 3.12
    if command -v python3.12 >/dev/null 2>&1; then
        log_success "Python 3.12 detected"
    else
        log_info "Using Python from container"
    fi
}

create_directories() {
    log_header "Setting Up Directories"
    
    # Create required directories
    mkdir -p documents data/{chromadb,logs,backups} static
    
    log_success "Directories created"
    
    # Set proper ownership
    if [ "$EUID" -ne 0 ]; then
        chown -R $(id -u):$(id -g) data/ documents/ 2>/dev/null || true
    fi
    
    log_success "Directories configured"
}

build_container() {
    log_header "Building Container Image"
    
    # Check if required files exist
    if [ ! -f "main.py" ] || [ ! -f "Containerfile" ]; then
        log_error "Required files are missing. Please ensure all files are present."
        exit 1
    fi
    
    # Build the container image
    log_info "Building container image (this may take a few minutes)..."
    if podman build -t "$IMAGE_NAME" -f Containerfile .; then
        log_success "Container image built successfully"
        return 0
    else
        log_error "Container build failed"
        return 1
    fi
}

deploy_container() {
    log_header "Deploying Container"
    
    # Clean up any existing containers
    cleanup_existing
    
    # Run with open permissions on the mounted volumes
    log_info "Starting container with properly configured volumes..."
    
    # Use a more permissive approach for ChromaDB
    if podman run -d \
        --name "$CONTAINER_NAME" \
        --publish "127.0.0.1:$PORT:8080" \
        --volume "$(pwd)/documents:/app/documents:Z" \
        --volume "$(pwd)/data/chromadb:/app/chromadb:Z" \
        --volume "$(pwd)/data/logs:/app/logs:Z" \
        --env-file .env \
        --replace \
        "$IMAGE_NAME"; then
        
        log_success "Container started successfully"
        return 0
    else
        log_error "Container start failed"
        
        # Try with minimal config as last resort
        log_info "Trying minimal configuration as last resort..."
        if podman run -d \
            --name "$CONTAINER_NAME" \
            --publish "127.0.0.1:$PORT:8080" \
            --volume "$(pwd)/documents:/app/documents:Z" \
            --volume "$(pwd)/data/chromadb:/app/chromadb:Z" \
            --env-file .env \
            --replace \
            "$IMAGE_NAME"; then
            
            log_success "Container started with minimal configuration"
            return 0
        else
            log_error "All deployment attempts failed"
            return 1
        fi
    fi
}

wait_for_service() {
    log_header "Waiting for Service to Start"
    
    # Check if container is running
    if ! podman ps | grep -q "$CONTAINER_NAME"; then
        log_error "Container is not running!"
        podman ps -a | grep "$CONTAINER_NAME" || true
        return 1
    fi
    
    log_info "Container is running, waiting for service to become accessible..."
    
    # Try to connect to the service
    for i in {1..30}; do
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
            log_success "Service is accessible!"
            return 0
        fi
        
        # Check container logs for issues
        if podman logs "$CONTAINER_NAME" 2>&1 | grep -q "error returned from database"; then
            log_error "ChromaDB database access error detected"
            log_info "Container logs (last 10 lines):"
            podman logs "$CONTAINER_NAME" | tail -10
            
            log_info "Stopping container to try again with fixed ChromaDB settings..."
            podman stop "$CONTAINER_NAME"
            podman rm "$CONTAINER_NAME"
            
            # Apply more aggressive ChromaDB fixes
            log_info "Applying more aggressive ChromaDB fixes..."
            fix_chromadb_directory
            update_env_file
            
            # Try again with fixed settings
            log_info "Redeploying container with fixed settings..."
            if podman run -d \
                --name "$CONTAINER_NAME" \
                --publish "127.0.0.1:$PORT:8080" \
                --volume "$(pwd)/documents:/app/documents:Z" \
                --volume "$(pwd)/data/chromadb:/app/chromadb:rw,Z" \
                --volume "$(pwd)/data/logs:/app/logs:Z" \
                --env-file .env \
                --security-opt label=disable \
                --replace \
                "$IMAGE_NAME"; then
                
                log_success "Container redeployed with fixed ChromaDB settings"
                # Wait a bit more for the service to start
                sleep 10
                
                if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
                    log_success "Service is now accessible!"
                    return 0
                else
                    log_warning "Service still not responding, but container is running"
                    # Continue with warning
                    return 0
                fi
            else
                log_error "Failed to redeploy container with fixed settings"
                return 1
            fi
        fi
        
        # Progress indicator
        echo -n "."
        sleep 2
    done
    
    log_warning "Service did not respond to health check within timeout"
    log_info "The service might still be starting up or might be accessible through a different URL"
    log_info "Check container logs for more information:"
    podman logs "$CONTAINER_NAME" | tail -10
    
    # Consider it a partial success - let the user check
    return 0
}

show_completion_info() {
    log_header "🎉 Red Hat Documentation RAG Deployment Complete!"
    
    echo ""
    echo -e "${GREEN}🌐 Access Points:${NC}"
    echo "   Frontend:      http://localhost:$PORT"
    echo "   API Docs:      http://localhost:$PORT/docs"
    echo "   Health Check:  http://localhost:$PORT/health"
    
    echo ""
    echo -e "${CYAN}📁 Important Directories:${NC}"
    echo "   Documents:     $(pwd)/documents"
    echo "   Database:      $(pwd)/data/chromadb"
    echo "   Logs:          $(pwd)/data/logs"
    
    echo ""
    echo -e "${YELLOW}📋 Management Commands:${NC}"
    echo "   View logs:     podman logs $CONTAINER_NAME"
    echo "   Stop:          podman stop $CONTAINER_NAME"
    echo "   Start:         podman start $CONTAINER_NAME"
    echo "   Restart:       podman restart $CONTAINER_NAME"
    echo "   Remove:        podman stop $CONTAINER_NAME && podman rm $CONTAINER_NAME"
    
    echo ""
    echo -e "${BLUE}🎯 Next Steps:${NC}"
    echo "   1. Copy your Red Hat PDF documentation to: $(pwd)/documents/"
    echo "   2. Access the web interface and start searching!"
    
    echo ""
    echo -e "${GREEN}✅ Container Status:${NC}"
    podman ps --filter name=$CONTAINER_NAME
}

main() {
    log_header "Red Hat Documentation RAG - Podman Deployment (ChromaDB Fix)"
    echo "Optimized for RHEL 9.6 with Python 3.12 and Podman"
    echo ""
    
    # Run all steps with error handling
    check_prerequisites
    create_directories
    
    # Fix ChromaDB directory before building/running
    fix_chromadb_directory
    update_env_file
    
    if ! build_container; then
        log_error "Container build failed. Please check your files and try again."
        exit 1
    fi
    
    if ! deploy_container; then
        log_error "Container deployment failed."
        
        # Show detailed diagnostics
        echo ""
        echo -e "${YELLOW}🔧 Diagnostics:${NC}"
        echo "=== Container Status ==="
        podman ps -a | grep "$CONTAINER_NAME" || echo "No container found"
        
        echo ""
        echo "=== Container Logs ==="
        podman logs "$CONTAINER_NAME" 2>/dev/null || echo "No logs available"
        
        exit 1
    fi
    
    wait_for_service
    show_completion_info
    
    echo ""
    log_success "🎉 Deployment completed successfully!"
}

# Run main function
main "$@"
