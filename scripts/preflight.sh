#!/usr/bin/env bash
# Safety checks that must pass before hardening. These exist because STIG
# remediation disables root SSH login, requires sudo passwords, and enables
# account lockout -- all of which can lock you out of a box with no usable admin.
#   usage: preflight.sh --admin-user NAME
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

ADMIN_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$ADMIN_USER" ]] || die "--admin-user is required (a non-root wheel user you will log in as after hardening)."

fail=0
bad() { warn "$*"; fail=1; }

# --- OS ----------------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "rocky" ]] || bad "Not Rocky Linux (ID=${ID:-?}). This project targets Rocky 10."
[[ "${VERSION_ID:-}" == 10* ]] || bad "Not a 10.x release (VERSION_ID=${VERSION_ID:-?})."
[[ "${VERSION_ID:-}" == "10.2" ]] || warn "Tested target is 10.2; running ${VERSION_ID:-?}."
# The RHEL 10 SCAP content decides applicability via the redhat-release provide.
rpm -q --whatprovides redhat-release >/dev/null 2>&1 \
  || bad "Nothing provides 'redhat-release'; RHEL 10 SCAP content may mark every rule not-applicable."

# --- Admin account that survives hardening --------------------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  bad "User '$ADMIN_USER' does not exist."
else
  [[ "$ADMIN_USER" != root ]] || bad "Admin user must not be root (root SSH login gets disabled)."
  id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx wheel \
    || bad "'$ADMIN_USER' is not in group wheel (no sudo)."
  hash="$(getent shadow "$ADMIN_USER" | cut -d: -f2)"
  case "$hash" in
    ''|'!'*|'*'*) bad "'$ADMIN_USER' has no usable password. STIG removes NOPASSWD sudo, so a password is mandatory: passwd $ADMIN_USER" ;;
  esac
fi

# --- Resources ------------------------------------------------------------------
avail_mb="$(df -Pm /var | awk 'NR==2{print $4}')"
[[ "$avail_mb" -ge 1024 ]] || bad "Less than 1 GiB free on /var (${avail_mb} MiB)."
dnf -q makecache >/dev/null 2>&1 || bad "dnf cannot reach its repositories; remediation installs/removes packages."

# --- Partitioning (reported, not fatal: cannot be fixed on a live system) -------------
missing=()
for m in /home /tmp /var /var/log /var/log/audit /var/tmp; do
  findmnt -n --target "$m" -o TARGET | grep -qx "$m" || missing+=("$m")
done
if ((${#missing[@]})); then
  warn "Not separate mount points: ${missing[*]}"
  warn "STIG partition_for_* findings will remain open. Use kickstart/rocky10-stig.ks on a fresh install."
fi

# --- Session --------------------------------------------------------------------
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  warn "Running over SSH. Keep this session open and verify a second login as '$ADMIN_USER' afterwards;"
  warn "root SSH login will be disabled and account lockout enabled (3 failures -> locked)."
fi

((fail == 0)) || die "Preflight failed. Fix the items above and re-run."
log "Preflight OK."
