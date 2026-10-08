#!/usr/bin/env bash
# Changes the pinned SCAP content does not (yet) make, applied idempotently:
#   * RHEL 10 STIG V1R3 additions
#   * Rocky-specific replacements for Red Hat-only checks
#   * guard rails that keep a STIG'd system usable
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

# --- V1R3: RHEL-10-003030  audit successful/unsuccessful use of useradd ----------
# Same form the upstream audit_rules_privileged_commands/usergroup rules use.
# Written to its own file so audit_rules.d ordering/immutability from SSG stays intact.
rules=/etc/audit/rules.d/50-stig-v1r3-useradd.rules
cat > "$rules" <<'RULES'
-a always,exit -F path=/usr/sbin/useradd -F perm=x -F auid>=1000 -F auid!=unset -F key=useradd
RULES
chmod 0600 "$rules"
if auditctl -s 2>/dev/null | grep -q 'enabled 2'; then
  warn "Audit rules are immutable (-e 2); useradd rule loads at next reboot."
else
  augenrules --load >/dev/null 2>&1 || warn "augenrules --load failed; rule will load at next reboot."
fi

# --- V1R3: RHEL-10-001060  OpenSSL must use DoW-approved (FIPS) cryptography ------
# OpenSSL inherits its algorithm set from the system crypto policy; FIPS mode + FIPS policy.
if [[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" == 1 ]]; then
  [[ "$(update-crypto-policies --show)" == FIPS* ]] || update-crypto-policies --set FIPS >/dev/null
else
  warn "FIPS is not active yet; OpenSSL requirement (V1R3 RHEL-10-001060) not satisfied until after reboot."
fi

# --- Keep rpm/dnf working with noexec on /var/tmp and /tmp -----------------------------
# rpm runs package scriptlets from %_tmppath (/var/tmp by default). The STIG requires
# noexec there, which makes many scriptlets fail with "Permission denied".
install -d -m 0700 /var/lib/rpm-tmp
echo '%_tmppath /var/lib/rpm-tmp' > /etc/rpm/macros.rocky10-stig
chmod 0644 /etc/rpm/macros.rocky10-stig
restorecon -R /var/lib/rpm-tmp 2>/dev/null || true

# --- Rocky replacement for ensure_redhat_gpgkey_installed -----------------------------
if rpm -q gpg-pubkey --qf '%{SUMMARY}\n' 2>/dev/null | grep -qi rocky; then
  log "Rocky Linux release signing key is imported."
else
  warn "No Rocky signing key imported in rpm. Import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 and re-run."
fi
grep -Rhs '^gpgcheck' /etc/dnf/dnf.conf /etc/yum.repos.d/ | grep -qv '=1' \
  && warn "A repo or dnf.conf sets gpgcheck != 1 (STIG V1R3 changed the GPG checks)." || true

log "Supplemental changes applied."
