#!/bin/bash
# Red Hat Documentation RAG Deployment Script for Podman on RHEL 9

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
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_header() {
    echo -e "${CYAN}🎩 $1${NC}"
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
        log_error "Podman is not installed. Installing..."
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y podman
            log_success "Podman installed"
        else
            log_error "Cannot install Podman automatically. Please install manually."
            exit 1
        fi
    else
        log_success "Podman detected: $(podman --version)"
    fi
    
    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        log_warning "curl not found. Installing..."
        sudo dnf install -y curl || log_warning "Could not install curl"
    fi
}

check_network_config() {
    log_info "Checking network configuration..."
    
    # Check if port is available
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln 2>/dev/null | grep -q ":$PORT "; then
            log_error "Port $PORT is already in use. Please free the port or change PORT variable."
            ss -tuln | grep ":$PORT" || echo "Port check failed"
            return 1
        fi
    else
        log_warning "ss command not available - cannot check port availability"
    fi
    
    # Test basic networking
    log_info "Testing network connectivity..."
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_warning "External connectivity test failed - this might affect container networking"
    fi
    
    return 0
}

create_directories() {
    log_header "Setting Up Directories"
    
    # Create required directories
    mkdir -p documents data/{chromadb,logs,backups} static
    
    # Set proper ownership for rootless containers
    if [ "$EUID" -ne 0 ]; then
        chown -R $(id -u):$(id -g) data/ documents/ 2>/dev/null || true
    fi
    
    # Set SELinux contexts for RHEL (if SELinux is enabled)
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
        log_info "Setting SELinux contexts for container volumes..."
        sudo semanage fcontext -a -t container_file_t "$(pwd)/data(/.*)?" 2>/dev/null || log_warning "Could not set SELinux contexts"
        sudo semanage fcontext -a -t container_file_t "$(pwd)/documents(/.*)?" 2>/dev/null || log_warning "Could not set SELinux contexts"
        sudo restorecon -R data/ documents/ 2>/dev/null || log_warning "Could not restore SELinux contexts"
    fi
    
    log_success "Directories configured"
}

build_container() {
    log_header "Building Container Image"
    
    # Check if required files exist
    if [ ! -f "main.py" ]; then
        log_error "main.py not found. Please ensure all required files are present."
        exit 1
    fi
    
    if [ ! -f "requirements.txt" ]; then
        log_error "requirements.txt not found. Please ensure all required files are present."
        exit 1
    fi
    
    if [ ! -f "Containerfile" ]; then
        log_error "Containerfile not found. Please ensure all required files are present."
        exit 1
    fi
    
    # Build image
    log_info "Building container image..."
    if ! podman build -t "$IMAGE_NAME" -f Containerfile .; then
        log_error "Container build failed"
        return 1
    fi
    
    log_success "Container image built successfully"
    return 0
}

deploy_container() {
    log_header "Deploying Container"
    
    # Stop and remove existing container
    log_info "Stopping any existing container..."
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Determine best network configuration
    log_info "Configuring container networking..."
    NETWORK_CMD=""
    
    # Try different network backends in order of preference
    if podman network ls 2>/dev/null | grep -q pasta; then
        log_info "Using pasta networking (recommended for RHEL 9)"
        NETWORK_CMD="--network=pasta"
    elif command -v slirp4netns >/dev/null 2>&1; then
        log_info "Using slirp4netns networking"
        NETWORK_CMD="--network=slirp4netns"
    else
        log_info "Using default Podman networking"
        NETWORK_CMD=""
    fi
    
    # Construct the run command
    if [ -n "$NETWORK_CMD" ]; then
        PODMAN_CMD="podman run -d \
            --name $CONTAINER_NAME \
            $NETWORK_CMD \
            --publish $PORT:8080 \
            --volume $(pwd)/documents:/app/documents:Z \
            --volume $(pwd)/data/chromadb:/app/chromadb:Z \
            --volume $(pwd)/data/logs:/app/logs:Z \
            --env-file .env \
            --restart unless-stopped \
            --memory 4g \
            --cpus 2.0 \
            $IMAGE_NAME"
    else
        PODMAN_CMD="podman run -d \
            --name $CONTAINER_NAME \
            --publish $PORT:8080 \
            --volume $(pwd)/documents:/app/documents:Z \
            --volume $(pwd)/data/chromadb:/app/chromadb:Z \
            --volume $(pwd)/data/logs:/app/logs:Z \
            --env-file .env \
            --restart unless-stopped \
            --memory 4g \
            --cpus 2.0 \
            $IMAGE_NAME"
    fi
    
    log_info "Running: $PODMAN_CMD"
    
    if eval "$PODMAN_CMD"; then
        log_success "Container deployed successfully"
    else
        log_error "Container start failed. Trying with minimal configuration..."
        
        # Fallback: try with minimal settings
        log_info "Attempting fallback deployment..."
        if podman run -d \
            --name "$CONTAINER_NAME" \
            --publish "$PORT:8080" \
            --volume "$(pwd)/documents:/app/documents:Z" \
            --volume "$(pwd)/data/chromadb:/app/chromadb:Z" \
            --volume "$(pwd)/data/logs:/app/logs:Z" \
            --env-file .env \
            --memory 2g \
            "$IMAGE_NAME"; then
            
            log_success "Fallback deployment succeeded"
        else
            log_error "Container deployment failed completely"
            return 1
        fi
    fi
    
    # Verify container is running
    sleep 2
    if ! podman ps | grep -q "$CONTAINER_NAME"; then
        log_error "Container stopped unexpectedly. Check logs:"
        podman logs "$CONTAINER_NAME"
        return 1
    fi
    
    return 0
}

wait_for_service() {
    log_header "Waiting for Service to Start"
    
    # First check if container is running
    if ! podman ps | grep -q "$CONTAINER_NAME"; then
        log_error "Container is not running!"
        podman ps -a | grep "$CONTAINER_NAME"
        return 1
    fi
    
    log_info "Container is running, testing service availability..."
    
    # Try multiple connection methods
    for i in {1..30}; do
        # Test localhost connection
        if curl -s --max-time 5 http://localhost:$PORT/health >/dev/null 2>&1; then
            log_success "Service is ready via localhost!"
            return 0
        fi
        
        # Test 127.0.0.1 connection  
        if curl -s --max-time 5 http://127.0.0.1:$PORT/health >/dev/null 2>&1; then
            log_success "Service is ready via 127.0.0.1!"
            return 0
        fi
        
        # Test container internal check
        if podman exec "$CONTAINER_NAME" curl -s --max-time 5 http://localhost:8080/health >/dev/null 2>&1; then
            log_info "Service is running inside container, checking port forwarding..."
            
            # Check if port is properly forwarded
            if command -v ss >/dev/null 2>&1 && ss -tuln | grep -q ":$PORT "; then
                log_success "Port forwarding is active!"
                return 0
            else
                log_warning "Port forwarding issue detected"
            fi
        fi
        
        if [ $i -eq 30 ]; then
            log_error "Service failed to start or is not accessible"
            return 1
        fi
        
        # Progress indicator
        case $((i % 4)) in
            0) echo -n "🌐 " ;;
            1) echo -n "🔄 " ;;
            2) echo -n "⏳ " ;;
            3) echo -n "🔍 " ;;
        esac
        
        sleep 2
    done
    echo ""
    return 1
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
    echo "   3. Try example searches like 'Podman configuration' or 'RHEL installation'"
    
    echo ""
    echo -e "${GREEN}✅ System Status:${NC}"
    podman ps --filter name=$CONTAINER_NAME --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

show_diagnostics() {
    echo ""
    echo -e "${YELLOW}🔧 Troubleshooting Information:${NC}"
    echo ""
    echo "=== Container Status ==="
    podman ps -a | grep "$CONTAINER_NAME" || echo "No container found"
    
    echo ""
    echo "=== Container Logs ==="
    podman logs --tail 20 "$CONTAINER_NAME" 2>/dev/null || echo "No logs available"
    
    echo ""
    echo "=== Port Status ==="
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep ":$PORT " || echo "Port $PORT not bound"
    else
        echo "ss command not available"
    fi
    
    echo ""
    echo "=== Network Info ==="
    podman inspect "$CONTAINER_NAME" 2>/dev/null | grep -A 10 -B 5 -i network || echo "Network info unavailable"
}

main() {
    log_header "Red Hat Documentation RAG - Podman Deployment"
    echo "Optimized for RHEL 9 with Python 3.12 and Podman"
    echo ""
    
    # Check if required files exist
    if [ ! -f ".env" ]; then
        log_warning ".env file not found. Creating default configuration..."
        cat > .env << 'EOF'
DOCUMENTS_DIR=/app/documents
CHROMA_DB_PATH=/app/chromadb
EMBEDDING_MODEL=all-MiniLM-L6-v2
CHUNK_SIZE=500
CHUNK_OVERLAP=50
MAX_RESULTS=20
MIN_CONFIDENCE=0.3
LOG_LEVEL=INFO
EOF
        log_success "Created default .env file"
    fi
    
    # Run all deployment steps
    check_prerequisites
    
    if ! check_network_config; then
        log_warning "Network configuration issues detected, but continuing..."
    fi
    
    create_directories
    
    if ! build_container; then
        log_error "Container build failed. Please check your files and try again."
        exit 1
    fi
    
    if ! deploy_container; then
        log_error "Container deployment failed."
        show_diagnostics
        exit 1
    fi
    
    if ! wait_for_service; then
        log_error "Service failed to start properly."
        show_diagnostics
        exit 1
    fi
    
    show_completion_info
    
    echo ""
    log_success "🎉 Deployment completed successfully!"
    echo ""
}

# Run main function
main "$@"
