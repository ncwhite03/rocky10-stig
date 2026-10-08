#!/usr/bin/env bash
# Rocky Linux 10 -> DISA RHEL 10 STIG, end to end.
#
#   harden.sh --admin-user NAME [--reboot] [--yes] [--scan-only] [--grub-password-file F]
#
# Stages (resumable; state in /var/lib/rocky10-stig):
#   1. preflight  - refuse to run if it could lock you out
#   2. backup     - tar of /etc, /boot/loader, grub config
#   3. fips       - enable FIPS 140 mode (needs one reboot)
#   4. remediate  - oscap remediation of the tailored STIG profile, twice, + supplemental.sh
#   5. verify     - scan, HTML report, list of remaining failures
#
# Exit codes: 0 done, 3 reboot required (re-run afterwards), other = error.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

ADMIN_USER=""; DO_REBOOT=0; ASSUME_YES=0; SCAN_ONLY=0; GRUB_PW_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --reboot) DO_REBOOT=1; shift ;;
    --yes|--unattended) ASSUME_YES=1; shift ;;
    --scan-only) SCAN_ONLY=1; shift ;;
    --grub-password-file) GRUB_PW_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$ADMIN_USER" ]] || die "--admin-user is required"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"; chmod 0700 "$STATE_DIR" "$BACKUP_DIR"
exec > >(tee -a "${LOG_DIR}/harden.log") 2>&1

reboot_or_exit() {
  if ((DO_REBOOT)); then log "Rebooting in 10s ($1)..."; sleep 10; systemctl reboot; exit 0; fi
  warn "Reboot required ($1). Reboot, then re-run this script to continue."
  exit 3
}

# ---------------------------------------------------------------------------
"${REPO_ROOT}/scripts/preflight.sh" --admin-user "$ADMIN_USER"

if ((!ASSUME_YES && !SCAN_ONLY)) && ! state_has remediated; then
  read -r -p "This will harden the system (root SSH off, lockout on, FIPS on, services/packages removed). Type YES: " a
  [[ "$a" == YES ]] || die "Aborted."
fi

# ---------------------------------------------------------------------------
dnf -y -q install openscap-scanner scap-security-guide >/dev/null
DS="$(find_datastream)" || die "$SSG_DATASTREAM missing even after installing scap-security-guide."
log "Using SCAP content: $DS"

# Build the tailored profile (base STIG profile minus excluded_rules.txt) --------
BASE_ID="xccdf_org.ssgproject.content_profile_${STIG_PROFILE}"
TAILORED_ID="${BASE_ID}_rocky10"
TAILORING="${STATE_DIR}/tailoring.xml"

excluded=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
  [[ -n $line ]] && excluded+=("$line")
done < "${REPO_ROOT}/config/excluded_rules.txt"

# grub2_password needs a hash we can't invent; leave it out unless a password is supplied.
[[ -z "$GRUB_PW_FILE" ]] && excluded+=(grub2_password)

{
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<xccdf-1.2:Tailoring xmlns:xccdf-1.2="http://checklists.nist.gov/xccdf/1.2" id="xccdf_rocky10-stig_tailoring_default">
  <xccdf-1.2:benchmark href="$DS"/>
  <xccdf-1.2:version time="$(date -u +%FT%T)">1</xccdf-1.2:version>
  <xccdf-1.2:Profile id="${TAILORED_ID}" extends="${BASE_ID}">
    <xccdf-1.2:title>DISA RHEL 10 STIG (tailored for Rocky Linux 10)</xccdf-1.2:title>
    <xccdf-1.2:description>Base STIG profile minus rules listed in config/excluded_rules.txt.</xccdf-1.2:description>
XML
  for r in "${excluded[@]}"; do
    if grep -q "xccdf_org.ssgproject.content_rule_${r}\"" "$DS"; then
      echo "    <xccdf-1.2:select idref=\"xccdf_org.ssgproject.content_rule_${r}\" selected=\"false\"/>"
      log "Excluding rule: $r" >&2
    fi
  done
  echo "  </xccdf-1.2:Profile>"
  echo "</xccdf-1.2:Tailoring>"
} > "$TAILORING"
echo "$TAILORED_ID" > "${STATE_DIR}/profile_id"

if ((SCAN_ONLY)); then "${REPO_ROOT}/scripts/verify.sh"; exit 0; fi

# ---------------------------------------------------------------------------
if ! state_has backup; then
  b="${BACKUP_DIR}/pre-stig-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$b" --warning=no-file-changed /etc /boot/loader /boot/grub2 2>/dev/null || true
  chmod 0600 "$b"; log "Backup: $b"; state_set backup
  warn "A VM snapshot is still the best rollback. Take one now if you haven't."
fi

# --- FIPS ---------------------------------------------------------------------
if [[ "$(cat /proc/sys/crypto/fips_enabled)" != 1 ]]; then
  state_has fips_requested && die "FIPS was requested earlier but kernel still reports fips_enabled=0. Check: fips-mode-setup --check; dmesg | grep -i fips"
  log "Enabling FIPS mode..."
  fips-mode-setup --enable
  state_set fips_requested
  reboot_or_exit "FIPS mode"
fi
log "FIPS mode active."

# --- GRUB password (optional) ------------------------------------------------------
if [[ -n "$GRUB_PW_FILE" ]]; then
  pw="$(cat "$GRUB_PW_FILE")"
  printf '%s\n%s\n' "$pw" "$pw" | grub2-setpassword
  unset pw
fi

# --- Remediate --------------------------------------------------------------------
if ! state_has remediated; then
  for pass in 1 2; do
    log "Remediation pass $pass/2 (this takes a while)..."
    rc=0
    oscap xccdf eval --remediate --profile "$TAILORED_ID" --tailoring-file "$TAILORING" \
      --results "${LOG_DIR}/remediate-pass${pass}.xml" "$DS" >"${LOG_DIR}/remediate-pass${pass}.log" 2>&1 || rc=$?
    [[ $rc -le 2 ]] || { tail -20 "${LOG_DIR}/remediate-pass${pass}.log"; die "oscap remediation failed (rc=$rc)"; }
  done
  "${REPO_ROOT}/scripts/supplemental.sh"
  state_set remediated
  reboot_or_exit "apply kernel args, audit immutability, and crypto policy"
fi

# --- Verify -----------------------------------------------------------------------
"${REPO_ROOT}/scripts/verify.sh"
state_set done
systemctl disable stig-firstboot.service >/dev/null 2>&1 || true
log "Done. Log in as '$ADMIN_USER' (root SSH is disabled) and review ${LOG_DIR}/report-*.html"
