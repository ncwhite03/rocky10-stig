#!/usr/bin/env bash
# Bake the kickstart and fips=1 into a Rocky installer ISO for upload to a vSphere datastore.
# Run on any Rocky/RHEL 9/10 box (needs: dnf install lorax).
#   usage: build-iso.sh Rocky-10.2-x86_64-dvd.iso out.iso
set -euo pipefail
in="${1:?input Rocky ISO}"; out="${2:?output ISO}"
ks="$(cd "$(dirname "$0")/.." && pwd)/kickstart/rocky10-stig.ks"
grep -q 'ADMIN_HASH' "$ks" && { echo "Edit ADMIN_HASH in $ks first (openssl passwd -6)." >&2; exit 1; }
command -v mkksiso >/dev/null || { echo "Install lorax: dnf install lorax" >&2; exit 1; }
mkksiso --ks "$ks" --cmdline "fips=1" "$in" "$out"
echo "Built $out -- upload to a vSphere datastore and attach to the VM's CD/DVD drive."
