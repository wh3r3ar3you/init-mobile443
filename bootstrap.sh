#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_SSH_PORT=22
readonly MOBILE443_BASE_DIR="/opt/mobile443"
readonly MOBILE443_STATE_DIR="/var/lib/mobile443"
readonly MOBILE443_LISTS_DIR="${MOBILE443_BASE_DIR}/lists"
readonly MOBILE443_CONFIG_FILE="${MOBILE443_BASE_DIR}/config.conf"
readonly MOBILE443_ASNS_FILE="${MOBILE443_BASE_DIR}/asns.conf"
readonly MOBILE443_EXCEPTIONS_FILE="${MOBILE443_BASE_DIR}/exceptions.conf"
readonly MOBILE443_PORTS="${MOBILE443_PORTS:-443}"
readonly MOBILE443_COMMON_TARGET="/usr/local/sbin/mobile443-common.sh"
readonly MOBILE443_UPDATE_TARGET="/usr/local/sbin/mobile443-update.sh"
readonly MOBILE443_APPLY_TARGET="/usr/local/sbin/mobile443-apply-cache.sh"
readonly MOBILE443_APPLY_EXCEPTIONS_TARGET="/usr/local/sbin/mobile443-apply-exceptions.sh"
readonly MOBILE443_APPLY_SERVICE_TARGET="/etc/systemd/system/mobile443-apply.service"
readonly MOBILE443_UPDATE_SERVICE_TARGET="/etc/systemd/system/mobile443-update.service"
readonly MOBILE443_TIMER_TARGET="/etc/systemd/system/mobile443-update.timer"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_BACKUP="/etc/ssh/sshd_config.bak.bootstrap"
readonly SYSCTL_IPV6_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
readonly SYSCTL_TUNING_FILE="/etc/sysctl.d/99-vpn-tuning.conf"
readonly SYSCTL_DEFENSE_FILE="/etc/sysctl.d/99-vpn-defense.conf"
readonly SYSCTL_RPS_FILE="/etc/sysctl.d/99-vpn-rps.conf"
readonly CONNTRACK_MODPROBE_FILE="/etc/modprobe.d/vpn-defense-conntrack.conf"
readonly RPS_SCRIPT_TARGET="/usr/local/sbin/apply-vpn-rps.sh"
readonly RPS_SERVICE_TARGET="/etc/systemd/system/vpn-rps.service"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"

HOSTNAME_VALUE=""
SSH_PORT_VALUE="${DEFAULT_SSH_PORT}"
SSH_KEY_VALUE=""
MOBILE443_EXCEPTIONS=()
INSTALL_VPN_DEFENSE=0
INSTALL_XANMOD_LTS=0
AUTO_REBOOT_AFTER_BOOTSTRAP=0
SSH_SERVICE_NAME=""
DEFENSE_CT_MAX=1048576
DEFENSE_CT_BUCKETS=524288
DEFENSE_SOMAXCONN=8192
DEFENSE_SYN_BACKLOG=8192
DEFENSE_NETDEV_BACKLOG=250000
DEFENSE_SYN_RATE=80
DEFENSE_SYN_BURST=160
DEFENSE_RPS_FLOW_TOTAL=0
DEFENSE_RPS_FLOW_Q=0
DEFENSE_RPS_CPU_MASK=""
DEFENSE_RPS_INTERFACE=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf 'Run as root\n' >&2
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${cmd}" >&2
    exit 1
  fi
}

is_apt_package_installed() {
  local package="$1"
  dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -Fqx 'install ok installed'
}

is_apt_package_available() {
  local package="$1"
  apt-cache show "${package}" >/dev/null 2>&1
}

install_apt_packages() {
  local package missing_packages=()

  for package in "$@"; do
    if ! is_apt_package_installed "${package}"; then
      missing_packages+=("${package}")
    fi
  done

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    log "Required apt packages are already installed"
    return
  fi

  log "Installing missing apt packages: ${missing_packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${missing_packages[@]}"
}

detect_ssh_service() {
  if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE_NAME="ssh"
    return
  fi

  if systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE_NAME="sshd"
    return
  fi

  printf 'Unable to detect SSH service name (ssh or sshd)\n' >&2
  exit 1
}

ask_hostname() {
  local current_hostname input
  current_hostname="$(hostnamectl --static 2>/dev/null || hostnamectl hostname 2>/dev/null || hostname)"

  while true; do
    read -r -p "Enter hostname [${current_hostname}]: " input
    input="${input:-${current_hostname}}"

    if [[ "${input}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]] && [[ "${input}" != *..* ]]; then
      HOSTNAME_VALUE="${input}"
      return
    fi

    printf 'Invalid hostname. Use letters, digits, dots and hyphens.\n' >&2
  done
}

ask_ssh_port() {
  local input

  while true; do
    read -r -p "Enter SSH port [${DEFAULT_SSH_PORT}]: " input
    input="${input:-${DEFAULT_SSH_PORT}}"

    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      SSH_PORT_VALUE="${input}"
      return
    fi

    printf 'Invalid SSH port. Enter a number from 1 to 65535.\n' >&2
  done
}

ask_ssh_key() {
  local input key_type

  while true; do
    read -r -p "Enter public SSH key to add to /root/.ssh/authorized_keys: " input

    key_type="${input%% *}"
    if [[ "${input}" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
      if [[ "${key_type}" == "ssh-rsa" ]]; then
        printf 'Warning: ssh-rsa keys are accepted for compatibility, but ed25519 is preferred.\n' >&2
      fi
      SSH_KEY_VALUE="${input}"
      return
    fi

    printf 'Invalid public SSH key. Paste a single OpenSSH public key line.\n' >&2
  done
}

ask_vpn_defense() {
  local input

  while true; do
    read -r -p "Install VPN defense profile (auto-tuned conntrack/backlog, RPS/RFS + iptables rate limits)? [y/N]: " input
    input="${input:-n}"

    case "${input}" in
      y|Y|yes|YES)
        INSTALL_VPN_DEFENSE=1
        return
        ;;
      n|N|no|NO)
        INSTALL_VPN_DEFENSE=0
        return
        ;;
    esac

    printf 'Enter y or n.\n' >&2
  done
}

normalize_ipv4_exception() {
  local entry="$1"
  local ip mask octet
  local IFS=.

  if [[ "${entry}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    entry="${entry}/32"
  fi

  [[ "${entry}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${entry%/*}"
  mask="${entry#*/}"

  [[ "${mask}" =~ ^[0-9]+$ ]] || return 1
  (( mask >= 0 && mask <= 32 )) || return 1

  for octet in ${ip}; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done

  printf '%s\n' "${entry}"
}

ask_mobile443_exceptions() {
  local input entry normalized
  local -A seen=()

  while true; do
    read -r -p "Add source IP/CIDR exceptions for mobile443 filter? [y/N]: " input
    input="${input:-n}"

    case "${input}" in
      y|Y|yes|YES)
        break
        ;;
      n|N|no|NO)
        MOBILE443_EXCEPTIONS=()
        return
        ;;
    esac

    printf 'Enter y or n.\n' >&2
  done

  while true; do
    read -r -p "Enter exception IP/CIDR list separated by spaces or commas: " input
    input="${input//,/ }"

    MOBILE443_EXCEPTIONS=()
    seen=()
    for entry in ${input}; do
      normalized="$(normalize_ipv4_exception "${entry}")" || {
        printf 'Invalid IPv4 address or CIDR: %s\n' "${entry}" >&2
        MOBILE443_EXCEPTIONS=()
        break
      }

      if [[ -z "${seen[${normalized}]:-}" ]]; then
        MOBILE443_EXCEPTIONS+=("${normalized}")
        seen["${normalized}"]=1
      fi
    done

    if [[ ${#MOBILE443_EXCEPTIONS[@]} -gt 0 ]]; then
      return
    fi

    printf 'Provide at least one valid IPv4 address or CIDR, for example 203.0.113.10 or 203.0.113.0/24.\n' >&2
  done
}

ask_xanmod_lts() {
  local input

  while true; do
    read -r -p "Install XanMod LTS kernel after package setup? [y/N]: " input
    input="${input:-n}"

    case "${input}" in
      y|Y|yes|YES)
        INSTALL_XANMOD_LTS=1
        return
        ;;
      n|N|no|NO)
        INSTALL_XANMOD_LTS=0
        return
        ;;
    esac

    printf 'Enter y or n.\n' >&2
  done
}

ask_xanmod_reboot() {
  local input

  if [[ "${INSTALL_XANMOD_LTS}" -ne 1 ]]; then
    AUTO_REBOOT_AFTER_BOOTSTRAP=0
    return
  fi

  while true; do
    read -r -p "Reboot automatically after successful bootstrap to activate XanMod? [y/N]: " input
    input="${input:-n}"

    case "${input}" in
      y|Y|yes|YES)
        AUTO_REBOOT_AFTER_BOOTSTRAP=1
        return
        ;;
      n|N|no|NO)
        AUTO_REBOOT_AFTER_BOOTSTRAP=0
        return
        ;;
    esac

    printf 'Enter y or n.\n' >&2
  done
}

configure_hostname() {
  local hosts_entry

  log "Configuring hostname"
  hostnamectl set-hostname "${HOSTNAME_VALUE}"

  hosts_entry="127.0.1.1 ${HOSTNAME_VALUE}"
  if grep -Eq '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    if grep -Fqx "${hosts_entry}" /etc/hosts; then
      return
    fi
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/${hosts_entry}/" /etc/hosts
  else
    printf '%s\n' "${hosts_entry}" >> /etc/hosts
  fi
}

configure_sysctl() {
  log "Configuring sysctl"

  cat <<'EOF' > "${SYSCTL_IPV6_FILE}"
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

  cat <<'EOF' > "${SYSCTL_TUNING_FILE}"

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1

net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.src_valid_mark=1
net.ipv4.conf.default.src_valid_mark=1

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.optmem_max=4194304

net.core.netdev_max_backlog=250000
net.core.somaxconn=8192

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_tw_reuse=1

net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_syn_backlog=8192

net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=7440
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=180
EOF

  sysctl -e -p "${SYSCTL_IPV6_FILE}" >/dev/null
  sysctl -e -p "${SYSCTL_TUNING_FILE}" >/dev/null
}

calculate_vpn_defense_tuning() {
  local nproc ram_kb ram_gb

  nproc="$(nproc)"
  ram_kb="$(awk '/MemTotal/ { print $2 }' /proc/meminfo)"
  ram_gb=$(( ram_kb / 1024 / 1024 ))

  if (( ram_gb >= 64 )); then
    DEFENSE_CT_MAX=16777216
  elif (( ram_gb >= 32 )); then
    DEFENSE_CT_MAX=8388608
  elif (( ram_gb >= 16 )); then
    DEFENSE_CT_MAX=4194304
  elif (( ram_gb >= 8 )); then
    DEFENSE_CT_MAX=2097152
  elif (( ram_gb >= 4 )); then
    DEFENSE_CT_MAX=1048576
  elif (( ram_gb >= 2 )); then
    DEFENSE_CT_MAX=524288
  else
    DEFENSE_CT_MAX=262144
  fi
  DEFENSE_CT_BUCKETS=$(( DEFENSE_CT_MAX / 2 ))

  if (( nproc >= 32 )); then
    DEFENSE_SOMAXCONN=524288
    DEFENSE_SYN_BACKLOG=524288
    DEFENSE_NETDEV_BACKLOG=1000000
    DEFENSE_SYN_RATE=300
    DEFENSE_SYN_BURST=600
    DEFENSE_RPS_FLOW_TOTAL=262144
    DEFENSE_RPS_FLOW_Q=16384
  elif (( nproc >= 16 )); then
    DEFENSE_SOMAXCONN=262144
    DEFENSE_SYN_BACKLOG=262144
    DEFENSE_NETDEV_BACKLOG=500000
    DEFENSE_SYN_RATE=200
    DEFENSE_SYN_BURST=400
    DEFENSE_RPS_FLOW_TOTAL=131072
    DEFENSE_RPS_FLOW_Q=8192
  elif (( nproc >= 8 )); then
    DEFENSE_SOMAXCONN=131072
    DEFENSE_SYN_BACKLOG=131072
    DEFENSE_NETDEV_BACKLOG=300000
    DEFENSE_SYN_RATE=120
    DEFENSE_SYN_BURST=240
    DEFENSE_RPS_FLOW_TOTAL=65536
    DEFENSE_RPS_FLOW_Q=8192
  elif (( nproc >= 4 )); then
    DEFENSE_SOMAXCONN=65535
    DEFENSE_SYN_BACKLOG=65535
    DEFENSE_NETDEV_BACKLOG=250000
    DEFENSE_SYN_RATE=80
    DEFENSE_SYN_BURST=160
    DEFENSE_RPS_FLOW_TOTAL=32768
    DEFENSE_RPS_FLOW_Q=4096
  elif (( nproc >= 2 )); then
    DEFENSE_SOMAXCONN=32768
    DEFENSE_SYN_BACKLOG=32768
    DEFENSE_NETDEV_BACKLOG=100000
    DEFENSE_SYN_RATE=60
    DEFENSE_SYN_BURST=120
    DEFENSE_RPS_FLOW_TOTAL=16384
    DEFENSE_RPS_FLOW_Q=4096
  else
    DEFENSE_SOMAXCONN=16384
    DEFENSE_SYN_BACKLOG=16384
    DEFENSE_NETDEV_BACKLOG=50000
    DEFENSE_SYN_RATE=60
    DEFENSE_SYN_BURST=120
    DEFENSE_RPS_FLOW_TOTAL=0
    DEFENSE_RPS_FLOW_Q=0
  fi

  DEFENSE_RPS_CPU_MASK="$(build_cpu_mask "${nproc}")"

  log "VPN defense auto-tune: nproc=${nproc} ram=${ram_gb}G ct_max=${DEFENSE_CT_MAX} buckets=${DEFENSE_CT_BUCKETS} somaxconn=${DEFENSE_SOMAXCONN} syn_backlog=${DEFENSE_SYN_BACKLOG} netdev_backlog=${DEFENSE_NETDEV_BACKLOG} rps_mask=${DEFENSE_RPS_CPU_MASK} rps_flow=${DEFENSE_RPS_FLOW_TOTAL}/${DEFENSE_RPS_FLOW_Q}"
}

build_cpu_mask() {
  local cpus="$1"
  local full_chunks remainder i
  local chunks=()

  if (( cpus <= 0 )); then
    printf '0\n'
    return
  fi

  full_chunks=$(( cpus / 32 ))
  remainder=$(( cpus % 32 ))

  if (( remainder > 0 )); then
    chunks+=("$(printf '%x' "$(( (1 << remainder) - 1 ))")")
  fi

  for (( i = 0; i < full_chunks; i++ )); do
    chunks+=("ffffffff")
  done

  (IFS=,; printf '%s\n' "${chunks[*]}")
}

detect_primary_interface() {
  local iface

  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '
    /dev/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  ')"

  if [[ -n "${iface}" ]]; then
    printf '%s\n' "${iface}"
    return
  fi

  ip -br link 2>/dev/null | awk '$1 !~ /^(lo|docker|veth|br-|tun|tap|wg)/ && $2 == "UP" { print $1; exit }'
}

apply_conntrack_hashsize() {
  modprobe nf_conntrack 2>/dev/null || true
  install -d -m 755 "$(dirname "${CONNTRACK_MODPROBE_FILE}")"
  printf 'options nf_conntrack hashsize=%s\n' "${DEFENSE_CT_BUCKETS}" > "${CONNTRACK_MODPROBE_FILE}"

  if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    printf '%s\n' "${DEFENSE_CT_BUCKETS}" > /sys/module/nf_conntrack/parameters/hashsize || true
  fi
}

configure_vpn_defense_sysctl() {
  if [[ "${INSTALL_VPN_DEFENSE}" -ne 1 ]]; then
    return
  fi

  log "Configuring VPN defense sysctl"
  calculate_vpn_defense_tuning
  apply_conntrack_hashsize

  cat <<EOF > "${SYSCTL_DEFENSE_FILE}"
# Auto-tuned VPN defense profile.
net.netfilter.nf_conntrack_max=${DEFENSE_CT_MAX}
net.ipv4.tcp_syncookies=1
net.core.somaxconn=${DEFENSE_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog=${DEFENSE_SYN_BACKLOG}
net.core.netdev_max_backlog=${DEFENSE_NETDEV_BACKLOG}
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_fin_timeout=15
EOF

  sysctl -e -p "${SYSCTL_DEFENSE_FILE}" >/dev/null
}

configure_vpn_rps_rfs() {
  local queue

  if [[ "${INSTALL_VPN_DEFENSE}" -ne 1 ]]; then
    return
  fi

  if [[ "${DEFENSE_RPS_FLOW_TOTAL}" -le 0 || "${DEFENSE_RPS_FLOW_Q}" -le 0 ]]; then
    log "Skipping RPS/RFS: single CPU or unsupported tuning profile"
    return
  fi

  DEFENSE_RPS_INTERFACE="$(detect_primary_interface)"
  if [[ -z "${DEFENSE_RPS_INTERFACE}" ]]; then
    log "Skipping RPS/RFS: unable to detect primary network interface"
    return
  fi

  if ! compgen -G "/sys/class/net/${DEFENSE_RPS_INTERFACE}/queues/rx-*/rps_cpus" >/dev/null; then
    log "Skipping RPS/RFS: no RX queues found for ${DEFENSE_RPS_INTERFACE}"
    return
  fi

  log "Configuring RPS/RFS on ${DEFENSE_RPS_INTERFACE}: mask=${DEFENSE_RPS_CPU_MASK} flow_entries=${DEFENSE_RPS_FLOW_TOTAL} per_queue=${DEFENSE_RPS_FLOW_Q}"

  for queue in /sys/class/net/"${DEFENSE_RPS_INTERFACE}"/queues/rx-*/rps_cpus; do
    [[ -w "${queue}" ]] && printf '%s\n' "${DEFENSE_RPS_CPU_MASK}" > "${queue}"
  done

  printf '%s\n' "${DEFENSE_RPS_FLOW_TOTAL}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

  for queue in /sys/class/net/"${DEFENSE_RPS_INTERFACE}"/queues/rx-*/rps_flow_cnt; do
    [[ -w "${queue}" ]] && printf '%s\n' "${DEFENSE_RPS_FLOW_Q}" > "${queue}"
  done

  cat <<EOF > "${SYSCTL_RPS_FILE}"
# Auto-tuned RPS/RFS flow table for VPN defense profile.
net.core.rps_sock_flow_entries=${DEFENSE_RPS_FLOW_TOTAL}
EOF

  install -d -m 755 "$(dirname "${RPS_SCRIPT_TARGET}")"
  cat <<EOF > "${RPS_SCRIPT_TARGET}"
#!/usr/bin/env bash
set -euo pipefail

readonly RPS_CPU_MASK="${DEFENSE_RPS_CPU_MASK}"
readonly RPS_FLOW_TOTAL="${DEFENSE_RPS_FLOW_TOTAL}"
readonly RPS_FLOW_Q="${DEFENSE_RPS_FLOW_Q}"

detect_primary_interface() {
  local iface

  iface="\$(ip route get 1.1.1.1 2>/dev/null | awk '
    /dev/ {
      for (i = 1; i <= NF; i++) {
        if (\$i == "dev") {
          print \$(i + 1)
          exit
        }
      }
    }
  ')"

  if [[ -n "\${iface}" ]]; then
    printf '%s\n' "\${iface}"
    return
  fi

  ip -br link 2>/dev/null | awk '\$1 !~ /^(lo|docker|veth|br-|tun|tap|wg)/ && \$2 == "UP" { print \$1; exit }'
}

main() {
  local iface queue

  iface="\$(detect_primary_interface)"
  [[ -n "\${iface}" ]] || exit 0

  for queue in /sys/class/net/"\${iface}"/queues/rx-*/rps_cpus; do
    [[ -w "\${queue}" ]] && printf '%s\n' "\${RPS_CPU_MASK}" > "\${queue}"
  done

  printf '%s\n' "\${RPS_FLOW_TOTAL}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

  for queue in /sys/class/net/"\${iface}"/queues/rx-*/rps_flow_cnt; do
    [[ -w "\${queue}" ]] && printf '%s\n' "\${RPS_FLOW_Q}" > "\${queue}"
  done
}

main "\$@"
EOF
  chmod 755 "${RPS_SCRIPT_TARGET}"

  cat <<EOF > "${RPS_SERVICE_TARGET}"
[Unit]
Description=Apply VPN RPS/RFS tuning to NIC RX queues
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RPS_SCRIPT_TARGET}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "${RPS_SERVICE_TARGET}")" >/dev/null
}

update_system() {
  log "Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
}

install_packages() {
  install_apt_packages \
    tcpdump \
    nload \
    iftop \
    htop \
    curl \
    sudo \
    git \
    wget \
    vim \
    zsh \
    fonts-powerline \
    ca-certificates \
    gnupg \
    kmod \
    iproute2 \
    lsb-release \
    openssh-server \
    openssh-client \
    ipset \
    iptables \
    iptables-persistent \
    jq

  if is_apt_package_available ipset-persistent; then
    install_apt_packages ipset-persistent
  else
    log "Optional apt package is not available: ipset-persistent"
  fi
}

is_supported_xanmod_codename() {
  local codename="$1"

  case "${codename}" in
    bookworm|trixie|forky|sid|noble|plucky|questing|resolute|stonking|faye|gigi|wilma|xia|zara|zena)
      return 0
      ;;
  esac

  return 1
}

detect_x86_64_psabi_level() {
  local loader

  if [[ "$(uname -m)" != "x86_64" ]]; then
    printf ''
    return
  fi

  for loader in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
    [[ -x "${loader}" ]] || continue

    if "${loader}" --help 2>/dev/null | grep -Fq 'x86-64-v3 (supported'; then
      printf 'v3'
      return
    fi

    if "${loader}" --help 2>/dev/null | grep -Fq 'x86-64-v2 (supported'; then
      printf 'v2'
      return
    fi
  done

  printf 'v1'
}

install_xanmod_lts() {
  local codename psabi_level package tmp_key

  if [[ "${INSTALL_XANMOD_LTS}" -ne 1 ]]; then
    log "Skipping XanMod LTS kernel installation"
    return
  fi

  if [[ "$(uname -m)" != "x86_64" ]]; then
    log "Skipping XanMod LTS: only amd64/x86_64 is supported"
    return
  fi

  codename="$(lsb_release -sc)"
  if ! is_supported_xanmod_codename "${codename}"; then
    log "Skipping XanMod LTS: unsupported distribution codename ${codename}"
    return
  fi

  psabi_level="$(detect_x86_64_psabi_level)"
  if [[ -z "${psabi_level}" ]]; then
    log "Skipping XanMod LTS: unable to detect x86-64 psABI level"
    return
  fi

  package="linux-xanmod-lts-x64${psabi_level}"
  log "Installing XanMod LTS kernel package: ${package}"

  install -d -m 755 /etc/apt/keyrings
  tmp_key="$(mktemp)"
  wget -qO "${tmp_key}" https://dl.xanmod.org/archive.key
  gpg --dearmor --yes -o "${XANMOD_KEYRING}" "${tmp_key}"
  rm -f "${tmp_key}"

  printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "${XANMOD_KEYRING}" "${codename}" > "${XANMOD_SOURCE_LIST}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${package}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed"
  else
    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable --now docker
}

install_oh_my_zsh() {
  if [[ -d /root/.oh-my-zsh ]]; then
    log "Oh My Zsh is already installed"
    return
  fi

  log "Installing Oh My Zsh"
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

install_powerlevel10k() {
  local theme_dir="${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/themes/powerlevel10k"

  if [[ -d "${theme_dir}" ]]; then
    log "Powerlevel10k is already installed"
  else
    log "Installing Powerlevel10k"
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${theme_dir}"
  fi

  if [[ -f /root/.zshrc ]]; then
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' /root/.zshrc
  fi
}

ensure_zsh_plugin() {
  local repo_url="$1"
  local plugin_name="$2"
  local plugin_dir="${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/${plugin_name}"

  if [[ ! -d "${plugin_dir}" ]]; then
    git clone --depth=1 "${repo_url}" "${plugin_dir}"
  fi
}

configure_zsh() {
  log "Configuring Zsh"
  install_oh_my_zsh
  install_powerlevel10k

  ensure_zsh_plugin https://github.com/zsh-users/zsh-autosuggestions zsh-autosuggestions
  ensure_zsh_plugin https://github.com/zsh-users/zsh-syntax-highlighting zsh-syntax-highlighting

  if [[ -f /root/.zshrc ]]; then
    if grep -Eq '^plugins=\(' /root/.zshrc; then
      sed -i 's/^plugins=(.*/plugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)/' /root/.zshrc
    else
      printf '\nplugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)\n' >> /root/.zshrc
    fi
  fi

  if [[ "$(getent passwd root | cut -d: -f7)" != "/bin/zsh" ]]; then
    chsh -s /bin/zsh root
  fi
}

install_speedtest() {
  if dpkg -s speedtest >/dev/null 2>&1; then
    log "Speedtest is already installed"
    return
  fi

  log "Installing Speedtest"
  curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y speedtest
}

configure_authorized_keys() {
  local ssh_dir="/root/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  log "Configuring root authorized_keys"
  install -d -m 700 "${ssh_dir}"
  touch "${auth_keys}"
  chmod 600 "${auth_keys}"

  if grep -Fqx "${SSH_KEY_VALUE}" "${auth_keys}"; then
    log "Public SSH key already exists in authorized_keys"
  else
    printf '%s\n' "${SSH_KEY_VALUE}" >> "${auth_keys}"
    log "Public SSH key added to authorized_keys"
  fi
}

configure_ssh() {
  local sshd_binary tmp_file

  log "Configuring SSH daemon"
  require_command sshd
  detect_ssh_service

  cp -a "${SSHD_CONFIG}" "${SSHD_BACKUP}"
  tmp_file="$(mktemp)"
  awk -v port="${SSH_PORT_VALUE}" '
    function emit_missing() {
      for (key in desired) {
        if (!(key in emitted)) {
          print key " " desired[key]
          emitted[key] = 1
        }
      }
    }
    BEGIN {
      desired["Port"] = port
      desired["PubkeyAuthentication"] = "yes"
      desired["PasswordAuthentication"] = "no"
      desired["KbdInteractiveAuthentication"] = "no"
      desired["ChallengeResponseAuthentication"] = "no"
      desired["PermitRootLogin"] = "prohibit-password"
      desired["PermitEmptyPasswords"] = "no"
      desired["X11Forwarding"] = "no"
      desired["AllowTcpForwarding"] = "yes"
      desired["ClientAliveInterval"] = "300"
      desired["ClientAliveCountMax"] = "2"
      desired["MaxAuthTries"] = "3"
      desired["LoginGraceTime"] = "30"
    }
    /^[[:space:]]*Match[[:space:]]+/ {
      emit_missing()
      in_match = 1
      print
      next
    }
    {
      if (in_match) {
        print
        next
      }

      line = $0
      for (key in desired) {
        pattern = "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]+"
        if (line ~ pattern) {
          if (!(key in emitted)) {
            print key " " desired[key]
            emitted[key] = 1
          }
          next
        }
      }
      print
    }
    END {
      emit_missing()
    }
  ' "${SSHD_CONFIG}" > "${tmp_file}"

  chown --reference="${SSHD_CONFIG}" "${tmp_file}"
  chmod --reference="${SSHD_CONFIG}" "${tmp_file}"
  mv "${tmp_file}" "${SSHD_CONFIG}"

  sshd_binary="$(command -v sshd)"
  if ! "${sshd_binary}" -t; then
    cp -a "${SSHD_BACKUP}" "${SSHD_CONFIG}"
    printf 'sshd configuration validation failed, original config restored\n' >&2
    exit 1
  fi

  systemctl restart "${SSH_SERVICE_NAME}"
}

write_mobile443_config() {
  install -d -m 755 "${MOBILE443_BASE_DIR}" "${MOBILE443_STATE_DIR}" "${MOBILE443_LISTS_DIR}" /etc/iptables

  cat > "${MOBILE443_CONFIG_FILE}" <<EOF
PORTS="${MOBILE443_PORTS}"
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="true"
TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
EOF
  chmod 0644 "${MOBILE443_CONFIG_FILE}"
}

write_default_mobile443_asns() {
  if [[ -s "${MOBILE443_ASNS_FILE}" ]]; then
    log "Keeping existing mobile443 ASN allowlist: ${MOBILE443_ASNS_FILE}"
    return
  fi

  cat > "${MOBILE443_ASNS_FILE}" <<'EOF'
# Mobile-focused allowlist for Russia.
# It includes core mobile operators, selected MVNO paths, and Rostelecom.

# MTS
8359
13174
21365
30922
34351

# Beeline / VimpelCom
3216
16043
16345
42842

# MegaFon core + related
31133
8263
6854
50928
48615
47395
47218
43841
42891
41976
35298
34552
31268
31224
31213
31208
31205
31195
31163
29648
25290
25159
24866
20663
20632
12396
202804

# T2 regional
12958
15378
42437
48092
48190
41330
48092
39374
13116

# Miranda
201776

# Sberbank-Telecom
206673

# Rostelecom
12389

# Sevastar
35816

# T-mobile + Alfa-mobile
205638
214257
202498

# Volna-Mobile
203451
203561

# MCS
47204

# DVF Irkutsk YOTA-mobile
31133

# MOTIV telecom
31499
EOF
  chmod 0644 "${MOBILE443_ASNS_FILE}"
}

write_mobile443_exceptions() {
  local exception
  local tmp_file

  if [[ ${#MOBILE443_EXCEPTIONS[@]} -eq 0 ]]; then
    if [[ -f "${MOBILE443_EXCEPTIONS_FILE}" ]]; then
      log "Keeping existing mobile443 exceptions: ${MOBILE443_EXCEPTIONS_FILE}"
    fi
    return
  fi

  tmp_file="$(mktemp)"

  if [[ -s "${MOBILE443_EXCEPTIONS_FILE}" ]]; then
    cat "${MOBILE443_EXCEPTIONS_FILE}" >> "${tmp_file}"
  fi

  for exception in "${MOBILE443_EXCEPTIONS[@]}"; do
    printf '%s\n' "${exception}" >> "${tmp_file}"
  done

  sort -Vu "${tmp_file}" -o "${tmp_file}"
  install -m 0644 "${tmp_file}" "${MOBILE443_EXCEPTIONS_FILE}"
  rm -f "${tmp_file}"
}

install_mobile443_filter() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  log "Installing mobile443 Traffic Guard and mobile ASN filter"
  write_mobile443_config
  write_default_mobile443_asns
  write_mobile443_exceptions

  install -m 755 "${repo_root}/scripts/mobile443-common.sh" "${MOBILE443_COMMON_TARGET}"
  install -m 755 "${repo_root}/scripts/mobile443-update.sh" "${MOBILE443_UPDATE_TARGET}"
  install -m 755 "${repo_root}/scripts/mobile443-apply-cache.sh" "${MOBILE443_APPLY_TARGET}"
  install -m 755 "${repo_root}/scripts/mobile443-apply-exceptions.sh" "${MOBILE443_APPLY_EXCEPTIONS_TARGET}"
  install -m 644 "${repo_root}/systemd/mobile443-apply.service" "${MOBILE443_APPLY_SERVICE_TARGET}"
  install -m 644 "${repo_root}/systemd/mobile443-update.service" "${MOBILE443_UPDATE_SERVICE_TARGET}"
  install -m 644 "${repo_root}/systemd/mobile443-update.timer" "${MOBILE443_TIMER_TARGET}"

  systemctl daemon-reload
  systemctl enable mobile443-apply.service
  systemctl enable --now mobile443-update.timer

  "${MOBILE443_UPDATE_TARGET}"
}

ensure_iptables_rule() {
  local rule=("$@")
  if ! iptables -C "${rule[@]}" >/dev/null 2>&1; then
    iptables -I "${rule[@]}"
  fi
}

ensure_iptables_mangle_rule() {
  local rule=("$@")
  if ! iptables -t mangle -C "${rule[@]}" >/dev/null 2>&1; then
    iptables -t mangle -I "${rule[@]}"
  fi
}

ensure_docker_user_rule() {
  local rule=("$@")

  if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    return
  fi

  if ! iptables -C DOCKER-USER "${rule[@]}" >/dev/null 2>&1; then
    iptables -I DOCKER-USER "${rule[@]}"
  fi
}

flush_iptables_comment_rules() {
  local table="$1"
  local chain="$2"
  local comment="$3"
  local prefix="-A ${chain} "
  local rule_spec

  while read -r rule_spec; do
    [[ -n "${rule_spec}" ]] || continue
    rule_spec="${rule_spec#"${prefix}"}"

    if [[ -n "${table}" ]]; then
      # shellcheck disable=SC2086
      iptables -t "${table}" -D "${chain}" ${rule_spec} 2>/dev/null || true
    else
      # shellcheck disable=SC2086
      iptables -D "${chain}" ${rule_spec} 2>/dev/null || true
    fi
  done < <(
    if [[ -n "${table}" ]]; then
      iptables -t "${table}" -S "${chain}" 2>/dev/null
    else
      iptables -S "${chain}" 2>/dev/null
    fi | grep -F -- "--comment \"${comment}\"" || true
  )
}

ensure_iptables_chain() {
  local chain="$1"

  if iptables -nL "${chain}" >/dev/null 2>&1; then
    iptables -F "${chain}"
  else
    iptables -N "${chain}"
  fi
}

insert_vpn_defense_input_rules() {
  local rules=(
    "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment vpn-defense"
    "-i lo -j ACCEPT -m comment --comment vpn-defense"
    "-p tcp -m tcp --dport ${SSH_PORT_VALUE} -j ACCEPT -m comment --comment vpn-defense"
    "-m conntrack --ctstate INVALID -j DROP -m comment --comment vpn-defense"
    "-p tcp -m tcp --syn -m multiport --dports 80,443,8443 -j VPN_SYN_LIM -m comment --comment vpn-defense"
    "-p udp -m multiport --sports 19,53,123,389,1900,11211,5060,1194 -j VPN_UDP_AMP -m comment --comment vpn-defense"
    "-p icmp --icmp-type echo-request -m limit --limit 30/sec --limit-burst 60 -j ACCEPT -m comment --comment vpn-defense"
    "-p icmp --icmp-type echo-request -j DROP -m comment --comment vpn-defense"
  )
  local i

  for (( i = ${#rules[@]} - 1; i >= 0; i-- )); do
    # shellcheck disable=SC2086
    iptables -I INPUT 1 ${rules[i]}
  done
}

configure_vpn_defense_firewall() {
  if [[ "${INSTALL_VPN_DEFENSE}" -ne 1 ]]; then
    return
  fi

  log "Applying VPN defense firewall rules"
  ensure_iptables_chain VPN_SYN_LIM
  ensure_iptables_chain VPN_UDP_AMP

  iptables -A VPN_SYN_LIM -m hashlimit --hashlimit-above "${DEFENSE_SYN_RATE}/sec" --hashlimit-burst "${DEFENSE_SYN_BURST}" \
    --hashlimit-mode srcip --hashlimit-name vpn_syn --hashlimit-htable-expire 30000 -j DROP
  iptables -A VPN_SYN_LIM -j RETURN

  iptables -A VPN_UDP_AMP -m hashlimit --hashlimit-above 100/sec --hashlimit-burst 200 \
    --hashlimit-mode srcip --hashlimit-name vpn_udp_amp --hashlimit-htable-expire 30000 -j DROP
  iptables -A VPN_UDP_AMP -j RETURN

  flush_iptables_comment_rules "" INPUT vpn-defense
  insert_vpn_defense_input_rules

  netfilter-persistent save >/dev/null
}

apply_firewall_rules() {
  log "Applying firewall rules"

  ensure_iptables_rule INPUT -m conntrack --ctstate INVALID -j DROP
  ensure_iptables_rule FORWARD -m conntrack --ctstate INVALID -j DROP
  ensure_iptables_rule INPUT -p icmp --icmp-type echo-request -j DROP
  ensure_iptables_mangle_rule FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ensure_docker_user_rule -m conntrack --ctstate INVALID -j DROP

  netfilter-persistent save >/dev/null
}

print_summary() {
  local timer_status

  timer_status="$(systemctl status mobile443-update.timer --no-pager --lines=6 2>/dev/null || true)"

  printf '\n===== DONE =====\n\n'
  printf 'Reconnect using:\n'
  printf 'ssh -p %s root@%s\n\n' "${SSH_PORT_VALUE}" "${HOSTNAME_VALUE}"
  printf 'mobile443 timer status:\n%s\n\n' "${timer_status}"
  printf 'Manual mobile443 update:\n%s\n\n' "${MOBILE443_UPDATE_TARGET}"
  printf 'Filtered VPN ports: %s\n\n' "${MOBILE443_PORTS}"
  if [[ "${INSTALL_VPN_DEFENSE}" -eq 1 ]]; then
    printf 'VPN defense profile:\n'
    printf '  conntrack max: %s\n' "${DEFENSE_CT_MAX}"
    printf '  conntrack buckets: %s\n' "${DEFENSE_CT_BUCKETS}"
    printf '  somaxconn: %s\n' "${DEFENSE_SOMAXCONN}"
    printf '  tcp_max_syn_backlog: %s\n' "${DEFENSE_SYN_BACKLOG}"
    printf '  netdev_max_backlog: %s\n' "${DEFENSE_NETDEV_BACKLOG}"
    if [[ -n "${DEFENSE_RPS_INTERFACE}" ]]; then
      printf '  RPS/RFS: interface=%s mask=%s flow_entries=%s per_queue=%s\n' "${DEFENSE_RPS_INTERFACE}" "${DEFENSE_RPS_CPU_MASK}" "${DEFENSE_RPS_FLOW_TOTAL}" "${DEFENSE_RPS_FLOW_Q}"
    fi
    printf '  SYN hashlimit: %s/sec burst %s on 80,443,8443\n\n' "${DEFENSE_SYN_RATE}" "${DEFENSE_SYN_BURST}"
  fi
  if [[ "${INSTALL_XANMOD_LTS}" -eq 1 ]]; then
    printf 'XanMod LTS was requested. Reboot is required to activate the new kernel.\n'
    printf 'Automatic reboot: %s\n\n' "$([[ "${AUTO_REBOOT_AFTER_BOOTSTRAP}" -eq 1 ]] && printf 'yes' || printf 'no')"
  fi
  printf 'Then run:\n'
  printf 'p10k configure\n'
}

maybe_reboot() {
  if [[ "${AUTO_REBOOT_AFTER_BOOTSTRAP}" -ne 1 ]]; then
    return
  fi

  log "Rebooting to activate XanMod LTS kernel"
  systemctl reboot
}

main() {
  require_root
  require_command hostnamectl
  require_command systemctl
  require_command apt-get
  require_command dpkg-query

  printf '===== VPN NODE BOOTSTRAP =====\n'

  ask_hostname
  ask_ssh_port
  ask_ssh_key
  ask_vpn_defense
  ask_mobile443_exceptions
  ask_xanmod_lts
  ask_xanmod_reboot

  configure_hostname
  configure_sysctl
  update_system
  install_packages
  configure_vpn_defense_sysctl
  configure_vpn_rps_rfs
  require_command curl
  require_command iptables
  require_command ipset
  require_command jq
  install_xanmod_lts
  install_docker
  configure_zsh
  configure_authorized_keys
  configure_ssh
  install_speedtest
  install_mobile443_filter
  apply_firewall_rules
  configure_vpn_defense_firewall
  print_summary
  maybe_reboot
}

main "$@"
