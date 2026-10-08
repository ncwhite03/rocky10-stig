#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.

_c() { [[ -t 2 ]] && printf '\033[%sm' "$1" || true; }
log()  { echo "$(_c 32)[+]$(_c 0) $*" >&2; }
warn() { echo "$(_c 33)[!]$(_c 0) $*" >&2; }
die()  { echo "$(_c 31)[x]$(_c 0) $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

# Resolve repo root and load config regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/config/stig.conf"

state_has() { [[ -f "${STATE_DIR}/$1" ]]; }
state_set() { mkdir -p "$STATE_DIR"; chmod 0700 "$STATE_DIR"; date -u +%FT%TZ > "${STATE_DIR}/$1"; }

# Echo path of the Rocky datastream (installed by the scap-security-guide package).
find_datastream() {
  [[ -f $SSG_DATASTREAM ]] && { echo "$SSG_DATASTREAM"; return 0; }
  return 1
}
