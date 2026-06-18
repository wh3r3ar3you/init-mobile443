#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/mobile443-common.sh
source /usr/local/sbin/mobile443-common.sh

TMP_RAW=""
TMP_CLEAN=""

cleanup_tmp() {
  rm -f "${TMP_RAW:-}" "${TMP_CLEAN:-}"
}

update_mobile_allowlist() {
  local asn new_count old_count min_safe

  if [[ ! -f "${ASNS_FILE}" ]]; then
    printf 'ASN file not found: %s\n' "${ASNS_FILE}" >&2
    exit 1
  fi

  TMP_RAW="$(mktemp)"
  TMP_CLEAN="$(mktemp)"
  trap cleanup_tmp EXIT

  log "Fetching announced prefixes from RIPEstat"

  while IFS= read -r asn || [[ -n "${asn}" ]]; do
    [[ -z "${asn}" || "${asn}" =~ ^# ]] && continue
    log "Fetching AS${asn}"
    curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" \
      | jq -r '.data.prefixes[]?.prefix // empty' >> "${TMP_RAW}" || true
  done < "${ASNS_FILE}"

  sort -Vu "${TMP_RAW}" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
    > "${TMP_CLEAN}" || true

  new_count="$(count_lines "${TMP_CLEAN}")"
  old_count="$(count_lines "${ALLOW_CACHE_FILE}")"

  log "Collected mobile prefixes: new=${new_count}, old=${old_count}"

  if (( new_count < 500 )); then
    log "Refusing mobile allowlist update: too few prefixes"
    exit 1
  fi

  if (( old_count > 0 )); then
    min_safe=$((old_count * 70 / 100))
    if (( new_count < min_safe )); then
      log "Refusing mobile allowlist update: new prefix count dropped too much (need >= ${min_safe})"
      exit 1
    fi
  fi

  rebuild_ipset_from_file "${IPSET_ALLOW_NAME}" "${IPSET_ALLOW_TMP_NAME}" "${TMP_CLEAN}" "mobile allowlist"
  install -m 0644 "${TMP_CLEAN}" "${ALLOW_CACHE_FILE}"
  cleanup_tmp
  trap - EXIT
}

mkdir -p "${STATE_DIR}"
exec 9>"${LOCK_FILE}"
flock -n 9 || {
  log "Another mobile443 job is already running"
  exit 0
}

ensure_deps
ensure_dirs
ensure_ipsets

if bool_is_true "${ENABLE_TRAF_GUARD}" && bool_is_true "${ENABLE_TRAF_GUARD_GOVERNMENT}"; then
  download_and_validate_list "${GOV_LIST_URL}" "${GOV_LIST_FILE}" "government_networks"
  rebuild_ipset_from_file "${IPSET_GOV_NAME}" "${IPSET_GOV_TMP_NAME}" "${GOV_LIST_FILE}" "government_networks"
fi

if bool_is_true "${ENABLE_TRAF_GUARD}" && bool_is_true "${ENABLE_TRAF_GUARD_ANTISCANNER}"; then
  download_and_validate_list "${ANTISCANNER_LIST_URL}" "${ANTISCANNER_LIST_FILE}" "antiscanner"
  rebuild_ipset_from_file "${IPSET_ANTISCANNER_NAME}" "${IPSET_ANTISCANNER_TMP_NAME}" "${ANTISCANNER_LIST_FILE}" "antiscanner"
fi

if bool_is_true "${ENABLE_MOBILE_ALLOW}"; then
  update_mobile_allowlist
fi

/usr/local/sbin/mobile443-apply-exceptions.sh
apply_rules

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null || log "netfilter-persistent save failed"
fi

log "Update complete"
