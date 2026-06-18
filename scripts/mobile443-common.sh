#!/usr/bin/env bash
# shellcheck disable=SC2034

set -Eeuo pipefail

readonly CONFIG_FILE="/opt/mobile443/config.conf"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

readonly BASE_DIR="/opt/mobile443"
readonly STATE_DIR="/var/lib/mobile443"
readonly LISTS_DIR="${BASE_DIR}/lists"
readonly ASNS_FILE="${BASE_DIR}/asns.conf"
readonly EXCEPTIONS_FILE="${BASE_DIR}/exceptions.conf"
readonly ALLOW_CACHE_FILE="${STATE_DIR}/prefixes.txt"
readonly LOCK_FILE="${STATE_DIR}/lock"

readonly IPSET_EXCEPTIONS_NAME="mobile443_exceptions"
readonly IPSET_EXCEPTIONS_TMP_NAME="${IPSET_EXCEPTIONS_NAME}_tmp"
readonly IPSET_ALLOW_NAME="allowed_mobile_443"
readonly IPSET_ALLOW_TMP_NAME="${IPSET_ALLOW_NAME}_tmp"
readonly IPSET_GOV_NAME="traf_guard_government"
readonly IPSET_GOV_TMP_NAME="${IPSET_GOV_NAME}_tmp"
readonly IPSET_ANTISCANNER_NAME="traf_guard_antiscanner"
readonly IPSET_ANTISCANNER_TMP_NAME="${IPSET_ANTISCANNER_NAME}_tmp"

readonly PRECHECK_CHAIN="TRAF_GUARD_PRECHECK"
readonly CHAIN_NAME="FILTER_MOBILE_443"
readonly LOG_PREFIX="MOBILE443_BLOCK: "
readonly GOV_LOG_PREFIX="MOBILE443_TG_GOV: "
readonly ANTISCANNER_LOG_PREFIX="MOBILE443_TG_SCAN: "

readonly GOV_LIST_FILE="${LISTS_DIR}/government_networks.list"
readonly ANTISCANNER_LIST_FILE="${LISTS_DIR}/antiscanner.list"

export ASNS_FILE EXCEPTIONS_FILE ALLOW_CACHE_FILE LOCK_FILE GOV_LIST_FILE ANTISCANNER_LIST_FILE

TRAF_GUARD_BASE_URL="${TRAF_GUARD_BASE_URL:-https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public}"
GOV_LIST_URL="${GOV_LIST_URL:-${TRAF_GUARD_BASE_URL}/government_networks.list}"
ANTISCANNER_LIST_URL="${ANTISCANNER_LIST_URL:-${TRAF_GUARD_BASE_URL}/antiscanner.list}"

ENABLE_TRAF_GUARD="${ENABLE_TRAF_GUARD:-true}"
ENABLE_TRAF_GUARD_GOVERNMENT="${ENABLE_TRAF_GUARD_GOVERNMENT:-true}"
ENABLE_TRAF_GUARD_ANTISCANNER="${ENABLE_TRAF_GUARD_ANTISCANNER:-true}"
ENABLE_MOBILE_ALLOW="${ENABLE_MOBILE_ALLOW:-true}"

read -r -a PORT_LIST <<< "${PORTS:-443}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Не найдена команда: %s\n' "$1" >&2
    exit 1
  fi
}

bool_is_true() {
  [[ "${1:-false}" == "true" ]]
}

ensure_deps() {
  need_cmd curl
  need_cmd ipset
  need_cmd iptables
  need_cmd flock
  need_cmd jq
  need_cmd sort
  need_cmd grep
}

ensure_dirs() {
  install -d -m 755 "${BASE_DIR}" "${STATE_DIR}" "${LISTS_DIR}"
}

ensure_set_pair() {
  local set_name="$1"
  local tmp_name="$2"

  ipset create "${set_name}" hash:net family inet hashsize 65536 maxelem 524288 -exist
  ipset create "${tmp_name}" hash:net family inet hashsize 65536 maxelem 524288 -exist
}

ensure_ipsets() {
  ensure_set_pair "${IPSET_EXCEPTIONS_NAME}" "${IPSET_EXCEPTIONS_TMP_NAME}"

  if bool_is_true "${ENABLE_TRAF_GUARD}"; then
    if bool_is_true "${ENABLE_TRAF_GUARD_GOVERNMENT}"; then
      ensure_set_pair "${IPSET_GOV_NAME}" "${IPSET_GOV_TMP_NAME}"
    fi
    if bool_is_true "${ENABLE_TRAF_GUARD_ANTISCANNER}"; then
      ensure_set_pair "${IPSET_ANTISCANNER_NAME}" "${IPSET_ANTISCANNER_TMP_NAME}"
    fi
  fi

  if bool_is_true "${ENABLE_MOBILE_ALLOW}"; then
    ensure_set_pair "${IPSET_ALLOW_NAME}" "${IPSET_ALLOW_TMP_NAME}"
  fi
}

count_lines() {
  local file="$1"

  if [[ ! -f "${file}" ]]; then
    printf '0\n'
    return
  fi

  wc -l < "${file}" | tr -d ' '
}

validate_ipv4_cidr() {
  local prefix="$1"
  local ip mask octet
  local IFS=.

  [[ "${prefix}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${prefix%/*}"
  mask="${prefix#*/}"

  [[ "${mask}" =~ ^[0-9]+$ ]] || return 1
  (( mask >= 0 && mask <= 32 )) || return 1

  for octet in ${ip}; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

download_and_validate_list() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local raw_tmp clean_tmp line normalized valid_count old_count min_safe

  raw_tmp="$(mktemp)"
  clean_tmp="$(mktemp)"
  trap 'rm -f "${raw_tmp}" "${clean_tmp}"' RETURN

  log "Скачивается ${label}: ${url}"
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "${url}" -o "${raw_tmp}"

  valid_count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    normalized="$(printf '%s\n' "${line}" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${normalized}" ]] || continue

    if validate_ipv4_cidr "${normalized}"; then
      printf '%s\n' "${normalized}" >> "${clean_tmp}"
      valid_count=$((valid_count + 1))
    else
      log "ПРЕДУПРЕЖДЕНИЕ ${label}: пропущена некорректная запись '${normalized}'"
    fi
  done < "${raw_tmp}"

  if (( valid_count == 0 )); then
    log "ОШИБКА ${label}: нет корректных CIDR-записей"
    return 1
  fi

  sort -Vu "${clean_tmp}" -o "${clean_tmp}"
  old_count="$(count_lines "${destination}")"
  if (( old_count > 0 )); then
    min_safe=$((old_count * 70 / 100))
    if (( valid_count < min_safe )); then
      log "ОШИБКА ${label}: слишком мало записей после обновления (${valid_count} < ${min_safe})"
      return 1
    fi
  fi

  install -m 0644 "${clean_tmp}" "${destination}"
  log "${label}: записей ${valid_count}"
}

rebuild_ipset_from_file() {
  local target_set="$1"
  local tmp_set="$2"
  local file="$3"
  local label="$4"
  local prefix

  if [[ ! -f "${file}" ]]; then
    log "ПРЕДУПРЕЖДЕНИЕ ${label}: файл не найден: ${file}"
    return 1
  fi

  ipset flush "${tmp_set}"
  while IFS= read -r prefix || [[ -n "${prefix}" ]]; do
    [[ -n "${prefix}" ]] || continue
    ipset add "${tmp_set}" "${prefix}" -exist
  done < "${file}"

  ipset swap "${tmp_set}" "${target_set}"
  ipset flush "${tmp_set}"
  log "${label} загружен в ${target_set}"
}

delete_jump_if_exists() {
  local chain="$1"
  local proto="$2"
  local port="$3"

  while iptables -C "${chain}" -p "${proto}" --dport "${port}" -j "${CHAIN_NAME}" 2>/dev/null; do
    iptables -D "${chain}" -p "${proto}" --dport "${port}" -j "${CHAIN_NAME}"
  done
}

prepare_chains() {
  iptables -N "${PRECHECK_CHAIN}" 2>/dev/null || true
  iptables -F "${PRECHECK_CHAIN}"

  if bool_is_true "${ENABLE_TRAF_GUARD}"; then
    if bool_is_true "${ENABLE_TRAF_GUARD_GOVERNMENT}"; then
      iptables -A "${PRECHECK_CHAIN}" -m set --match-set "${IPSET_GOV_NAME}" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "${GOV_LOG_PREFIX}" --log-level 4
      iptables -A "${PRECHECK_CHAIN}" -m set --match-set "${IPSET_GOV_NAME}" src -j DROP
    fi
    if bool_is_true "${ENABLE_TRAF_GUARD_ANTISCANNER}"; then
      iptables -A "${PRECHECK_CHAIN}" -m set --match-set "${IPSET_ANTISCANNER_NAME}" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "${ANTISCANNER_LOG_PREFIX}" --log-level 4
      iptables -A "${PRECHECK_CHAIN}" -m set --match-set "${IPSET_ANTISCANNER_NAME}" src -j DROP
    fi
  fi

  iptables -N "${CHAIN_NAME}" 2>/dev/null || true
  iptables -F "${CHAIN_NAME}"
  iptables -A "${CHAIN_NAME}" -m set --match-set "${IPSET_EXCEPTIONS_NAME}" src -j ACCEPT
  iptables -A "${CHAIN_NAME}" -j "${PRECHECK_CHAIN}"

  if bool_is_true "${ENABLE_MOBILE_ALLOW}"; then
    iptables -A "${CHAIN_NAME}" -m set --match-set "${IPSET_ALLOW_NAME}" src -j ACCEPT
    iptables -A "${CHAIN_NAME}" -m limit --limit 30/min --limit-burst 10 \
      -j LOG --log-prefix "${LOG_PREFIX}" --log-level 4
    iptables -A "${CHAIN_NAME}" -j DROP
  else
    iptables -A "${CHAIN_NAME}" -j RETURN
  fi
}

attach_chain() {
  local chain port

  for port in "${PORT_LIST[@]}"; do
    for chain in INPUT FORWARD; do
      delete_jump_if_exists "${chain}" tcp "${port}"
      delete_jump_if_exists "${chain}" udp "${port}"
      iptables -I "${chain}" 1 -p tcp --dport "${port}" -j "${CHAIN_NAME}"
      iptables -I "${chain}" 1 -p udp --dport "${port}" -j "${CHAIN_NAME}"
    done

    if iptables -nL DOCKER-USER >/dev/null 2>&1; then
      delete_jump_if_exists DOCKER-USER tcp "${port}"
      delete_jump_if_exists DOCKER-USER udp "${port}"
      iptables -I DOCKER-USER 1 -p tcp --dport "${port}" -j "${CHAIN_NAME}"
      iptables -I DOCKER-USER 1 -p udp --dport "${port}" -j "${CHAIN_NAME}"
    fi
  done
}

apply_rules() {
  ensure_dirs
  ensure_ipsets
  prepare_chains
  attach_chain
}
