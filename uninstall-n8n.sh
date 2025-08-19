#!/bin/bash
#
# n8n Uninstall Script (uninstall_n8n.bash)
# Version: 1.0.0
#
# DESCRIPTION
# ---------------------------------------------------------------------
# This script safely uninstalls n8n and all related components while
# checking for dependencies used by other processes. It will:
#
# 1. Stop all n8n processes and containers
# 2. Remove Docker containers, volumes, and images (if not used elsewhere)
# 3. Remove Nginx configurations and SSL certificates
# 4. Remove cron jobs for SSL renewal
# 5. Clean up Docker and Docker Compose (if not used by other services)
# 6. Remove swap file (if created by n8n installation)
# 7. Clean up system packages (if not used by other services)
# 8. Remove installation files and logs
#
# SAFETY FEATURES
# - Checks for other Docker containers before removing Docker
# - Checks for other Nginx sites before removing Nginx
# - Backs up important data before deletion
# - Provides detailed logging of all actions
# - Allows selective uninstallation of components
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Function to create backup directory
create_backup_dir() {
    local backup_dir="/tmp/n8n_uninstall_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "$backup_dir"
}

# Function to backup n8n data
backup_n8n_data() {
    local backup_dir=$1

    log "Creating backup of n8n data..."

    # Backup Docker volumes
    if docker volume ls | grep -q "n8n_data\|n8n_n8n_data"; then
        log "Backing up n8n Docker volumes..."
        mkdir -p "$backup_dir/docker_volumes"

        # Create temporary container to access volume data
        if docker volume ls | grep -q "n8n_data"; then
            docker run --rm -v n8n_data:/data -v "$backup_dir/docker_volumes":/backup alpine tar czf /backup/n8n_data.tar.gz -C /data . 2>/dev/null || true
        fi

        if docker volume ls | grep -q "n8n_n8n_data"; then
            docker run --rm -v n8n_n8n_data:/data -v "$backup_dir/docker_volumes":/backup alpine tar czf /backup/n8n_n8n_data.tar.gz -C /data . 2>/dev/null || true
        fi
    fi

    # Backup docker-compose.yml if exists
    if [[ -f "docker-compose.yml" ]]; then
        cp docker-compose.yml "$backup_dir/"
        log "Backed up docker-compose.yml"
    fi

    # Backup Nginx configuration
    if [[ -f "/etc/nginx/sites-available/n8n" ]]; then
        mkdir -p "$backup_dir/nginx"
        cp /etc/nginx/sites-available/n8n "$backup_dir/nginx/"
        log "Backed up Nginx configuration"
    fi

    log "Backup created at: $backup_dir"
    log "You can restore data from this backup if needed"
}

# Function to stop n8n processes
stop_n8n_processes() {
    log "Stopping n8n processes..."

    # Stop Docker Compose services
    if [[ -f "docker-compose.yml" ]]; then
        log "Stopping docker-compose services..."
        docker-compose down -v --remove-orphans 2>/dev/null || true
    fi

    # Stop any running n8n containers
    local n8n_containers=$(docker ps -aq --filter "name=n8n" 2>/dev/null || true)
    if [[ -n "$n8n_containers" ]]; then
        log "Stopping n8n containers..."
        echo "$n8n_containers" | xargs -r docker stop
        echo "$n8n_containers" | xargs -r docker rm
    fi

    # Stop containers using n8n image
    local n8n_image_containers=$(docker ps -aq --filter "ancestor=n8nio/n8n" 2>/dev/null || true)
    if [[ -n "$n8n_image_containers" ]]; then
        log "Stopping containers using n8n image..."
        echo "$n8n_image_containers" | xargs -r docker stop
        echo "$n8n_image_containers" | xargs -r docker rm
    fi

    # Kill any processes using port 5678
    local pids=$(sudo lsof -t -i:5678 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        log "Terminating processes using port 5678..."
        echo "$pids" | xargs -r sudo kill -9
    fi

    log "All n8n processes stopped"
}

# Function to remove Docker resources
remove_docker_resources() {
    log "Removing n8n Docker resources..."

    # Remove n8n volumes
    local volumes=$(docker volume ls -q | grep -E "n8n|n8n_data" 2>/dev/null || true)
    if [[ -n "$volumes" ]]; then
        log "Removing n8n Docker volumes..."
        echo "$volumes" | xargs -r docker volume rm 2>/dev/null || true
    fi

    # Remove n8n images
    local images=$(docker images -q n8nio/n8n 2>/dev/null || true)
    if [[ -n "$images" ]]; then
        log "Removing n8n Docker images..."
        echo "$images" | xargs -r docker rmi -f 2>/dev/null || true
    fi

    # Clean up unused Docker resources
    docker system prune -f 2>/dev/null || true

    log "Docker resources cleaned up"
}

# Function to check if Docker is used by other services
check_docker_usage() {
    local other_containers=$(docker ps -aq --filter "name!=n8n" 2>/dev/null | wc -l)
    local other_images=$(docker images -q | grep -v $(docker images -q n8nio/n8n 2>/dev/null || echo "none") 2>/dev/null | wc -l)

    if [[ $other_containers -gt 0 ]] || [[ $other_images -gt 0 ]]; then
        return 0  # Docker is used by other services
    else
        return 1  # Docker is not used by other services
    fi
}

# Function to remove Docker and Docker Compose
remove_docker_system() {
    if check_docker_usage; then
        warn "Docker is being used by other containers/images. Skipping Docker removal."
        return 0
    fi

    read -p "Docker appears to be used only by n8n. Remove Docker completely? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Keeping Docker installed"
        return 0
    fi

    log "Removing Docker and Docker Compose..."

    # Stop Docker service
    sudo systemctl stop docker 2>/dev/null || true
    sudo systemctl disable docker 2>/dev/null || true

    # Remove Docker packages
    sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
    sudo apt-get remove -y docker-compose 2>/dev/null || true

    # Remove Docker Compose binary
    sudo rm -f /usr/local/bin/docker-compose

    # Remove Docker directories
    sudo rm -rf /var/lib/docker
    sudo rm -rf /etc/docker
    sudo rm -rf ~/.docker

    # Remove Docker group
    sudo groupdel docker 2>/dev/null || true

    # Remove Docker repository
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg

    log "Docker and Docker Compose removed"
}

# Function to check if Nginx is used by other sites
check_nginx_usage() {
    local other_sites=$(find /etc/nginx/sites-enabled/ -name "*" ! -name "n8n" ! -name "default" 2>/dev/null | wc -l)
    local other_configs=$(find /etc/nginx/sites-available/ -name "*" ! -name "n8n" ! -name "default" 2>/dev/null | wc -l)

    if [[ $other_sites -gt 0 ]] || [[ $other_configs -gt 0 ]]; then
        return 0  # Nginx is used by other sites
    else
        return 1  # Nginx is not used by other sites
    fi
}

# Function to remove Nginx configuration and SSL certificates
remove_nginx_config() {
    log "Removing Nginx configuration..."

    # Get domain from nginx config
    local domain=""
    if [[ -f "/etc/nginx/sites-available/n8n" ]]; then
        domain=$(grep "server_name" /etc/nginx/sites-available/n8n | head -1 | awk '{print $2}' | sed 's/;//g')
    fi

    # Remove n8n site configuration
    sudo rm -f /etc/nginx/sites-available/n8n
    sudo rm -f /etc/nginx/sites-enabled/n8n

    # Remove SSL certificates
    if [[ -n "$domain" ]] && [[ -d "/etc/letsencrypt/live/$domain" ]]; then
        log "Removing SSL certificates for $domain..."
        sudo certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi

    # Check if Nginx is used by other sites
    if check_nginx_usage; then
        warn "Nginx is being used by other sites."
        read -p "Force remove Nginx anyway? This will affect other sites! (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Force removing Nginx..."
            sudo systemctl stop nginx 2>/dev/null || true
            sudo systemctl disable nginx 2>/dev/null || true
            sudo pkill -f nginx 2>/dev/null || true
            sudo apt-get purge -y nginx nginx-common nginx-core nginx-full nginx-light 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true
            sudo rm -rf /etc/nginx
            sudo rm -rf /var/log/nginx
            sudo rm -rf /var/www/html
            log "Nginx forcefully removed"
        else
            log "Keeping Nginx installed"
            # Just reload nginx to apply config changes
            sudo systemctl reload nginx 2>/dev/null || true
        fi
    else
        read -p "Nginx appears to be used only by n8n. Remove Nginx completely? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Removing Nginx..."
            sudo systemctl stop nginx 2>/dev/null || true
            sudo systemctl disable nginx 2>/dev/null || true
            sudo pkill -f nginx 2>/dev/null || true
            sudo apt-get purge -y nginx nginx-common nginx-core nginx-full nginx-light 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true
            sudo rm -rf /etc/nginx
            sudo rm -rf /var/log/nginx
            sudo rm -rf /var/www/html
            log "Nginx removed"
        else
            log "Keeping Nginx installed"
            # Restore default site if no other sites exist
            if [[ ! -f "/etc/nginx/sites-enabled/default" ]] && [[ -f "/etc/nginx/sites-available/default" ]]; then
                sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
            fi
            sudo systemctl reload nginx 2>/dev/null || true
        fi
    fi

    log "Nginx configuration cleaned up"
}

# Function to remove Certbot and related packages
remove_certbot() {
    if check_nginx_usage; then
        warn "Other Nginx sites detected. Keeping Certbot installed."
        return 0
    fi

    # Check if there are other SSL certificates
    local other_certs=$(sudo certbot certificates 2>/dev/null | grep -c "Certificate Name:" || echo "0")

    if [[ $other_certs -gt 0 ]]; then
        warn "Other SSL certificates found. Keeping Certbot installed."
        return 0
    fi

    read -p "Remove Certbot (SSL certificate manager)? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing Certbot..."
        sudo apt-get remove -y certbot python3-certbot-nginx 2>/dev/null || true
        sudo rm -rf /etc/letsencrypt
        sudo rm -rf /var/lib/letsencrypt
        sudo rm -rf /var/log/letsencrypt
        log "Certbot removed"
    else
        log "Keeping Certbot installed"
    fi
}

# Function to remove cron jobs
remove_cron_jobs() {
    log "Removing n8n-related cron jobs..."

    # Remove certbot renewal cron job
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "certbot renew" > "$temp_cron" || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"

    # Remove any other n8n-related cron jobs
    temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v -i "n8n" > "$temp_cron" || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"

    log "Cron jobs cleaned up"
}

# Function to remove swap file (if created by n8n installation)
remove_swap_file() {
    if [[ ! -f /swapfile ]]; then
        log "No swap file found"
        return 0
    fi

    # Check if swap file was likely created by our installation
    # (This is a heuristic - we check if it's exactly 1GB, 2GB, 4GB, or 8GB)
    local swap_size=$(stat -c%s /swapfile 2>/dev/null | awk '{print int($1/1024/1024/1024)}')

    if [[ $swap_size -eq 1 ]] || [[ $swap_size -eq 2 ]] || [[ $swap_size -eq 4 ]] || [[ $swap_size -eq 8 ]]; then
        read -p "Remove swap file (/swapfile - ${swap_size}GB)? This may have been created by n8n installation (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Removing swap file..."
            sudo swapoff /swapfile 2>/dev/null || true
            sudo rm -f /swapfile

            # Remove from fstab
            sudo sed -i '/\/swapfile/d' /etc/fstab

            # Remove swap-related sysctl settings
            sudo sed -i '/vm.swappiness/d' /etc/sysctl.conf
            sudo sed -i '/vm.vfs_cache_pressure/d' /etc/sysctl.conf

            log "Swap file removed"
        else
            log "Keeping swap file"
        fi
    else
        warn "Swap file size (${swap_size}GB) doesn't match typical n8n installation. Skipping removal."
    fi
}
# Optional: Securely refresh swap (wipe and recreate)
secure_swap_refresh() {
    if [[ ! -f /swapfile ]]; then
        warn "No /swapfile present. Skipping secure swap refresh."
        return 0
    fi

    # Determine current swap size in MiB
    local swap_bytes=$(stat -c%s /swapfile 2>/dev/null || echo 0)
    local swap_mib=$(( swap_bytes / 1024 / 1024 ))
    if [[ $swap_mib -le 0 ]]; then
        warn "Unable to determine swapfile size. Skipping secure swap refresh."
        return 0
    fi

    echo
    warn "Secure swap refresh will temporarily disable swap, wipe the swapfile, recreate it, and re-enable swap."
    warn "Ensure you have sufficient free RAM to hold all memory without swapping during this process."
    read -p "Proceed with secure swap refresh now? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Skipping secure swap refresh."
        return 0
    fi

    log "Disabling swap..."
    sudo swapoff /swapfile 2>/dev/null || true

    log "Wiping swapfile securely (this can take a while)..."
    # Use shred to overwrite the file securely, fall back to dd if shred is unavailable
    if command -v shred >/dev/null 2>&1; then
        sudo shred -u -n 1 -z /swapfile
    else
        sudo dd if=/dev/zero of=/swapfile bs=1M count=$swap_mib status=progress conv=fsync 2>/dev/null || true
        sudo rm -f /swapfile
    fi

    log "Recreating swapfile (${swap_mib} MiB)..."
    sudo fallocate -l ${swap_mib}M /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=$swap_mib status=progress conv=fsync
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null

    # Ensure fstab entry exists or is correct
    if ! grep -qE '^/swapfile\s' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    fi

    log "Re-enabling swap..."
    sudo swapon /swapfile

    # Re-apply conservative defaults
    if ! grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf >/dev/null
    fi
    if ! grep -q '^vm.vfs_cache_pressure' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf >/dev/null
    fi
    sudo sysctl -p >/dev/null 2>&1 || true

    log "Secure swap refresh completed."
}


# Function to remove installation files
remove_installation_files() {
    log "Removing installation files..."

    # Remove docker-compose.yml
    if [[ -f "docker-compose.yml" ]]; then
        rm -f docker-compose.yml
        log "Removed docker-compose.yml"
    fi

    # Remove any n8n installation scripts
    find . -name "*n8n*install*" -type f -delete 2>/dev/null || true
    find . -name "install_n8n*" -type f -delete 2>/dev/null || true

    log "Installation files cleaned up"
}

# Function to clean up system packages
cleanup_system_packages() {
    log "Cleaning up system packages..."

    # Remove packages that were likely installed only for n8n
    local packages_to_check=("dnsutils")
    local packages_to_remove=()

    for package in "${packages_to_check[@]}"; do
        if dpkg -l | grep -q "^ii.*$package "; then
            # Check if package is used by other software (basic check)
            read -p "Remove $package? It may have been installed for n8n (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                packages_to_remove+=("$package")
            fi
        fi
    done

    if [[ ${#packages_to_remove[@]} -gt 0 ]]; then
        sudo apt-get remove -y "${packages_to_remove[@]}" 2>/dev/null || true
        log "Removed packages: ${packages_to_remove[*]}"
    fi

    # Clean up package cache
    sudo apt-get autoremove -y 2>/dev/null || true
    sudo apt-get autoclean 2>/dev/null || true

    log "System packages cleaned up"
}

# Function to display final status
display_final_status() {
    log "n8n uninstallation completed!"
    echo
    echo "=================================="
    echo "Uninstallation Summary"
    echo "=================================="
    echo "✅ n8n processes stopped"
    echo "✅ Docker containers and volumes removed"
    echo "✅ Nginx configuration cleaned up"
    echo "✅ SSL certificates removed"
    echo "✅ Cron jobs cleaned up"
    echo "✅ Installation files removed"
    echo

    # Check what's still installed
    echo "Remaining components:"
    if command -v docker &> /dev/null; then
        echo "• Docker: Still installed"
    else
        echo "• Docker: Removed"
    fi

    if command -v nginx &> /dev/null; then
        echo "• Nginx: Still installed"
    else
        echo "• Nginx: Removed"
    fi

    if command -v certbot &> /dev/null; then
        echo "• Certbot: Still installed"
    else
        echo "• Certbot: Removed"
    fi

    if [[ -f /swapfile ]]; then
        echo "• Swap file: Still present"
    else
        echo "• Swap file: Removed"
    fi

    echo
    echo "Backup location: $1"
    echo "=================================="
}

# Function to show uninstall options
show_uninstall_options() {
    echo
    echo "=================================="
    echo "n8n Uninstall Options"
    echo "=================================="
    echo "This script will:"
    echo "1. Stop all n8n processes and containers"
    echo "2. Create a backup of your n8n data"
    echo "3. Remove n8n Docker resources"
    echo "4. Clean up Nginx configuration and SSL certificates"
    echo "5. Remove related cron jobs"
    echo "6. Optionally remove Docker, Nginx, and other components"
    echo "7. Clean up installation files"
    echo
    echo "Backup details:"
    echo "• A timestamped backup will be created at:"
    echo "  /tmp/n8n_uninstall_backup_YYYYMMDD_HHMMSS"
    echo "• Contents may include:"
    echo "  - docker_volumes: archives of n8n volumes (n8n_data.tar.gz, n8n_n8n_data.tar.gz)"
    echo "  - docker-compose.yml: your compose file if found"
    echo "  - nginx/n8n: nginx site configuration if found"
    echo
    echo "How to restore from this backup (manual):"
    echo "1) Stop any running n8n containers:"
    echo "   docker-compose down -v --remove-orphans 2>/dev/null || true"
    echo "2) Restore docker-compose.yml (if needed):"
    echo "   cp /tmp/n8n_uninstall_backup_YYYYMMDD_HHMMSS/docker-compose.yml ./"
    echo "3) Restore volumes (if needed):"
    echo "   docker volume create n8n_data"
    echo "   docker run --rm -v n8n_data:/data -v /tmp/n8n_uninstall_backup_YYYYMMDD_HHMMSS/docker_volumes:/backup alpine sh -c \"cd /data && tar xzf /backup/n8n_data.tar.gz\""
    echo "   (If you have n8n_n8n_data.tar.gz, repeat with that volume name)"
    echo "4) Restore nginx config (optional):"
    echo "   sudo cp /tmp/n8n_uninstall_backup_YYYYMMDD_HHMMSS/nginx/n8n /etc/nginx/sites-available/n8n"
    echo "   sudo ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n && sudo systemctl reload nginx"
    echo "5) Start n8n:"
    echo "   docker-compose up -d"
    echo
    echo "⚠️ WARNING: This will permanently remove n8n and its data from this system."
    echo "   A backup is created as described above, but ensure you have your own backups as well."
    echo
    read -p "Do you want to proceed with the uninstallation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Uninstallation cancelled."
        exit 0
    fi
}

# Main uninstallation process
main() {
    log "Starting n8n uninstallation process..."

    # Show options and get confirmation
    show_uninstall_options

    # Create backup directory
    local backup_dir=$(create_backup_dir)

    # Backup n8n data
    backup_n8n_data "$backup_dir"

    # Stop all n8n processes
    stop_n8n_processes

    # Remove Docker resources
    remove_docker_resources

    # Remove Nginx configuration and SSL certificates
    remove_nginx_config

    # Remove Certbot if not needed
    remove_certbot

    # Remove cron jobs
    remove_cron_jobs

    # Optional secure swap refresh (wipe and recreate without removing)
    secure_swap_refresh

    # Remove swap file if appropriate
    remove_swap_file

    # Remove installation files
    remove_installation_files

    # Clean up system packages
    cleanup_system_packages

    # Optionally remove Docker system
    remove_docker_system

    # Display final status
    display_final_status "$backup_dir"

    log "n8n has been successfully uninstalled!"
}

# Run main function
main "$@"


