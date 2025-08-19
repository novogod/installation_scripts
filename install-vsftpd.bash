#!/bin/bash
#
# vsftpd Installation Script (install_vsftpd.bash)
# Version: 1.0.2
#
# DESCRIPTION
# ---------------------------------------------------------------------
# This script automatically installs and configures vsftpd FTP server
# with the following features:
#
# 1. System analysis and compatibility check
# 2. Dependency installation and swap configuration
# 3. vsftpd installation and secure configuration
# 4. FTP user creation with random password
# 5. Disk quota calculation and monitoring
# 6. Firewall configuration for FTP access
# 7. Service enablement and startup
# 8. Connection testing and credential display
#
# FEATURES
# - Automatic OS detection (Ubuntu/Debian/CentOS/RHEL)
# - Intelligent swap sizing based on available RAM
# - Secure vsftpd configuration with chroot jail
# - Random password generation for FTP user
# - Firewall rules for FTP (ports 21 and passive range)
# - Comprehensive logging and error handling
# - Disk quota management (50% of available space per user)
# - Real-time disk usage monitoring and welcome messages
# - Automated quota updates via cron job
#
# AMENDMENTS IN VERSION 1.0.2
# - Added disk quota calculation (50% of available disk space)
# - Implemented welcome message system showing quota information
# - Created automated quota monitoring script with hourly updates
# - Enhanced vsftpd configuration to display quota messages
# - Fixed port checking using ss/netstat with automatic fallback
# - Added comprehensive disk space analysis and reporting
#
# ---------------------------------------------------------------------

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
FTP_USERS=("ftpbackup" "ftp_1" "ftp_2")
PASSIVE_MIN_PORT=30000
PASSIVE_MAX_PORT=31000
LOG_FILE="/var/log/vsftpd_install.log"

# User-specific directories
declare -A FTP_DIRS
FTP_DIRS["ftpbackup"]="backups"
FTP_DIRS["ftp_1"]="uploads"
FTP_DIRS["ftp_2"]="files"

# Logging functions
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

warn() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

error() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

info() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1"
    echo -e "${BLUE}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

success() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1"
    echo -e "${CYAN}$message${NC}"
    echo "$message" >> "$LOG_FILE"
}

# Function to detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        error "Cannot detect operating system"
        exit 1
    fi

    log "Detected OS: $OS $OS_VERSION"
}

# Function to check system requirements
check_system_requirements() {
    log "Checking system requirements..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi

    # Check available disk space (minimum 1GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local min_space=1048576  # 1GB in KB

    if [[ $available_space -lt $min_space ]]; then
        error "Insufficient disk space. At least 1GB required, found $(($available_space/1024))MB"
        exit 1
    fi

    # Check RAM
    local total_ram=$(free -m | awk 'NR==2{print $2}')
    info "Total RAM: ${total_ram}MB"
    info "Available disk space: $(($available_space/1024))MB"

    # Check if vsftpd is already installed
    if command -v vsftpd &> /dev/null; then
        warn "vsftpd is already installed"
        read -p "Do you want to reconfigure it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Installation cancelled by user"
            exit 0
        fi
    fi

    log "System requirements check completed"
}

# Function to update package manager
update_package_manager() {
    log "Updating package manager..."

    case $OS in
        ubuntu|debian)
            apt-get update -y
            ;;
        centos|rhel|fedora)
            if command -v dnf &> /dev/null; then
                dnf -y makecache
                dnf update -y
            else
                yum makecache -y
                yum update -y
            fi
            ;;
        *)
            error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac

    log "Package manager updated"
}

# Function to install dependencies
install_dependencies() {
    log "Installing dependencies..."

    local packages=""
    case $OS in
        ubuntu|debian)
            packages="vsftpd ufw pwgen openssl iproute2 net-tools curl"
            apt-get install -y $packages
            ;;
        centos|rhel|fedora)
            packages="vsftpd firewalld pwgen openssl iproute net-tools curl"
            if command -v dnf &> /dev/null; then
                dnf install -y $packages
            else
                yum install -y $packages
            fi
            ;;
    esac

    log "Dependencies installed: $packages"
}

# Function to analyze server configuration and create swap if needed
analyze_and_create_swap() {
    log "Analyzing server configuration for swap requirements..."

    # Get system information
    local total_ram_mb=$(free -m | awk 'NR==2{print $2}')
    local total_ram_gb=$((total_ram_mb / 1024))
    local available_disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    local cpu_cores=$(nproc)

    info "Server Analysis:"
    info "• RAM: ${total_ram_mb}MB (${total_ram_gb}GB)"
    info "• CPU Cores: $cpu_cores"
    info "• Available Disk: ${available_disk_gb}GB"

    # Check if swap already exists
    local current_swap=$(free -m | awk 'NR==3{print $2}')
    if [[ $current_swap -gt 0 ]]; then
        info "• Current Swap: ${current_swap}MB"
        log "Swap already configured, skipping swap creation"
        return 0
    fi

    # Calculate recommended swap size for FTP server
    local recommended_swap_gb=0
    if [[ $total_ram_gb -le 1 ]]; then
        recommended_swap_gb=2
    elif [[ $total_ram_gb -le 2 ]]; then
        recommended_swap_gb=2
    elif [[ $total_ram_gb -le 4 ]]; then
        recommended_swap_gb=2
    elif [[ $total_ram_gb -le 8 ]]; then
        recommended_swap_gb=4
    else
        recommended_swap_gb=4
    fi

    # Ensure we don't use more than 20% of available disk space
    local max_swap_gb=$((available_disk_gb / 5))
    if [[ $recommended_swap_gb -gt $max_swap_gb ]]; then
        recommended_swap_gb=$max_swap_gb
    fi

    if [[ $recommended_swap_gb -lt 1 ]]; then
        warn "Insufficient disk space for swap file. Skipping swap creation."
        return 0
    fi

    log "Creating ${recommended_swap_gb}GB swap file for optimal FTP server performance..."

    # Create swap file
    local swap_size_mb=$((recommended_swap_gb * 1024))

    if ! fallocate -l ${swap_size_mb}M /swapfile 2>/dev/null; then
        log "fallocate failed, using dd instead..."
        dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_mb status=progress
    fi

    # Set proper permissions and format
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Add to fstab for persistence
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # Optimize swap settings for FTP server
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    if ! grep -q 'vm.vfs_cache_pressure' /etc/sysctl.conf; then
        echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
    fi

    sysctl -p

    success "Swap file created and configured: ${recommended_swap_gb}GB"
}

# Function to generate random password
generate_password() {
    if command -v pwgen &> /dev/null; then
        pwgen -s 16 1
    else
        openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
    fi
}

# Function to calculate and set up disk quotas
setup_disk_quotas() {
    log "Setting up disk quotas..."

    # Get available disk space in KB for root filesystem
    local available_space_kb=$(df / | awk 'NR==2 {print $4}')
    local available_space_gb=$((available_space_kb / 1024 / 1024))

    # Calculate quota per user as 50% of available space divided by number of users
    local total_quota_kb=$((available_space_kb / 2))
    local quota_per_user_kb=$((total_quota_kb / ${#FTP_USERS[@]}))
    local quota_per_user_gb=$((quota_per_user_kb / 1024 / 1024))

    # Store quota values globally for use in other functions
    USER_QUOTA_KB=$quota_per_user_kb
    USER_QUOTA_GB=$quota_per_user_gb
    AVAILABLE_SPACE_GB=$available_space_gb

    info "Disk Space Analysis:"
    info "• Total available space: ${available_space_gb}GB"
    info "• Total quota pool (50% of available): $((total_quota_kb / 1024 / 1024))GB"
    info "• Quota per user (${#FTP_USERS[@]} users): ${quota_per_user_gb}GB"

    # Create welcome messages for each user
    for user in "${FTP_USERS[@]}"; do
        local user_home="/home/$user"
        local user_dir="$user_home/${FTP_DIRS[$user]}"

        cat > "$user_dir/.message" << EOF
=================================================================
Welcome to FTP Server - User: $user
=================================================================

Disk Space Information:
• Your quota: ${quota_per_user_gb}GB (${quota_per_user_kb}KB)
• Server total available: ${available_space_gb}GB
• Total users: ${#FTP_USERS[@]}

Please ensure your files fit within the allocated quota.
For support, contact your system administrator.

=================================================================
EOF

        chown "$user:$user" "$user_dir/.message"
        chmod 644 "$user_dir/.message"
    done

    success "Disk quotas configured: ${quota_per_user_gb}GB quota per user (${#FTP_USERS[@]} users)"
}

# Function to create FTP users
create_ftp_users() {
    log "Creating FTP users..."

    # Initialize associative array for passwords
    declare -g -A FTP_PASSWORDS

    for user in "${FTP_USERS[@]}"; do
        # Generate random password for each user
        local password=$(generate_password)
        FTP_PASSWORDS[$user]=$password

        local user_home="/home/$user"
        local user_dir="$user_home/${FTP_DIRS[$user]}"

        # Create user if doesn't exist
        if ! id "$user" &>/dev/null; then
            useradd -m -d "$user_home" -s /bin/bash "$user"
            log "Created user: $user"
        else
            log "User $user already exists"
        fi

        # Set password
        echo "$user:$password" | chpasswd

        # Create user's FTP directory
        mkdir -p "$user_dir"
        chown "$user:$user" "$user_dir"
        chmod 755 "$user_dir"

        # Set proper permissions for home directory
        chown root:root "$user_home"
        chmod 755 "$user_home"

        success "FTP user created: $user with directory ${FTP_DIRS[$user]}"
    done

    log "All FTP users created successfully"
}

# Function to configure vsftpd
configure_vsftpd() {
    log "Configuring vsftpd..."

    # Backup original config
    if [[ -f /etc/vsftpd.conf ]]; then
        cp /etc/vsftpd.conf /etc/vsftpd.conf.backup.$(date +%Y%m%d_%H%M%S)
    fi

    # Create secure vsftpd configuration
    cat > /etc/vsftpd.conf << EOF
# vsftpd configuration for secure FTP backup server
# Generated by install_vsftpd.bash on $(date)

# Basic settings
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES

# Security settings
chroot_local_user=YES
chroot_list_enable=NO
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty

# User restrictions
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO

# Logging
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
xferlog_std_format=YES
log_ftp_protocol=YES

# Passive mode configuration
pasv_enable=YES
pasv_min_port=$PASSIVE_MIN_PORT
pasv_max_port=$PASSIVE_MAX_PORT
pasv_address=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

# Performance settings
idle_session_timeout=600
data_connection_timeout=120
accept_timeout=60
connect_timeout=60

# Additional security
hide_ids=YES
ls_recurse_enable=NO
download_enable=YES
dirlist_enable=YES

# Welcome message and directory message
message_file=.message
dirmessage_enable=YES

# SSL/TLS (disabled for plain FTP as requested)
ssl_enable=NO

# Local user settings
user_sub_token=\$USER
local_root=/home/\$USER
EOF

    # Create userlist with all FTP users
    > /etc/vsftpd.userlist
    for user in "${FTP_USERS[@]}"; do
        echo "$user" >> /etc/vsftpd.userlist
    done

    # Create secure chroot directory
    mkdir -p /var/run/vsftpd/empty

    # Set proper permissions
    chmod 644 /etc/vsftpd.conf
    chmod 644 /etc/vsftpd.userlist

    # Create quota monitoring script
    cat > /usr/local/bin/ftp_quota_check.sh << 'EOF'
#!/bin/bash
# FTP Quota Monitoring Script
# Updates the welcome message with current disk usage

FTP_USER="ftpbackup"
BACKUP_DIR="/home/$FTP_USER/backups"

if [[ -d "$BACKUP_DIR" ]]; then
    # Get current usage
    USED_KB=$(du -sk "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    USED_GB=$((USED_KB / 1024 / 1024))

    # Get available space
    AVAILABLE_KB=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))

    # Calculate quota (50% of total available + used)
    TOTAL_KB=$((AVAILABLE_KB + USED_KB))
    QUOTA_KB=$((TOTAL_KB / 2))
    QUOTA_GB=$((QUOTA_KB / 1024 / 1024))

    # Calculate remaining quota
    REMAINING_KB=$((QUOTA_KB - USED_KB))
    REMAINING_GB=$((REMAINING_KB / 1024 / 1024))

    # Update welcome message
    cat > "$BACKUP_DIR/.message" << EOL
=================================================================
Welcome to FTP Backup Server - $(date)
=================================================================

Disk Space Information:
• Your quota: ${QUOTA_GB}GB
• Currently used: ${USED_GB}GB
• Remaining quota: ${REMAINING_GB}GB
• Server available: ${AVAILABLE_GB}GB

$(if [[ $REMAINING_KB -lt 1048576 ]]; then echo "⚠️  WARNING: Less than 1GB quota remaining!"; fi)

Please ensure your backups fit within the allocated quota.
For support, contact your system administrator.

=================================================================
EOL

    chown "$FTP_USER:$FTP_USER" "$BACKUP_DIR/.message"
    chmod 644 "$BACKUP_DIR/.message"
fi
EOF

    chmod +x /usr/local/bin/ftp_quota_check.sh

    # Add cron job to update quota info every hour
    (crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/ftp_quota_check.sh") | crontab -

    success "vsftpd configured securely with quota monitoring"
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall for FTP access..."

    case $OS in
        ubuntu|debian)
            if command -v ufw &> /dev/null; then
                ufw --force enable
                ufw allow 21/tcp
                ufw allow $PASSIVE_MIN_PORT:$PASSIVE_MAX_PORT/tcp
                ufw allow ssh
                success "UFW firewall configured for FTP"
            fi
            ;;
        centos|rhel|fedora)
            if command -v firewall-cmd &> /dev/null; then
                systemctl enable firewalld
                systemctl start firewalld
                firewall-cmd --permanent --add-service=ftp
                firewall-cmd --permanent --add-port=$PASSIVE_MIN_PORT-$PASSIVE_MAX_PORT/tcp
                firewall-cmd --reload
                success "firewalld configured for FTP"
            fi
            ;;
    esac
}

# Function to start and enable vsftpd service
start_vsftpd_service() {
    log "Starting and enabling vsftpd service..."

    systemctl enable vsftpd
    systemctl start vsftpd

    if systemctl is-active --quiet vsftpd; then
        success "vsftpd service is running"
    else
        error "Failed to start vsftpd service"
        systemctl status vsftpd || true
        exit 1
    fi
}

# Function to test FTP connection
test_ftp_connection() {
    log "Testing FTP connection..."

    # Get server IP
    local server_ip=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

    # Check if FTP port is listening using ss first, fallback to netstat, otherwise install ss
    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ':21 '; then
            success "FTP server is listening on port 21"
        else
            error "FTP server is not listening on port 21"
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ':21 '; then
            success "FTP server is listening on port 21"
        else
            error "FTP server is not listening on port 21"
            return 1
        fi
    else
        warn "Neither ss nor netstat found. Installing ss..."
        case $OS in
            ubuntu|debian)
                apt-get update -y && apt-get install -y iproute2
                ;;
            centos|rhel|fedora)
                if command -v dnf &> /dev/null; then
                    dnf install -y iproute
                else
                    yum install -y iproute
                fi
                ;;
        esac
        if ss -tuln | grep -q ':21 '; then
            success "FTP server is listening on port 21"
        else
            error "FTP server is not listening on port 21"
            return 1
        fi
    fi

    # Test basic FTP authentication with first user if ftp client is available
    if command -v ftp &> /dev/null; then
        local first_user="${FTP_USERS[0]}"
        local first_password="${FTP_PASSWORDS[$first_user]}"
        timeout 10 ftp -n "$server_ip" << EOF > /dev/null 2>&1
user $first_user $first_password
quit
EOF
        if [[ $? -eq 0 ]]; then
            success "FTP authentication test completed (may still fail if firewall/NAT blocks data channel)"
        else
            warn "FTP authentication test failed (could be due to network/NAT/firewall). Try with a GUI client like FileZilla."
        fi
    fi
}

# Function to display installation summary
display_summary() {
    local server_ip=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

    echo
    echo "=================================================================="
    echo -e "${GREEN}vsftpd FTP Server Installation Complete!${NC}"
    echo "=================================================================="
    echo
    echo -e "${CYAN}FTP Server Details:${NC}"
    echo "• Server IP: $server_ip"
    echo "• FTP Port: 21"
    echo "• Passive Ports: $PASSIVE_MIN_PORT-$PASSIVE_MAX_PORT"
    echo
    echo -e "${CYAN}FTP User Credentials:${NC}"
    for user in "${FTP_USERS[@]}"; do
        local user_home="/home/$user"
        local user_dir="$user_home/${FTP_DIRS[$user]}"
        echo "• Username: $user"
        echo "  Password: ${FTP_PASSWORDS[$user]}"
        echo "  Home Directory: $user_home"
        echo "  Working Directory: $user_dir"
        echo
    done

    echo -e "${CYAN}Connection Examples:${NC}"
    local first_user="${FTP_USERS[0]}"
    local first_password="${FTP_PASSWORDS[$first_user]}"
    echo "• Command line: ftp $server_ip"
    echo "• FileZilla: Host: $server_ip, Port: 21, User: $first_user, Pass: $first_password"
    echo "• URL format: ftp://$first_user:$first_password@$server_ip"
    echo
    echo -e "${CYAN}Security Notes:${NC}"
    echo "• Users are chrooted to their home directories"
    echo "• ${#FTP_USERS[@]} FTP users configured with individual directories"
    echo "• Firewall configured for FTP access"
    echo "• Plain FTP (no SSL/TLS) as requested"
    echo
    echo -e "${YELLOW}⚠️  Important Security Warning:${NC}"
    echo "• FTP transmits credentials and data in plain text"
    echo "• Consider using SFTP for production environments"
    echo "• Regularly change the FTP passwords"
    echo
    echo -e "${CYAN}Log Files:${NC}"
    echo "• Installation log: $LOG_FILE"
    echo "• FTP transfer log: /var/log/vsftpd.log"
    echo
    echo "=================================================================="

    # Save credentials to file
    cat > /root/ftp_credentials.txt << EOF
vsftpd FTP Server Credentials
Generated on: $(date)

Server IP: $server_ip
FTP Port: 21

FTP Users:
EOF

    for user in "${FTP_USERS[@]}"; do
        local user_home="/home/$user"
        local user_dir="$user_home/${FTP_DIRS[$user]}"
        cat >> /root/ftp_credentials.txt << EOF
Username: $user
Password: ${FTP_PASSWORDS[$user]}
Home Directory: $user_home
Working Directory: $user_dir
Connection String: ftp://$user:${FTP_PASSWORDS[$user]}@$server_ip

EOF
    done

    echo -e "${GREEN}Credentials saved to: /root/ftp_credentials.txt${NC}"
    echo
}

# Main installation function
main() {
    echo "=================================================================="
    echo -e "${GREEN}vsftpd FTP Server Installation Script${NC}"
    echo "=================================================================="
    echo

    # Initialize log file
    touch "$LOG_FILE"
    log "Starting vsftpd installation process..."

    # Run installation steps
    detect_os
    check_system_requirements
    update_package_manager
    install_dependencies
    analyze_and_create_swap
    create_ftp_users
    setup_disk_quotas
    configure_vsftpd
    configure_firewall
    start_vsftpd_service
    test_ftp_connection

    # Display final summary
    display_summary

    success "vsftpd FTP server installation completed successfully!"
}

# Run main function
main "$@"
