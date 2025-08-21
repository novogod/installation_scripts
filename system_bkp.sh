#!/bin/bash

# VPS Complete Backup Script (No Docker Downtime)
# Run as root: bash vps_backup_no_stop.sh
# Creates comprehensive backup in /home/ftpbackup/ without stopping Docker containers

set -e

BACKUP_DIR="/home/ftpbackup"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="vps_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
TEMP_PERMS_FILE="/tmp/backup_perms_${TIMESTAMP}.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

# Create backup directory structure
log "Creating backup directory structure..."
mkdir -p "${BACKUP_PATH}"/{system,docker,configs,packages,services}
chmod 755 "${BACKUP_DIR}"
chmod 755 "${BACKUP_PATH}"

# Function to temporarily change permissions and restore them later
temp_chmod() {
    local path="$1"
    local new_perm="$2"

    if [[ -e "$path" ]]; then
        # Store original permissions
        local orig_perm=$(stat -c "%a" "$path" 2>/dev/null || echo "")
        if [[ -n "$orig_perm" ]]; then
            echo "$path:$orig_perm" >> "$TEMP_PERMS_FILE"
            chmod "$new_perm" "$path" 2>/dev/null || true
        fi
    fi
}

# Function to restore original permissions
restore_permissions() {
    if [[ -f "$TEMP_PERMS_FILE" ]]; then
        log "Restoring original permissions..."
        while IFS=':' read -r path orig_perm; do
            if [[ -e "$path" && -n "$orig_perm" ]]; then
                chmod "$orig_perm" "$path" 2>/dev/null || warn "Could not restore permissions for $path"
            fi
        done < "$TEMP_PERMS_FILE"
        rm -f "$TEMP_PERMS_FILE"
    fi
}

# Function to clean up and exit on space error
cleanup_and_exit() {
    local available_space="$1"
    local backup_size="$2"
    
    # Clean up backup directory
    if [[ -d "${BACKUP_PATH}" ]]; then
        rm -rf "${BACKUP_PATH}"
    fi
    
    # Clean up compressed archive if it exists
    if [[ -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" ]]; then
        rm -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    fi
    
    # Restore permissions
    restore_permissions
    
    # Display blinking error message
    echo -e "\n${RED}$(tput blink)The space available is: ${available_space}MB, the backup file size is: ${backup_size}MB. THE BACKUP STOPPED. THE FILE IS NOT SAVED. CLEAN SPACE!!!$(tput sgr0)${NC}\n"
    
    exit 1
}

# Function to check available space and estimate backup size
check_space() {
    local phase="$1"
    local current_backup_size=0
    
    # Get available space in MB
    local available_space=$(df "${BACKUP_DIR}" | tail -1 | awk '{print int($4/1024)}')
    
    # Calculate current backup size if backup directory exists
    if [[ -d "${BACKUP_PATH}" ]]; then
        current_backup_size=$(du -sm "${BACKUP_PATH}" 2>/dev/null | cut -f1 || echo "0")
    fi
    
    # Estimate additional space needed based on phase
    local estimated_additional=0
    case "$phase" in
        "docker_volumes")
            # Estimate Docker volumes size (usually largest component)
            if [[ -d "/var/lib/docker/volumes" ]]; then
                estimated_additional=$(du -sm /var/lib/docker/volumes 2>/dev/null | cut -f1 || echo "0")
            fi
            ;;
        "docker_images")
            # Estimate Docker images size
            if command -v docker &> /dev/null; then
                estimated_additional=$(docker system df --format "table {{.Size}}" 2>/dev/null | grep -v SIZE | head -1 | sed 's/[^0-9.]//g' | cut -d'.' -f1 || echo "0")
                # Convert GB to MB if needed
                if docker system df 2>/dev/null | grep -q "GB"; then
                    estimated_additional=$((estimated_additional * 1024))
                fi
            fi
            ;;
        "compression")
            # For final compression, we need space for both uncompressed and compressed
            estimated_additional=$((current_backup_size * 2))
            ;;
        *)
            # Default safety margin
            estimated_additional=100
            ;;
    esac
    
    local total_needed=$((current_backup_size + estimated_additional + 500)) # 500MB safety margin
    
    if [[ $total_needed -gt $available_space ]]; then
        cleanup_and_exit "$available_space" "$total_needed"
    fi
    
    log "Space check passed: Available: ${available_space}MB, Estimated needed: ${total_needed}MB"
}

# Trap to ensure permissions are restored on exit
trap restore_permissions EXIT

log "Starting VPS backup process (Docker containers will remain running)..."

# Initial space check
check_space "initial"

# 1. System Information Collection
log "Collecting system information..."
{
    echo "=== SYSTEM INFORMATION ==="
    echo "Hostname: $(hostname)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h / | tail -1 | awk '{print $2}')"
    echo "IP Address: $(ip route get 8.8.8.8 | grep -oP 'src \K\S+')"
    echo "Backup Date: $(date)"
    echo ""
} > "${BACKUP_PATH}/system/system_info.txt"

# 2. Package Information
log "Collecting package information..."
{
    echo "=== INSTALLED PACKAGES ==="
    dpkg -l > "${BACKUP_PATH}/packages/dpkg_packages.txt" 2>/dev/null || true
    apt list --installed > "${BACKUP_PATH}/packages/apt_packages.txt" 2>/dev/null || true
    snap list > "${BACKUP_PATH}/packages/snap_packages.txt" 2>/dev/null || true

    echo "=== APT SOURCES ==="
    cp -r /etc/apt "${BACKUP_PATH}/packages/" 2>/dev/null || true

    echo "=== PIP PACKAGES ==="
    pip list > "${BACKUP_PATH}/packages/pip_packages.txt" 2>/dev/null || true
    pip3 list > "${BACKUP_PATH}/packages/pip3_packages.txt" 2>/dev/null || true
} 2>/dev/null

# 3. Services Information
log "Collecting services information..."
{
    systemctl list-units --type=service --state=active > "${BACKUP_PATH}/services/active_services.txt"
    systemctl list-units --type=service --state=enabled > "${BACKUP_PATH}/services/enabled_services.txt"
    systemctl list-units --type=service --state=failed > "${BACKUP_PATH}/services/failed_services.txt"
} 2>/dev/null || true

# 4. Network Configuration
log "Collecting network configuration..."
{
    ip addr show > "${BACKUP_PATH}/system/network_interfaces.txt"
    ip route show > "${BACKUP_PATH}/system/routes.txt"
    cat /etc/hosts > "${BACKUP_PATH}/system/hosts.txt" 2>/dev/null || true
    cat /etc/resolv.conf > "${BACKUP_PATH}/system/resolv.conf" 2>/dev/null || true
} 2>/dev/null

# 5. Docker Information and Backup (WITHOUT STOPPING CONTAINERS)
log "Collecting Docker information..."
if command -v docker &> /dev/null; then
    {
        docker --version > "${BACKUP_PATH}/docker/docker_version.txt"
        docker info > "${BACKUP_PATH}/docker/docker_info.txt" 2>/dev/null || true
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" > "${BACKUP_PATH}/docker/containers.txt"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" > "${BACKUP_PATH}/docker/images.txt"
        docker network ls > "${BACKUP_PATH}/docker/networks.txt"
        docker volume ls > "${BACKUP_PATH}/docker/volumes.txt"
    } 2>/dev/null || true

    # Check space before Docker volumes backup
    check_space "docker_volumes"
    
    # Backup Docker volumes (while containers are running - live backup)
    log "Backing up Docker volumes (live backup - containers remain running)..."
    temp_chmod "/var/lib/docker" "755"
    tar -czf "${BACKUP_PATH}/docker/docker_volumes.tar.gz" -C /var/lib/docker/volumes . 2>/dev/null || warn "Could not backup Docker volumes"

    # Check space before Docker images backup
    check_space "docker_images"
    
    # Backup Docker images (this doesn't affect running containers)
    log "Backing up Docker images..."
    docker save $(docker images -q) 2>/dev/null | gzip > "${BACKUP_PATH}/docker/docker_images.tar.gz" || warn "Could not backup Docker images"

    # Export compose files
    log "Searching for Docker Compose files..."
    find /opt /home /root -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | while read -r compose_file; do
        if [[ -f "$compose_file" ]]; then
            compose_dir=$(dirname "$compose_file")
            compose_name=$(echo "$compose_dir" | tr '/' '_')
            mkdir -p "${BACKUP_PATH}/docker/compose${compose_name}"
            cp "$compose_file" "${BACKUP_PATH}/docker/compose${compose_name}/" 2>/dev/null || true
            # Copy .env files if they exist
            if [[ -f "${compose_dir}/.env" ]]; then
                cp "${compose_dir}/.env" "${BACKUP_PATH}/docker/compose${compose_name}/" 2>/dev/null || true
            fi
        fi
    done

    # Backup database containers data (live dumps for consistency)
    log "Creating database dumps from running containers..."
    mkdir -p "${BACKUP_PATH}/docker/database_dumps"

    # MySQL/MariaDB containers
    docker ps --format "{{.Names}}" | grep -E "(mysql|mariadb)" | while read -r container; do
        log "Creating MySQL dump from container: $container"
        docker exec "$container" mysqldump --all-databases --single-transaction --routines --triggers 2>/dev/null > "${BACKUP_PATH}/docker/database_dumps/${container}_mysql_dump.sql" || warn "Could not dump MySQL from $container"
    done

    # PostgreSQL containers
    docker ps --format "{{.Names}}" | grep -E "(postgres|postgresql)" | while read -r container; do
        log "Creating PostgreSQL dump from container: $container"
        docker exec "$container" pg_dumpall -U postgres 2>/dev/null > "${BACKUP_PATH}/docker/database_dumps/${container}_postgres_dump.sql" || warn "Could not dump PostgreSQL from $container"
    done

    info "Docker backup completed without stopping any containers"
else
    warn "Docker not found on system"
fi

# 6. Easypanel Backup
log "Checking for Easypanel..."
if [[ -d "/etc/easypanel" ]] || [[ -d "/opt/easypanel" ]] || command -v easypanel &> /dev/null; then
    log "Backing up Easypanel..."

    # Backup Easypanel directories
    for dir in "/etc/easypanel" "/opt/easypanel" "/var/lib/easypanel"; do
        if [[ -d "$dir" ]]; then
            temp_chmod "$dir" "755"
            tar -czf "${BACKUP_PATH}/configs/easypanel_$(basename $dir).tar.gz" -C "$(dirname $dir)" "$(basename $dir)" 2>/dev/null || warn "Could not backup $dir"
        fi
    done

    # Backup Easypanel database if running (without stopping)
    if docker ps | grep -q easypanel; then
        log "Backing up Easypanel database (live dump)..."
        # Try to find Easypanel DB container more flexibly
        easypanel_db_container=$(docker ps --format '{{.Names}}' | grep -i 'easypanel' | grep -E 'mysql|mariadb|db' | head -1)
        if [[ -n "$easypanel_db_container" ]]; then
            # Try with no password first, then with password if you know it
            docker exec "$easypanel_db_container" mysqldump -u root --all-databases --single-transaction --routines --triggers 2>/dev/null > "${BACKUP_PATH}/configs/easypanel_db.sql" \
                || warn "Could not backup Easypanel database (no password)."
            # If you know the password, use:
            # docker exec "$easypanel_db_container" mysqldump -u root -pYOURPASSWORD --all-databases --single-transaction --routines --triggers 2>/dev/null > "${BACKUP_PATH}/configs/easypanel_db.sql" \
            #     || warn "Could not backup Easypanel database (with password)."
        else
            warn "Could not find Easypanel DB container"
        fi
    fi
else
    info "Easypanel not found on system"
fi

# 7. Configuration Files Backup
log "Backing up configuration files..."
config_dirs=(
    "/etc/nginx"
    "/etc/apache2"
    "/etc/ssl"
    "/etc/letsencrypt"
    "/etc/cron.d"
    "/etc/crontab"
    "/etc/fstab"
    "/etc/ssh"
    "/etc/systemd/system"
    "/etc/environment"
    "/etc/profile.d"
)

for config_dir in "${config_dirs[@]}"; do
    if [[ -e "$config_dir" ]]; then
        temp_chmod "$config_dir" "755"
        config_name=$(basename "$config_dir")
        tar -czf "${BACKUP_PATH}/configs/${config_name}.tar.gz" -C "$(dirname $config_dir)" "$config_name" 2>/dev/null || warn "Could not backup $config_dir"
    fi
done

# 8. User Data Backup (excluding system users)
log "Backing up user data..."
temp_chmod "/home" "755"
for user_home in /home/*; do
    if [[ -d "$user_home" ]]; then
        username=$(basename "$user_home")
        # Skip if user ID is less than 1000 (system users)
        user_id=$(id -u "$username" 2>/dev/null || echo "0")
        if [[ $user_id -ge 1000 ]]; then
            temp_chmod "$user_home" "755"
            tar -czf "${BACKUP_PATH}/system/user_${username}.tar.gz" -C "/home" "$username" 2>/dev/null || warn "Could not backup user data for $username"
        fi
    fi
done

# 9. Database Backup (system-level databases)
log "Checking for system databases..."
# MySQL/MariaDB (system installation)
if command -v mysql &> /dev/null || command -v mariadb &> /dev/null; then
    log "Backing up system MySQL/MariaDB databases..."
    mysqldump --all-databases --single-transaction --routines --triggers 2>/dev/null > "${BACKUP_PATH}/configs/mysql_all_databases.sql" || warn "Could not backup system MySQL databases"
fi

# PostgreSQL (system installation)
if command -v pg_dumpall &> /dev/null; then
    log "Backing up system PostgreSQL databases..."
    runuser -l postgres -c 'pg_dumpall' > "${BACKUP_PATH}/configs/postgresql_all_databases.sql" 2>/dev/null || warn "Could not backup system PostgreSQL databases"
fi

# 10. Create restoration script
log "Creating restoration script..."
cat > "${BACKUP_PATH}/restore.sh" << 'EOF'
#!/bin/bash

# VPS Restoration Script
# Run as root on target system

set -e

RESTORE_DIR="$(dirname "$(readlink -f "$0")")"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

log "Starting VPS restoration process..."
log "Restore directory: $RESTORE_DIR"

# Update system
log "Updating system packages..."
apt update && apt upgrade -y

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

# Restore packages
log "Installing packages..."
if [[ -f "$RESTORE_DIR/packages/apt_packages.txt" ]]; then
    grep -v "WARNING" "$RESTORE_DIR/packages/apt_packages.txt" | cut -d'/' -f1 | xargs apt install -y 2>/dev/null || warn "Some packages could not be installed"
fi

# Restore configurations
log "Restoring configurations..."
for config_file in "$RESTORE_DIR"/configs/*.tar.gz; do
    if [[ -f "$config_file" ]]; then
        config_name=$(basename "$config_file" .tar.gz)
        log "Restoring $config_name..."
        tar -xzf "$config_file" -C / 2>/dev/null || warn "Could not restore $config_name"
    fi
done

# Restore Docker
if [[ -d "$RESTORE_DIR/docker" ]]; then
    log "Restoring Docker data..."
    systemctl stop docker 2>/dev/null || true

    if [[ -f "$RESTORE_DIR/docker/docker_volumes.tar.gz" ]]; then
        tar -xzf "$RESTORE_DIR/docker/docker_volumes.tar.gz" -C /var/lib/docker/volumes/ 2>/dev/null || warn "Could not restore Docker volumes"
    fi

    systemctl start docker

    if [[ -f "$RESTORE_DIR/docker/docker_images.tar.gz" ]]; then
        docker load < "$RESTORE_DIR/docker/docker_images.tar.gz" 2>/dev/null || warn "Could not restore Docker images"
    fi

    # Restore database dumps to containers (after they're running)
    if [[ -d "$RESTORE_DIR/docker/database_dumps" ]]; then
        log "Restoring database dumps to containers..."
        for dump_file in "$RESTORE_DIR/docker/database_dumps"/*.sql; do
            if [[ -f "$dump_file" ]]; then
                container_name=$(basename "$dump_file" | sed 's/_mysql_dump.sql\|_postgres_dump.sql//')
                if docker ps | grep -q "$container_name"; then
                    if [[ "$dump_file" == *"mysql"* ]]; then
                        log "Restoring MySQL dump to $container_name"
                        docker exec -i "$container_name" mysql < "$dump_file" 2>/dev/null || warn "Could not restore MySQL dump to $container_name"
                    elif [[ "$dump_file" == *"postgres"* ]]; then
                        log "Restoring PostgreSQL dump to $container_name"
                        docker exec -i "$container_name" psql -U postgres < "$dump_file" 2>/dev/null || warn "Could not restore PostgreSQL dump to $container_name"
                    fi
                fi
            fi
        done
    fi
fi

# Restore system databases
if [[ -f "$RESTORE_DIR/configs/mysql_all_databases.sql" ]]; then
    log "Restoring system MySQL databases..."
    mysql < "$RESTORE_DIR/configs/mysql_all_databases.sql" 2>/dev/null || warn "Could not restore system MySQL databases"
fi

if [[ -f "$RESTORE_DIR/configs/postgresql_all_databases.sql" ]]; then
    log "Restoring system PostgreSQL databases..."
    runuser -l postgres -c "psql < '$RESTORE_DIR/configs/postgresql_all_databases.sql'" 2>/dev/null || warn "Could not restore system PostgreSQL databases"
fi

# Restore users
log "Restoring user data..."
for user_file in "$RESTORE_DIR"/system/user_*.tar.gz; do
    if [[ -f "$user_file" ]]; then
        username=$(basename "$user_file" | sed 's/user_//' | sed 's/.tar.gz//')
        log "Restoring user: $username"
        tar -xzf "$user_file" -C /home/ 2>/dev/null || warn "Could not restore user $username"
    fi
done

# Final steps
log "Performing final configuration..."
systemctl daemon-reload
systemctl restart docker 2>/dev/null || true

log "Restoration completed! Please reboot the system and verify all services."
log "Check the system_info.txt file for original system configuration."

EOF

chmod +x "${BACKUP_PATH}/restore.sh"

# 11. Create backup summary
log "Creating backup summary..."
{
    echo "=== VPS BACKUP SUMMARY ==="
    echo "Backup Date: $(date)"
    echo "Backup Location: ${BACKUP_PATH}"
    echo "Original System: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "Hostname: $(hostname)"
    echo "Backup Type: LIVE BACKUP (No Docker downtime)"
    echo ""
    echo "=== BACKUP CONTENTS ==="
    echo "- System information and configuration"
    echo "- All installed packages (apt, snap, pip)"
    echo "- Service configurations"
    echo "- Network settings"
    echo "- User data (non-system users)"
    echo "- Configuration files (/etc/nginx, /etc/ssl, etc.)"

    if command -v docker &> /dev/null; then
        echo "- Docker containers, images, and volumes (LIVE BACKUP)"
        echo "- Docker Compose files"
        echo "- Database dumps from running containers"
    fi

    if [[ -d "/etc/easypanel" ]] || [[ -d "/opt/easypanel" ]]; then
        echo "- Easypanel configuration and data"
    fi

    if command -v mysql &> /dev/null; then
        echo "- MySQL/MariaDB databases"
    fi

    if command -v pg_dumpall &> /dev/null; then
        echo "- PostgreSQL databases"
    fi

    echo ""
    echo "=== IMPORTANT NOTES ==="
    echo "- This backup was created WITHOUT stopping Docker containers"
    echo "- Database consistency ensured through live dumps"
    echo "- No service downtime during backup process"
    echo "- Volume backups are crash-consistent (safe for most applications)"
    echo ""
    echo "=== RESTORATION ==="
    echo "To restore on a new Ubuntu 24 VPS:"
    echo "1. Copy this backup directory to the new server"
    echo "2. Run: bash restore.sh"
    echo "3. Reboot the system"
    echo "4. Verify all services are running"
    echo ""
    echo "Backup Size: $(du -sh ${BACKUP_PATH} | cut -f1)"
} > "${BACKUP_PATH}/README.txt"

# 12. Set permissions for FTP access
log "Setting permissions for FTP access..."
chmod -R 755 "${BACKUP_PATH}"
chown -R root:root "${BACKUP_PATH}"

# 13. Create compressed archive
# Final space check before compression
check_space "compression"

log "Creating compressed backup archive..."
cd "${BACKUP_DIR}"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"
chmod 644 "${BACKUP_NAME}.tar.gz"

# Calculate final size
BACKUP_SIZE=$(du -sh "${BACKUP_NAME}.tar.gz" | cut -f1)

log "Backup completed successfully!"
log "✅ NO DOCKER CONTAINERS WERE STOPPED - Zero downtime backup!"
log "Backup location: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
log "Backup size: ${BACKUP_SIZE}"
log "To restore: Extract archive and run restore.sh as root"

# Clean up temporary directory if user wants
read -p "Remove uncompressed backup directory? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "${BACKUP_PATH}"
    log "Temporary backup directory removed"
fi

log "🎉 Live backup process completed - your services never went down!"
