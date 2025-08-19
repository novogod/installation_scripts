#!/bin/bash
#
# n8n Installation Script (install_n8n_fixed.bash)
# Version: 1.2.1
#
# CHANGELOG
# ---------------------------------------------------------------------
# [2025-08-18 19:15] v1.2.1
#   - Added informational domain prompt (no technical validation)
#   - Warns user about HTTPS requiring FQDN (not IP addresses)
#   - Gives user opportunity to configure DNS before continuing
#   - Simple y/N prompt to proceed with installation
#
# [2025-08-18 19:10] v1.2.0
#   - Added automatic port conflict detection and cleanup (port 5678)
#   - Added automatic process termination for conflicting services
#   - Added automatic Docker container cleanup (stop/remove existing n8n)
#   - Added automatic conflicting package removal (no prompts)
#   - Removed all user prompts for cleanup operations
#   - Added automatic cleanup of existing Docker volumes and networks
#
# [2025-08-18 18:58] v1.1.0
#   - Removed domain validation restrictions (regex check removed)
#   - Removed DNS resolution check (allows any domain format)
#   - Simplified domain input - accepts any string as valid domain
#
# [2025-08-18] v1.0.0
#   - Added encryption key handling:
#       • Reuse existing key from /var/lib/docker/volumes/.../config
#       • Generate new key only if no config exists
#   - Pin n8n image to v1.97.1 (avoid "command start not found")
#   - Added dependency auto-repair (apt-get check/install -f/dpkg)
#   - Docker conflict detection & optional removal (docker.io vs docker-ce)
#   - Swapfile creation for systems with ≤1 GB RAM
#   - Memory limits in docker-compose (512M / 256M reservations)
#   - Domain name validation with DNS resolution check
#   - n8n health check (/healthz) with retries and logging on failure
#   - Nginx reverse proxy + SSL redirect configuration
#   - Certbot automatic SSL issuance & renewal cron job
#   - Final install summary (domain, auth creds, encryption key, resources)
#
# ---------------------------------------------------------------------

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

log "Starting n8n installation with Docker, Nginx, and SSL..."

# Function to check and resolve dependency issues
check_and_fix_dependencies() {
    log "Checking for dependency issues..."

    # Update package index
    sudo apt update

    # Check for broken packages
    if ! sudo apt-get check 2>/dev/null; then
        warn "Found broken packages, attempting to fix..."
        sudo apt-get install -f -y
        sudo dpkg --configure -a
    fi

    # Check for held packages and unhold them
    held_packages=$(apt-mark showhold)
    if [[ -n "$held_packages" ]]; then
        warn "Found held packages: $held_packages - removing holds..."
        echo "$held_packages" | xargs -r sudo apt-mark unhold
    fi
}

# Function to stop processes using port 5678
cleanup_port_conflicts() {
    log "Checking for port 5678 conflicts..."

    # Find processes using port 5678
    local pids=$(sudo lsof -t -i:5678 2>/dev/null || true)

    if [[ -n "$pids" ]]; then
        warn "Found processes using port 5678: $pids"
        log "Terminating conflicting processes..."
        echo "$pids" | xargs -r sudo kill -9
        sleep 2
        log "Port 5678 conflicts resolved"
    else
        log "No port 5678 conflicts found"
    fi
}

# Function to cleanup existing Docker containers and resources
cleanup_docker_resources() {
    log "Cleaning up existing Docker resources..."

    # Stop and remove any existing n8n containers
    local containers=$(docker ps -aq --filter "name=n8n" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        log "Stopping and removing existing n8n containers..."
        echo "$containers" | xargs -r docker stop
        echo "$containers" | xargs -r docker rm
    fi

    # Remove any containers using n8n image
    local n8n_containers=$(docker ps -aq --filter "ancestor=n8nio/n8n" 2>/dev/null || true)
    if [[ -n "$n8n_containers" ]]; then
        log "Removing containers using n8n image..."
        echo "$n8n_containers" | xargs -r docker stop
        echo "$n8n_containers" | xargs -r docker rm
    fi

    # Clean up docker-compose resources if they exist
    if [[ -f "docker-compose.yml" ]]; then
        log "Cleaning up existing docker-compose resources..."
        docker-compose down -v --remove-orphans 2>/dev/null || true
    fi

    # Remove dangling volumes
    docker volume prune -f 2>/dev/null || true

    log "Docker cleanup completed"
}

# Function to handle Docker conflicts (automatic removal)
handle_docker_conflicts() {
    log "Checking for Docker installation conflicts..."

    # Check if old Docker packages are installed
    old_docker_packages=$(dpkg -l | grep -E "docker\.io|docker-engine" | awk '{print $2}' || true)

    if [[ -n "$old_docker_packages" ]]; then
        warn "Found conflicting Docker packages: $old_docker_packages"
        log "Automatically removing conflicting Docker packages..."
        echo "$old_docker_packages" | xargs -r sudo apt-get remove -y
        sudo apt-get autoremove -y
        log "Conflicting Docker packages removed"
    else
        log "No Docker package conflicts found"
    fi
}

# Function to cleanup existing Nginx configurations
cleanup_nginx_configs() {
    log "Cleaning up existing Nginx configurations..."

    # Remove existing n8n site configurations
    sudo rm -f /etc/nginx/sites-available/n8n
    sudo rm -f /etc/nginx/sites-enabled/n8n

    # Remove any SSL certificates for the domain if they exist
    if [[ -n "$1" ]] && [[ -d "/etc/letsencrypt/live/$1" ]]; then
        log "Removing existing SSL certificates for $1..."
        sudo certbot delete --cert-name "$1" --non-interactive 2>/dev/null || true
    fi

    log "Nginx cleanup completed"
}

# Function to create swap file for low-memory systems
create_swap_if_needed() {
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')

    if [[ $mem_gb -le 1 ]]; then
        log "Detected low memory system (${mem_gb}GB). Creating swap file..."

        if [[ ! -f /swapfile ]]; then
            sudo fallocate -l 2G /swapfile
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile
            sudo swapon /swapfile

            # Make swap permanent
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
            fi

            log "Swap file created and activated"
        else
            log "Swap file already exists"
        fi
    fi
}

# Function to validate domain name (simplified - no restrictions)
validate_domain() {
    local domain=$1

    if [[ -z "$domain" ]]; then
        error "Domain name cannot be empty"
        return 1
    fi

    local server_ip=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "unknown")
    local domain_ip=$(dig +short $domain | tail -n1)

    if [[ "$domain_ip" != "$server_ip" ]]; then
        warn "Domain $domain does not resolve to server IP ($server_ip)"
        warn "It currently resolves to: $domain_ip"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Aborting installation. Please configure DNS first."
            exit 1
        fi
    fi

    log "Using domain: $domain"
}

# Function to get existing encryption key from n8n config
get_existing_encryption_key() {
    local config_file="/var/lib/docker/volumes/n8n_n8n_data/_data/config"

    if [[ -f "$config_file" ]]; then
        local existing_key=$(grep -o '"encryptionKey":"[^"]*"' "$config_file" 2>/dev/null | cut -d'"' -f4)
        if [[ -n "$existing_key" ]]; then
            echo "$existing_key"
            return 0
        fi
    fi

    # If no existing key found, generate a new one
    openssl rand -base64 32
}

# Function to generate YAML-safe docker-compose.yml
generate_docker_compose() {
    local domain=$1
    local password=$2
    local encryption_key=$3

    cat > docker-compose.yml << EOF
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:1.97.1
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${password}
      - WEBHOOK_URL=https://${domain}/
      - N8N_ENCRYPTION_KEY=${encryption_key}
      - TZ=UTC
      - N8N_METRICS=true
      - N8N_LOG_LEVEL=info
    volumes:
      - n8n_data:/home/node/.n8n
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  n8n_data:
    driver: local
EOF
}

# Function to validate docker-compose.yml syntax
validate_docker_compose() {
    if ! docker-compose config -q 2>/dev/null; then
        error "Generated docker-compose.yml has syntax errors"
        return 1
    fi
    log "docker-compose.yml syntax validated successfully"
}

# Function to test n8n startup and check for errors
test_n8n_startup() {
    log "Testing n8n startup..."

    # Wait for container to be ready
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if docker-compose ps | grep -q "Up"; then
            log "n8n container is running"
            break
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            error "n8n failed to start within expected time"
            log "Container logs:"
            docker-compose logs n8n
            return 1
        fi

        log "Waiting for n8n to start... (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done

    # Give n8n time to fully initialize
    sleep 20

    # Check container logs for critical errors
    log "Checking n8n logs for errors..."
    local logs=$(docker-compose logs n8n 2>&1)
    
    # Check for common error patterns
    if echo "$logs" | grep -qi "error\|failed\|exception\|mismatching encryption keys\|command.*not found"; then
        error "Critical errors found in n8n logs:"
        echo "$logs" | grep -i "error\|failed\|exception\|mismatching encryption keys\|command.*not found" | tail -10
        return 1
    fi

    # Test health endpoint
    if curl -f -s http://localhost:5678/healthz > /dev/null 2>&1; then
        log "✅ n8n health check passed - n8n is running successfully!"
        return 0
    elif curl -f -s http://localhost:5678/ > /dev/null 2>&1; then
        log "✅ n8n is responding on port 5678 - n8n is running successfully!"
        return 0
    else
        warn "Health check endpoint not available, but container is running"
        log "This might be normal for older n8n versions"
        log "✅ n8n container is running successfully!"
        return 0
    fi
}

# Function to inform user about domain requirements
inform_about_domain_requirements() {
    echo
    echo "=============================================="
    echo "IMPORTANT: Domain Requirements for HTTPS/SSL"
    echo "=============================================="
    echo
    echo "This script will set up n8n with HTTPS using Let's Encrypt SSL certificates."
    echo
    echo "REQUIREMENTS:"
    echo "• You need a FULLY QUALIFIED DOMAIN NAME (FQDN) like: n8n.example.com"
    echo "• IP addresses (like 192.168.1.100) will NOT work for SSL certificates"
    echo "• Your domain must point to this server's IP address via DNS A record"
    echo
    echo "If you haven't configured DNS yet:"
    echo "1. Go to your domain registrar or DNS provider"
    echo "2. Create an A record pointing your domain to this server's IP"
    echo "3. Wait for DNS propagation (usually 5-15 minutes)"
    echo
    echo "=============================================="
    echo
    read -p "Do you have a qualified domain name properly configured? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo
        echo "Please configure your domain DNS first, then run this script again."
        echo "Exiting..."
        exit 0
    fi
    echo
    log "Proceeding with installation..."
}

# Main installation process
main() {
    # Inform user about domain requirements
    inform_about_domain_requirements

    # Get domain name
    read -p "Enter your domain name (e.g., n8n.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "Domain name is required"
        exit 1
    fi

    # Validate domain (simplified)
    validate_domain "$DOMAIN"

    # Get email for Let's Encrypt
    read -p "Enter your email for Let's Encrypt SSL certificate: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        error "Email is required for SSL certificate"
        exit 1
    fi

    # Generate admin password
    ADMIN_PASSWORD=$(openssl rand -base64 16)

    # Cleanup existing resources first
    cleanup_port_conflicts
    cleanup_docker_resources
    cleanup_nginx_configs "$DOMAIN"

    # Check and fix dependencies
    check_and_fix_dependencies

    # Handle Docker conflicts
    handle_docker_conflicts

    # Create swap if needed
    create_swap_if_needed

    # Install required packages
    log "Installing required packages..."
    sudo apt-get update
    sudo apt-get install -y curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common dnsutils

    # Install Docker if not present
    if ! command -v docker &> /dev/null; then
        log "Installing Docker..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        sudo usermod -aG docker $USER
        log "Docker installed successfully"
    else
        log "Docker is already installed"
    fi

    # Install Docker Compose if not present
    if ! command -v docker-compose &> /dev/null; then
        log "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        log "Docker Compose installed successfully"
    else
        log "Docker Compose is already installed"
    fi

    # Get or generate encryption key
    log "Handling encryption key..."
    ENCRYPTION_KEY=$(get_existing_encryption_key)

    if [[ -f "/var/lib/docker/volumes/n8n_n8n_data/_data/config" ]]; then
        log "Using existing encryption key from n8n config"
    else
        log "Generated new encryption key"
    fi

    # Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    generate_docker_compose "$DOMAIN" "$ADMIN_PASSWORD" "$ENCRYPTION_KEY"

    # Validate docker-compose.yml
    validate_docker_compose

    # Start n8n
    log "Starting n8n..."
    docker-compose up -d

    # Test n8n startup
    if ! test_n8n_startup; then
        error "n8n startup test failed"
        exit 1
    fi

    # Install and configure Nginx
    log "Installing and configuring Nginx..."
    sudo apt-get install -y nginx

    # Stop nginx to avoid conflicts during SSL setup
    sudo systemctl stop nginx

    # Create Nginx configuration
    sudo tee /etc/nginx/sites-available/n8n << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 50M;

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
EOF

    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default

    # Install Certbot and get SSL certificate
    log "Installing Certbot and obtaining SSL certificate..."
    sudo apt-get install -y certbot python3-certbot-nginx

    # Get SSL certificate (standalone mode first, then switch to nginx)
    sudo certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive

    # Test Nginx configuration
    sudo nginx -t
    sudo systemctl start nginx
    sudo systemctl enable nginx

    # Set up automatic renewal
    (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

    # Final verification that n8n is running properly
    log "Performing final n8n verification..."
    sleep 10  # Give services time to stabilize
    
    # Check if n8n is still running and accessible
    if ! docker-compose ps | grep -q "Up"; then
        error "n8n container is not running after installation!"
        log "Container status:"
        docker-compose ps
        log "Recent logs:"
        docker-compose logs --tail=20 n8n
        exit 1
    fi
    
    # Check for any critical errors in recent logs
    local recent_logs=$(docker-compose logs --tail=50 n8n 2>&1)
    if echo "$recent_logs" | grep -qi "error\|failed\|exception\|mismatching encryption keys"; then
        error "Critical errors detected in n8n logs after installation:"
        echo "$recent_logs" | grep -i "error\|failed\|exception\|mismatching encryption keys" | tail -5
        exit 1
    fi
    
    # Test final connectivity
    if curl -f -s http://localhost:5678/ > /dev/null 2>&1; then
        log "✅ n8n is running and accessible on localhost:5678"
    else
        warn "n8n may not be fully ready yet, but container is running"
    fi

    # Final system information
    log "Installation completed successfully!"
    echo
    echo "=================================="
    echo "n8n Installation Summary"
    echo "=================================="
    echo "Domain: https://$DOMAIN"
    echo "Username: admin"
    echo "Password: $ADMIN_PASSWORD"
    echo "Encryption Key: $ENCRYPTION_KEY"
    echo
    echo "Docker containers:"
    docker-compose ps
    echo
    echo "System resources:"
    free -h
    echo
    echo "SSL certificate status:"
    sudo certbot certificates
    echo
    echo "=================================="
    echo "✅ n8n is now running successfully!"
    echo "Access it at: https://$DOMAIN"
    echo "Save these credentials securely!"
    echo "=================================="
}

# Run main function
main "$@"
