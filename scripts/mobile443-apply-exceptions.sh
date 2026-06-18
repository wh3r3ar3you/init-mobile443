#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/mobile443-common.sh
source /usr/local/sbin/mobile443-common.sh

normalize_exception() {
  local entry="$1"

  if [[ "${entry}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    entry="${entry}/32"
  fi

  validate_ipv4_cidr "${entry}" || return 1
  printf '%s\n' "${entry}"
}

load_exceptions() {
  local tmp_file line normalized

  tmp_file="$(mktemp)"
  trap 'rm -f "${tmp_file}"' EXIT

  if [[ -f "${EXCEPTIONS_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      normalized="$(printf '%s\n' "${line}" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "${normalized}" ]] || continue

      if normalize_exception "${normalized}" >> "${tmp_file}"; then
        continue
      fi

      log "WARN exceptions: skip invalid entry '${normalized}'"
    done < "${EXCEPTIONS_FILE}"
  fi

  sort -Vu "${tmp_file}" -o "${tmp_file}"

  ipset flush "${IPSET_EXCEPTIONS_TMP_NAME}"
  while IFS= read -r normalized || [[ -n "${normalized}" ]]; do
    [[ -n "${normalized}" ]] || continue
    ipset add "${IPSET_EXCEPTIONS_TMP_NAME}" "${normalized}" -exist
  done < "${tmp_file}"

  ipset swap "${IPSET_EXCEPTIONS_TMP_NAME}" "${IPSET_EXCEPTIONS_NAME}"
  ipset flush "${IPSET_EXCEPTIONS_TMP_NAME}"
  log "mobile443 exceptions loaded: $(count_lines "${tmp_file}")"
}

ensure_deps
ensure_dirs
ensure_ipsets
load_exceptions
