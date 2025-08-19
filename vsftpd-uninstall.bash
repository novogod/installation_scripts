#!/usr/bin/env bash
# vsftpd complete uninstaller
# Version: 1.0.6
# Ultra-safe stop (PID-targeted), timeout guard, smart reverse-deps handling, and --force support.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()    { echo -e "${GREEN}[$(date +'%F %T')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%F %T')] WARNING: $*${NC}"; }
error()  { echo -e "${RED}[$(date +'%F %T')] ERROR: $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%F %T')] INFO: $*${NC}"; }

FORCE="${FORCE:-false}"

usage() {
  cat <<EOF
vsftpd-uninstall.bash v1.0.6
Usage: $0 [--force|-f] [--help|-h]

Options:
  -f, --force   Force-remove vsftpd package even if reverse dependencies exist
  -h, --help    Show this help
Environment:
  FORCE=true    Same as --force
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      -f|--force) FORCE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) warn "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}

FTP_USERS=("ftpbackup" "ftp_1" "ftp_2")

detect_os() {
  . /etc/os-release || { error "No /etc/os-release"; exit 1; }
  OS=$ID
  log "Detected OS: $OS"
}

check_requirements() {
  [[ $EUID -eq 0 ]] || { error "Run as root"; exit 1; }
}

safe_kill_vsftpd_pids() {
  # Only target exact vsftpd PIDs. Never use pkill -f.
  local pids
  pids=$(pgrep -x vsftpd 2>/dev/null || true)
  if [[ -n "${pids:-}" ]]; then
    info "Terminating vsftpd processes: $pids"
    # TERM then KILL each PID, never touching our shell
    echo "$pids" | xargs -r -n1 sh -c 'kill -TERM "$0" 2>/dev/null || true; sleep 1; kill -KILL "$0" 2>/dev/null || true'
  fi
}

stop_and_disable_vsftpd() {
  log "Stopping and disabling vsftpd service..."
  # Timeout guard so we never hang indefinitely during stop
  local t=0; local max=8
  systemctl stop vsftpd 2>/dev/null || true
  systemctl disable vsftpd 2>/dev/null || true
  systemctl mask vsftpd 2>/dev/null || true

  # Try PID-targeted termination loop for a few seconds
  while (( t < max )); do
    safe_kill_vsftpd_pids
    sleep 1
    if ! pgrep -x vsftpd >/dev/null 2>&1; then
      break
    fi
    ((t++))
  done

  # Final check (do not exit even if still present)
  if pgrep -x vsftpd >/dev/null 2>&1; then
    warn "Some vsftpd processes may still be running, continuing anyway"
  fi
}

remove_ftp_users() {
  log "Removing FTP users and home directories..."
  for user in "${FTP_USERS[@]}"; do
    if id "$user" >/dev/null 2>&1; then
      info "Removing user: $user"
      pkill -u "$user" 2>/dev/null || true
      sleep 0.5
      pkill -9 -u "$user" 2>/dev/null || true
      home_dir=$(getent passwd "$user" | cut -d: -f6 || echo "/home/$user")
      userdel -r "$user" 2>/dev/null || {
        warn "Failed to remove $user with userdel, trying manual cleanup"
        userdel "$user" 2>/dev/null || true
        [[ -n "$home_dir" && -d "$home_dir" ]] && rm -rf "$home_dir" 2>/dev/null || true
      }
      [[ -d "/home/$user" ]] && rm -rf "/home/$user" 2>/dev/null || true
    else
      info "User $user does not exist, skipping"
    fi
  done
}

remove_configs_and_logs() {
  log "Removing vsftpd configurations and logs..."
  rm -rf /etc/vsftpd 2>/dev/null || true
  rm -f /etc/vsftpd.conf /etc/vsftpd.conf.backup.* /etc/vsftpd.userlist 2>/dev/null || true
  rm -f /var/log/vsftpd* /var/log/xferlog* 2>/dev/null || true
  rm -rf /var/run/vsftpd /var/ftp 2>/dev/null || true
  rm -f /root/ftp_credentials.txt /var/log/vsftpd_install.log 2>/dev/null || true
  rm -rf /root/vsftpd_backup_* /root/vsftpd_hotfix_* /root/vsftpd_fix_* 2>/dev/null || true
}

remove_firewall_rules() {
  log "Removing firewall rules..."
  case "$OS" in
    ubuntu|debian)
      if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow 21/tcp 2>/dev/null || true
        ufw --force delete allow 40000:40050/tcp 2>/dev/null || true
        info "UFW rules removed"
      fi
      ;;
    centos|rhel|fedora)
      if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-service=ftp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=40000-40050/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewalld rules removed"
      fi
      ;;
  esac
}

get_reverse_deps_deb() {
  apt-cache rdepends vsftpd 2>/dev/null | awk 'NF && $0 !~ /Reverse Depends:|^vsftpd$/' || true
}

remove_known_reverse_deps_deb() {
  local removed_any=false
  local pkgs_to_remove=()
  dpkg -l | grep -qE '^ii\s+vsftpd-dbg' && pkgs_to_remove+=("vsftpd-dbg")
  dpkg -l | grep -qE '^ii\s+ubumirror' && pkgs_to_remove+=("ubumirror")
  if [[ ${#pkgs_to_remove[@]} -gt 0 ]]; then
    info "Removing known reverse dependencies: ${pkgs_to_remove[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs_to_remove[@]}" || true
    removed_any=true
  fi
  $removed_any && return 0 || return 1
}

is_deps_only_benign_deb() {
  local deps rest
  deps="$(get_reverse_deps_deb | tr -d '|' | awk '{$1=$1}1')"
  [[ -z "$deps" ]] && return 0
  rest="$(echo "$deps" | grep -Ev '^(vsftpd-dbg|ubumirror)$' || true)"
  [[ -z "$rest" ]]
}

check_package_dependencies() {
  log "Checking if packages can be safely removed..."
  case "$OS" in
    ubuntu|debian)
      if dpkg -l | grep -q "^ii.*vsftpd"; then
        local deps_count
        deps_count=$(get_reverse_deps_deb | wc -l | tr -d ' ' || echo "0")
        if [[ "$deps_count" -eq 0 ]]; then
          info "vsftpd has no reverse dependencies, safe to remove"
          return 0
        else
          warn "vsftpd has $deps_count reverse dependencies, manual review recommended"
          apt-cache rdepends vsftpd 2>/dev/null || true
          remove_known_reverse_deps_deb || true
          if is_deps_only_benign_deb; then
            info "Only benign reverse dependencies remain (or none). Proceeding with removal."
            return 0
          fi
          $FORCE && { warn "FORCE=true: proceeding to remove vsftpd despite remaining reverse dependencies"; return 0; }
          return 1
        fi
      fi
      ;;
    centos|rhel|fedora)
      if rpm -q vsftpd >/dev/null 2>&1; then
        local deps
        if command -v dnf >/dev/null 2>&1; then
          deps=$(dnf repoquery --whatrequires vsftpd 2>/dev/null | wc -l || echo "0")
        else
          deps=$(yum whatrequires vsftpd 2>/dev/null | grep -v "^Loaded plugins" | grep -v "^vsftpd-" | wc -l || echo "0")
        fi
        if [[ "$deps" -eq 0 ]]; then
          info "vsftpd has no dependencies, safe to remove"
          return 0
        else
          warn "vsftpd has dependencies, manual review recommended"
          $FORCE && { warn "FORCE=true: proceeding to remove vsftpd despite dependencies"; return 0; }
          return 1
        fi
      fi
      ;;
  esac
  return 0
}

remove_packages() {
  log "Removing vsftpd package..."
  if ! check_package_dependencies; then
    warn "Skipping package removal due to dependencies"
    return
  fi

  case "$OS" in
    ubuntu|debian)
      if dpkg -l | grep -q "^ii.*vsftpd"; then
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y vsftpd || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
        info "vsftpd package removed"
      fi
      ;;
    centos|rhel|fedora)
      if rpm -q vsftpd >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
          dnf remove -y vsftpd || true
        else
          yum remove -y vsftpd || true
        fi
        info "vsftpd package removed"
      fi
      ;;
  esac
}

cleanup_optional_packages() {
  log "Checking optional packages for removal..."
  case "$OS" in
    ubuntu|debian)
      if dpkg -l | grep -q "^ii.*pwgen"; then
        deps=$(apt-cache rdepends pwgen 2>/dev/null | grep -v "^pwgen$" | grep -v "Reverse Depends:" | wc -l || echo "1")
        if [[ "$deps" -eq 0 ]]; then
          info "Removing pwgen (no dependencies)"
          DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y pwgen || true
        else
          info "Keeping pwgen (has dependencies)"
        fi
      fi
      ;;
    centos|rhel|fedora)
      if rpm -q pwgen >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
          deps=$(dnf repoquery --whatrequires pwgen 2>/dev/null | wc -l || echo "1")
        else
          deps=1
        fi
        if [[ "$deps" -eq 0 ]]; then
          info "Removing pwgen (no dependencies)"
          if command -v dnf >/dev/null 2>&1; then dnf remove -y pwgen || true; else yum remove -y pwgen || true; fi
        else
          info "Keeping pwgen (has dependencies)"
        fi
      fi
      ;;
  esac
}

remove_shell_entry() {
  log "Cleaning up shell entries..."
  if grep -q "^/usr/sbin/nologin$" /etc/shells 2>/dev/null; then
    users_with_nologin=$(getent passwd | grep "/usr/sbin/nologin" | wc -l || echo "0")
    if [[ "$users_with_nologin" -eq 0 ]]; then
      sed -i '/^\/usr\/sbin\/nologin$/d' /etc/shells
      info "Removed /usr/sbin/nologin from /etc/shells"
    else
      info "Keeping /usr/sbin/nologin (other users still use it)"
    fi
  fi
}

verify_cleanup() {
  log "Verifying cleanup..."
  if systemctl is-active --quiet vsftpd 2>/dev/null; then
    warn "vsftpd service is still active"
  else
    info "vsftpd service stopped"
  fi
  if pgrep -x vsftpd >/dev/null 2>&1; then
    warn "vsftpd processes still running:"
    pgrep -x vsftpd | xargs ps -p 2>/dev/null || true
  else
    info "No vsftpd processes running"
  fi

  remaining_users=()
  for user in "${FTP_USERS[@]}"; do id "$user" >/dev/null 2>&1 && remaining_users+=("$user"); done
  if [[ ${#remaining_users[@]} -gt 0 ]]; then
    warn "Some FTP users still exist: ${remaining_users[*]}"
  else
    info "All FTP users removed"
  fi

  if find /etc -name "*vsftpd*" -type f 2>/dev/null | grep -v -F "$(readlink -f "$0")" | grep -q .; then
    warn "Some vsftpd config files remain:"
    find /etc -name "*vsftpd*" -type f 2>/dev/null | grep -v -F "$(readlink -f "$0")" || true
  else
    info "All vsftpd config files removed"
  fi

  case "$OS" in
    ubuntu|debian)
      if dpkg -l | grep -q "^ii.*vsftpd"; then
        warn "vsftpd package still installed"
      else
        info "vsftpd package removed"
      fi
      ;;
    centos|rhel|fedora)
      if rpm -q vsftpd >/dev/null 2>&1; then
        warn "vsftpd package still installed"
      else
        info "vsftpd package removed"
      fi
      ;;
  esac
}

main() {
  parse_args "$@"

  echo "=== vsftpd Complete Uninstaller v1.0.6 ==="
  echo

  detect_os
  check_requirements

  info "This will completely remove vsftpd and related configurations"
  info "FTP users (${FTP_USERS[*]}) and their home directories will be deleted"
  $FORCE && warn "FORCE=true is set: will remove vsftpd even if reverse dependencies are present"
  echo

  stop_and_disable_vsftpd
  remove_ftp_users
  remove_configs_and_logs
  remove_firewall_rules
  remove_packages
  cleanup_optional_packages
  remove_shell_entry

  echo
  verify_cleanup

  echo
  log "Uninstallation complete"
  info "Manual cleanup may be needed for:"
  info "- Custom firewall rules not managed by ufw/firewalld"
  info "- Application-specific FTP client configurations"
  info "- Backup files in non-standard locations"
}

main "$@"
