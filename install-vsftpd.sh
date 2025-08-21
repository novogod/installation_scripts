#!/usr/bin/env bash
#
# install_vsftpd.sh
# Version: 1.5.0
#
# Plain FTP (no TLS). Users are chrooted and land directly in a writable subdirectory.
# Passive mode enabled with validated pasv_address and configurable port range.
# Runs an end-to-end passive upload test and prints a summary.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
LOG_FILE="/var/log/vsftpd_install.log"

# Users and their writable subdirectories
FTP_USERS=("ftpbackup" "ftp_1" "ftp_2")
declare -A FTP_DIRS=(
  ["ftpbackup"]="backups"
  ["ftp_1"]="uploads"
  ["ftp_2"]="files"
)

# Passive mode ports (adjust if needed)
PASSIVE_MIN_PORT=40000
PASSIVE_MAX_PORT=40050

log()    { echo -e "${GREEN}[$(date +'%F %T')] $*${NC}" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[$(date +'%F %T')] WARNING: $*${NC}" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[$(date +'%F %T')] ERROR: $*${NC}" | tee -a "$LOG_FILE"; }
info()   { echo -e "${BLUE}[$(date +'%F %T')] INFO: $*${NC}" | tee -a "$LOG_FILE"; }
success(){ echo -e "${CYAN}[$(date +'%F %T')] SUCCESS: $*${NC}" | tee -a "$LOG_FILE"; }

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  elif [[ -f /etc/redhat-release ]]; then
    OS="centos"; OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
  else
    error "Unsupported OS"; exit 1
  fi
  log "Detected OS: $OS $OS_VERSION"
}

check_requirements() {
  if [[ $EUID -ne 0 ]]; then error "Run as root"; exit 1; fi
  touch "$LOG_FILE" || { error "Cannot write $LOG_FILE"; exit 1; }
  local avail_kb min_kb
  avail_kb=$(df / | awk 'NR==2{print $4}')
  min_kb=262144
  if (( avail_kb < min_kb )); then
    error "At least 256MB free disk required"; exit 1
  fi
  log "Requirements OK"
}

update_pkg_mgr() {
  log "Updating package manager..."
  case "$OS" in
    ubuntu|debian) apt-get update -y ;;
    centos|rhel|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y makecache
      else
        yum makecache -y
      fi
      ;;
    *) error "Unsupported OS"; exit 1 ;;
  esac
  log "Package manager updated"
}

install_dependencies() {
  log "Installing packages..."
  case "$OS" in
    ubuntu|debian)
      apt-get install -y vsftpd ufw pwgen openssl iproute2 net-tools curl ftp
      ;;
    centos|rhel|fedora)
      local packages="vsftpd firewalld pwgen openssl iproute net-tools curl ftp"
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y $packages
      else
        yum install -y $packages
      fi
      ;;
  esac
  log "Dependencies installed"
}

generate_password() {
  if command -v pwgen >/dev/null 2>&1; then
    pwgen -s 16 1
  else
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
  fi
}

create_ftp_users() {
  log "Creating FTP users..."
  declare -g -A FTP_PASSWORDS
  
  for user in "${FTP_USERS[@]}"; do
    local password user_home user_dir
    password=$(generate_password)
    FTP_PASSWORDS[$user]=$password
    user_home="/home/$user"
    user_dir="$user_home/${FTP_DIRS[$user]}"
    
    if ! id "$user" >/dev/null 2>&1; then
      useradd -m -d "$user_home" -s /bin/bash "$user"
      log "Created user: $user"
    else
      log "User $user already exists"
    fi
    
    echo "$user:$password" | chpasswd
    
    # Create writable subdirectory
    mkdir -p "$user_dir"
    chown "$user:$user" "$user_dir"
    chmod 755 "$user_dir"
    chmod u+w "$user_dir"
    
    # Set home directory permissions for chroot
    chown root:root "$user_home"
    chmod 755 "$user_home"
    
    success "FTP user created: $user -> ${FTP_DIRS[$user]}"
  done
}

configure_vsftpd() {
  log "Configuring vsftpd..."
  
  # Detect passive address
  PASV_ADDRESS=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' || echo "")
  info "Detected pasv_address: ${PASV_ADDRESS}"
  
  # Validate IPv4 format
  if [[ ! "$PASV_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    warn "Invalid or empty pasv_address detected; will omit pasv_address directive"
    PASV_ADDRESS=""
  fi
  
  # Backup original config
  if [[ -f /etc/vsftpd.conf ]]; then
    cp /etc/vsftpd.conf "/etc/vsftpd.conf.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Create vsftpd configuration
  cat > /etc/vsftpd.conf << 'EOF'
# vsftpd configuration for plain FTP
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

# Data connection mode (Passive)
pasv_enable=YES
port_enable=YES

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

# Welcome message
message_file=.message
dirmessage_enable=YES

# SSL/TLS disabled for plain FTP
ssl_enable=NO
EOF

  # Add passive port range and address
  echo "pasv_min_port=${PASSIVE_MIN_PORT}" >> /etc/vsftpd.conf
  echo "pasv_max_port=${PASSIVE_MAX_PORT}" >> /etc/vsftpd.conf
  
  if [[ -n "$PASV_ADDRESS" ]]; then
    echo "pasv_address=${PASV_ADDRESS}" >> /etc/vsftpd.conf
  fi
  
  # Add per-user local_root using user_config_dir
  mkdir -p /etc/vsftpd/user_conf
  for user in "${FTP_USERS[@]}"; do
    echo "local_root=/home/$user/${FTP_DIRS[$user]}" > "/etc/vsftpd/user_conf/$user"
  done
  echo "user_config_dir=/etc/vsftpd/user_conf" >> /etc/vsftpd.conf
  
  # Create userlist
  printf '%s\n' "${FTP_USERS[@]}" > /etc/vsftpd.userlist
  
  # Create secure chroot directory
  mkdir -p /var/run/vsftpd/empty
  
  # Set permissions
  chmod 644 /etc/vsftpd.conf /etc/vsftpd.userlist
  chmod 755 /etc/vsftpd/user_conf
  chmod 644 /etc/vsftpd/user_conf/*
  
  # Restart vsftpd to apply new config
  systemctl restart vsftpd || true
  
  success "vsftpd configured with passive mode"
}

configure_firewall() {
  log "Configuring firewall (if present)..."
  
  case "$OS" in
    ubuntu|debian)
      if command -v ufw >/dev/null 2>&1; then
        ufw --force enable
        ufw allow 21/tcp
        ufw allow "${PASSIVE_MIN_PORT}:${PASSIVE_MAX_PORT}/tcp"
        ufw allow ssh
        success "UFW configured for FTP and passive ports"
      else
        info "UFW not found, skipping firewall config"
      fi
      ;;
    centos|rhel|fedora)
      if command -v firewall-cmd >/dev/null 2>&1; then
        systemctl enable firewalld
        systemctl start firewalld
        firewall-cmd --permanent --add-service=ftp
        firewall-cmd --permanent --add-port="${PASSIVE_MIN_PORT}-${PASSIVE_MAX_PORT}/tcp"
        firewall-cmd --reload
        success "firewalld configured for FTP and passive ports"
      else
        info "firewalld not found, skipping firewall config"
      fi
      ;;
  esac
}

start_vsftpd_service() {
  log "Starting vsftpd service..."
  systemctl enable vsftpd
  systemctl start vsftpd
  
  if systemctl is-active --quiet vsftpd; then
    success "vsftpd service is running"
  else
    error "Failed to start vsftpd service"
    systemctl status vsftpd --no-pager || true
    exit 1
  fi
}

test_ftp_connection() {
  log "Testing FTP connectivity (passive mode)..."
  
  local server_ip test_user test_pass local_tmp remote_tmp
  server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  
  # Check if port 21 is listening
  if command -v ss >/dev/null 2>&1; then
    if ! ss -tuln | grep -q ':21 '; then
      error "FTP server not listening on port 21"; return 10
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if ! netstat -tuln | grep -q ':21 '; then
      error "FTP server not listening on port 21"; return 10
    fi
  fi
  success "Port 21 is listening"
  
  # Test with first user
  test_user="${FTP_USERS[0]}"
  test_pass="${FTP_PASSWORDS[$test_user]}"
  local_tmp="/tmp/ftp_test_$$.txt"
  remote_tmp="test_$$.txt"
  
  if ! command -v ftp >/dev/null 2>&1; then
    error "ftp client not found"; return 60
  fi
  
  echo "FTP test file $(date)" > "$local_tmp"
  
  # Perform FTP test
  ftp -n "$server_ip" << EOF > "/tmp/ftp_output_$$.log" 2>&1
user $test_user $test_pass
verbose
passive
pwd
mkdir test_dir_$$
cd test_dir_$$
lcd /tmp
put $(basename "$local_tmp") $remote_tmp
ls -l
delete $remote_tmp
cd ..
rmdir test_dir_$$
quit
EOF
  local rc=$?
  
  if [[ $rc -ne 0 ]]; then
    error "FTP test failed (exit code $rc)"
    head -50 "/tmp/ftp_output_$$.log" | sed 's/^/  /'
    rm -f "$local_tmp" "/tmp/ftp_output_$$.log"
    
    if grep -q "Login incorrect" "/tmp/ftp_output_$$.log"; then return 20; fi
    if grep -qi "Permission denied" "/tmp/ftp_output_$$.log"; then return 30; fi
    if grep -qi "Transfer complete" "/tmp/ftp_output_$$.log"; then return 50; fi
    return 40
  fi
  
  success "Passive-mode FTP test succeeded for user '$test_user'"
  rm -f "$local_tmp" "/tmp/ftp_output_$$.log"
  return 0
}

display_summary() {
  local test_rc="$1"
  local server_ip
  server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  
  echo
  echo "=================================================================="
  echo -e "${CYAN}vsftpd FTP Server Installation Complete${NC}"
  echo "=================================================================="
  echo
  
  echo -e "${CYAN}Test Result:${NC}"
  case "$test_rc" in
    0) echo "✓ Success: Passive-mode login and write test passed" ;;
    10) echo "✗ Failure (10): Not listening on port 21" ;;
    20) echo "✗ Failure (20): Authentication failed" ;;
    30) echo "✗ Failure (30): Permission denied" ;;
    40) echo "✗ Failure (40): Upload failed" ;;
    50) echo "✗ Failure (50): Delete failed" ;;
    60) echo "✗ Failure (60): FTP client missing" ;;
    *) echo "✗ Failure ($test_rc): Unknown error" ;;
  esac
  echo
  
  echo -e "${CYAN}Server Details:${NC}"
  echo "• IP Address: $server_ip"
  echo "• FTP Port: 21"
  echo "• Mode: Plain FTP (no encryption)"
  echo "• Passive Ports: ${PASSIVE_MIN_PORT}-${PASSIVE_MAX_PORT}"
  echo
  
  echo -e "${CYAN}FTP Users:${NC}"
  for user in "${FTP_USERS[@]}"; do
    echo "• Username: $user"
    echo "  Password: ${FTP_PASSWORDS[$user]}"
    echo "  Directory: ${FTP_DIRS[$user]}"
    echo "  Connection: ftp://$user:${FTP_PASSWORDS[$user]}@$server_ip"
    echo
  done
  
  echo -e "${CYAN}FileZilla Settings:${NC}"
  echo "• Protocol: FTP - File Transfer Protocol"
  echo "• Host: $server_ip"
  echo "• Port: 21"
  echo "• Encryption: Only use plain FTP (insecure)"
  echo "• Logon Type: Normal"
  echo "• Transfer Settings: Passive"
  echo
  
  echo -e "${YELLOW}Security Warning:${NC}"
  echo "• Plain FTP transmits passwords and data unencrypted"
  echo "• Use only on trusted networks or for temporary transfers"
  echo "• Consider SFTP for production use"
  echo
  
  echo -e "${CYAN}Log Files:${NC}"
  echo "• Installation: $LOG_FILE"
  echo "• FTP Transfers: /var/log/vsftpd.log"
  echo
  
  # Save credentials
  cat > /root/ftp_credentials.txt << EOF
FTP Server Credentials
Generated: $(date)

Server: $server_ip:21
Mode: Plain FTP (passive)

Users:
EOF
  
  for user in "${FTP_USERS[@]}"; do
    cat >> /root/ftp_credentials.txt << EOF
$user:${FTP_PASSWORDS[$user]} -> ${FTP_DIRS[$user]}
EOF
  done
  
  echo -e "${GREEN}Credentials saved to: /root/ftp_credentials.txt${NC}"
  echo "=================================================================="
}

main() {
  echo "=================================================================="
  echo -e "${GREEN}vsftpd FTP Server Installer v1.5.0${NC}"
  echo "=================================================================="
  echo
  
  touch "$LOG_FILE"
  log "Starting installation..."
  
  detect_os
  check_requirements
  update_pkg_mgr
  install_dependencies
  create_ftp_users
  configure_vsftpd
  configure_firewall
  start_vsftpd_service
  
  test_ftp_connection
  local test_result=$?
  
  display_summary "$test_result"
  
  if [[ $test_result -eq 0 ]]; then
    success "Installation completed successfully!"
  else
    warn "Installation completed with test failures (see summary above)"
  fi
}

main "$@"
