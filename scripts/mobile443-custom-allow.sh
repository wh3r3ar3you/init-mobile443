#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/mobile443-common.sh
source /usr/local/sbin/mobile443-common.sh

readonly CUSTOM_ALLOW_FILE="${BASE_DIR}/custom-allow.conf"

normalize_custom_allow_entry() {
  local entry="$1"

  if [[ "${entry}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    entry="${entry}/32"
  fi

  validate_ipv4_cidr "${entry}" || return 1
  printf '%s\n' "${entry}"
}

apply_custom_allow() {
  local line normalized count=0

  [[ -f "${CUSTOM_ALLOW_FILE}" ]] || return 0

  ipset create "${IPSET_EXCEPTIONS_NAME}" hash:net family inet hashsize 65536 maxelem 524288 -exist

  while IFS= read -r line || [[ -n "${line}" ]]; do
    normalized="$(printf '%s\n' "${line}" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${normalized}" ]] || continue

    if ! normalized="$(normalize_custom_allow_entry "${normalized}")"; then
      log "ПРЕДУПРЕЖДЕНИЕ: в custom allow пропущена некорректная запись '${line}'"
      continue
    fi

    ipset add "${IPSET_EXCEPTIONS_NAME}" "${normalized}" -exist
    count=$((count + 1))
  done < "${CUSTOM_ALLOW_FILE}"

  log "Custom allow mobile443 применен: ${count}"
}

need_cmd ipset
need_cmd sed
ensure_dirs
apply_custom_allow
