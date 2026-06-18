#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ARCHIVE_URL="https://codeload.github.com/wh3r3ar3you/init-mobile443/tar.gz/refs/heads/main"

PACKAGE_MANAGER=""
PACKAGE_INDEX_UPDATED=0

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf 'Run as root\n' >&2
    exit 1
  fi
}

detect_package_manager() {
  local manager

  for manager in apt-get dnf yum zypper apk pacman; do
    if command -v "${manager}" >/dev/null 2>&1; then
      PACKAGE_MANAGER="${manager}"
      return
    fi
  done

  PACKAGE_MANAGER=""
}

update_package_index() {
  if [[ "${PACKAGE_INDEX_UPDATED}" -eq 1 ]]; then
    return
  fi

  case "${PACKAGE_MANAGER}" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
    apk)
      apk update
      ;;
    pacman)
      pacman -Sy --noconfirm
      ;;
  esac

  PACKAGE_INDEX_UPDATED=1
}

install_packages() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  if [[ -z "${PACKAGE_MANAGER}" ]]; then
    printf 'Unable to install missing prerequisites automatically: supported package manager not found\n' >&2
    exit 1
  fi

  update_package_index

  case "${PACKAGE_MANAGER}" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install --no-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    pacman)
      pacman -S --noconfirm --needed "$@"
      ;;
  esac
}

ensure_command() {
  local cmd="$1"
  shift

  if command -v "${cmd}" >/dev/null 2>&1; then
    return
  fi

  printf 'Installing missing prerequisite: %s\n' "${cmd}"
  install_packages "$@"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'Failed to install required command: %s\n' "${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}

download_archive() {
  local archive_path="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_ARCHIVE_URL}" -o "${archive_path}"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "${archive_path}" "${REPO_ARCHIVE_URL}"
    return
  fi

  printf 'Neither curl nor wget is available after prerequisite installation\n' >&2
  exit 1
}

main() {
  trap cleanup EXIT

  require_root
  detect_package_manager
  ensure_command bash bash
  ensure_command tar tar

  if [[ ! -e /etc/ssl/certs/ca-certificates.crt ]]; then
    printf 'Installing missing prerequisite: ca-certificates\n'
    install_packages ca-certificates
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    printf 'Installing missing prerequisite: curl\n'
    install_packages curl
  fi

  WORKDIR="$(mktemp -d)"
  mkdir -p "${WORKDIR}/init-mobile443"
  download_archive "${WORKDIR}/init-mobile443.tar.gz"
  tar -xzf "${WORKDIR}/init-mobile443.tar.gz" --strip-components=1 -C "${WORKDIR}/init-mobile443"
  cd "${WORKDIR}/init-mobile443"
  exec bash ./bootstrap.sh
}

main "$@"
