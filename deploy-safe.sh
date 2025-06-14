#!/bin/bash
# Network-safe deployment script for Red Hat RAG
# This script monitors network status and stops if connectivity is lost

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_header() { echo -e "${CYAN}🛡️  $1${NC}"; }

# Network monitoring functions
check_network() {
    # Test multiple connectivity methods
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || return 1
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || return 1
    curl -s --max-time 5 http://httpbin.org/ip >/dev/null 2>&1 || return 1
    return 0
}

network_monitor() {
    local operation="$1"
    local pid="$2"
    
    log_info "Monitoring network during: $operation"
    
    while kill -0 "$pid" 2>/dev/null; do
        if ! check_network; then
            log_error "Network connectivity lost during $operation!"
            log_error "Terminating operation to prevent further network issues..."
            kill "$pid" 2>/dev/null || true
            
            # Try to restore network
            log_info "Attempting network recovery..."
            sudo systemctl restart NetworkManager 2>/dev/null || true
            sleep 5
            
            if check_network; then
                log_success "Network connectivity restored"
            else
                log_error "Network connectivity still lost - manual intervention required"
                echo ""
                echo "🔧 Network recovery steps:"
                echo "1. sudo systemctl restart NetworkManager"
                echo "2. sudo systemctl restart podman"
                echo "3. Check: ip link show"
                echo "4. Check: sudo dmesg | tail -20"
            fi
            
            exit 1
        fi
        sleep 2
    done
}

# Pre-flight network check
log_header "Network-Safe Red Hat RAG Deployment"
echo "====================================="

log_info "Pre-flight network connectivity check..."
if ! check_network; then
    log_error "Network connectivity issues detected before starting"
    exit 1
fi
log_success "Network connectivity verified"

# Create backup of network configuration
log_info "Creating network configuration backup..."
mkdir -p backups
sudo cp /etc/NetworkManager/NetworkManager.conf backups/ 2>/dev/null || true
ip route show > backups/routes.backup 2>/dev/null || true
ip addr show > backups/interfaces.backup 2>/dev/null || true

# Check Podman network configuration
log_info "Checking Podman network configuration..."
if podman network ls >/dev/null 2>&1; then
    log_success "Podman network accessible"
else
    log_warning "Podman network issues detected"
fi

# Configure Podman for minimal network impact
log_info "Configuring Podman for network safety..."
mkdir -p ~/.config/containers

cat > ~/.config/containers/containers.conf << 'EOF'
[containers]
# Network-safe configuration
network_cmd_options = ["--ip-masq=false"]
netns = "private"

[engine]
# Limit concurrent operations
max_parallel_downloads = 1
events_logger = "file"

[network]
network_backend = "netavark"
default_network = "podman"
dns_bind_port = 0
EOF

# Option 1: Try local development first (safest)
log_header "Option 1: Local Development (Network-Safe)"
echo ""
read -p "Would you like to try local development first (no containers, network-safe)? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$|^$ ]]; then
    log_info "Starting local development setup..."
    
    # Run local setup with network monitoring
    if [ -x "./run-local.sh" ]; then
        ./run-local.sh
    else
        log_info "Setting up local development environment..."
        
        # Create virtual environment
        python3 -m venv venv
        source venv/bin/activate
        
        # Install minimal packages with network monitoring
        log_info "Installing Python packages (monitoring network)..."
        pip install --timeout=60 fastapi uvicorn pydantic python-multipart python-dotenv &
        PIP_PID=$!
        
        # Monitor network during pip install
        network_monitor "pip install" $PIP_PID &
        MONITOR_PID=$!
        
        wait $PIP_PID
        kill $MONITOR_PID 2>/dev/null || true
        
        if check_network; then
            log_success "Local setup completed successfully"
            
            # Create directories
            mkdir -p documents chromadb logs static
            
            # Start the application
            log_info "Starting local application..."
            echo ""
            echo "🌐 Starting Red Hat RAG locally at http://localhost:8000"
            echo "📁 Add PDF files to: documents/"
            echo "🛑 Press Ctrl+C to stop"
            echo ""
            python main.py
        else
            log_error "Network lost during pip install"
        fi
    fi
    
    exit 0
fi

# Option 2: Pre-built container approach
log_header "Option 2: Pre-built Container (Network-Safe)"
echo ""
read -p "Would you like to try using a pre-built container? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Attempting to use pre-built Python container..."
    
    # Use a simple Python container and copy files
    log_info "Pulling lightweight Python container..."
    podman pull python:3.12-alpine &
    PULL_PID=$!
    
    # Monitor network during pull
    network_monitor "container pull" $PULL_PID &
    MONITOR_PID=$!
    
    wait $PULL_PID
    kill $MONITOR_PID 2>/dev/null || true
    
    if check_network; then
        log_success "Container pulled successfully"
        
        # Create and run container
        log_info "Creating application container..."
        
        # Stop any existing container
        podman stop redhat-rag 2>/dev/null || true
        podman rm redhat-rag 2>/dev/null || true
        
        # Create directories
        mkdir -p documents data/{chromadb,logs}
        
        # Run container with minimal network access
        podman run -d \
            --name redhat-rag \
            --publish 127.0.0.1:8080:8080 \
            --volume "$(pwd):/app:Z" \
            --workdir /app \
            --network=slirp4netns \
            --dns=8.8.8.8 \
            python:3.12-alpine \
            sh -c "pip install fastapi uvicorn pydantic python-multipart && python main.py"
        
        if check_network; then
            log_success "Container deployment successful!"
            echo ""
            echo "🌐 Access at: http://localhost:8080"
            echo "📋 Check status: podman logs redhat-rag"
        else
            log_error "Network lost during container deployment"
        fi
    else
        log_error "Network lost during container pull"
    fi
    
    exit 0
fi

# Option 3: Diagnostic mode
log_header "Option 3: Network Diagnostic Mode"
echo ""
log_warning "Running in diagnostic mode to identify network issues..."

# Create comprehensive diagnostic script
cat > diagnose-network-issue.sh << 'EOF'
#!/bin/bash
# Diagnose what's causing network loss during deployment

set -e

echo "🔍 Network Issue Diagnostic Report"
echo "=================================="
echo "Timestamp: $(date)"
echo ""

echo "📊 System Information:"
echo "OS: $(cat /etc/redhat-release 2>/dev/null || echo 'Unknown')"
echo "Kernel: $(uname -r)"
echo "Podman: $(podman --version 2>/dev/null || echo 'Not installed')"
echo ""

echo "🌐 Network Configuration:"
echo "Interfaces:"
ip link show | grep -E '^[0-9]+:' | sed 's/^/  /'
echo ""
echo "Routes:"
ip route show | sed 's/^/  /'
echo ""
echo "DNS:"
cat /etc/resolv.conf | sed 's/^/  /'
echo ""

echo "🔧 NetworkManager Status:"
systemctl status NetworkManager --no-pager -l | sed 's/^/  /'
echo ""

echo "🐳 Podman Network Configuration:"
podman network ls 2>/dev/null | sed 's/^/  /' || echo "  Podman not accessible"
echo ""

echo "🔥 Firewall Status:"
firewall-cmd --list-all 2>/dev/null | sed 's/^/  /' || echo "  Firewall not accessible"
echo ""

echo "📝 Recent System Logs (network related):"
journalctl -n 50 --no-pager | grep -i -E 'network|podman|container' | tail -10 | sed 's/^/  /'
echo ""

echo "💾 Memory and Resource Usage:"
free -h | sed 's/^/  /'
echo ""
df -h / | sed 's/^/  /'
echo ""

echo "🔍 Potential Issues to Check:"
echo "1. Is NetworkManager conflicting with Podman?"
echo "2. Are iptables rules being modified incorrectly?"
echo "3. Is there insufficient memory causing network stack issues?"
echo "4. Are there SELinux denials blocking network access?"
echo "5. Is DNS being overwhelmed by build requests?"
echo ""

echo "🛠️  Recommended Actions:"
echo "1. Try local development: ./run-local.sh"
echo "2. Check system resources before deployment"
echo "3. Monitor network interfaces during deployment"
echo "4. Consider updating NetworkManager"
echo "5. Review Podman network configuration"
EOF

chmod +x diagnose-network-issue.sh
./diagnose-network-issue.sh > network-diagnostic-report.txt

log_success "Diagnostic report created: network-diagnostic-report.txt"
echo ""
echo "📋 Immediate recommendations:"
echo ""
echo "1. **Use local development (safest):**"
echo "   ./run-local.sh"
echo ""
echo "2. **Check the diagnostic report:**"
echo "   cat network-diagnostic-report.txt"
echo ""
echo "3. **Try system network reset:**"
echo "   sudo systemctl restart NetworkManager"
echo "   sudo systemctl restart podman"
echo ""
echo "4. **Monitor system resources:**"
echo "   htop  # Check if memory/CPU exhaustion is causing network issues"
echo ""
echo "⚠️  AVOID running the standard deploy script until this is resolved!"
echo ""
echo "🔧 Common causes of this issue:"
echo "• Podman network configuration conflicts"
echo "• iptables/firewall rule corruption"
echo "• NetworkManager/Podman integration issues"
echo "• Resource exhaustion (memory/CPU)"
echo "• DNS resolver overload"
echo "• SELinux policy conflicts"
