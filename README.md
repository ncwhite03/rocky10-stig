# rocky10-stig

Automated DISA STIG hardening for **Rocky Linux 10.2**, built against the **DISA RHEL 10 STIG**
(V1R3, published 2026-09-30), with FIPS 140 mode enabled and a STIG-compliant disk layout.

## Read this first: what is and isn't verified

| | Status |
|---|---|
| Rocky 10.2 + Rocky's `ssg-rl10-ds.xml` STIG profile loads, tailors, scans, and remediates | Tested in a `rockylinux/rockylinux:10` container |
| Kickstart, FIPS reboot flow, first-boot service, Ansible reboots | **Not yet run on a VM/bare metal.** Test on a throwaway VM first. |
| STIG V1R3 coverage | **Partial.** Rocky's package (SSG 0.1.82) targets **V1R2**. `scripts/supplemental.sh` adds the two V1R3 new rules (useradd auditing, OpenSSL/FIPS crypto). The 51 V1R3 check/fix wording changes (GPG checks, FTP, rsyslog, cron logging, SSH cipher/MAC text) are not independently implemented; re-scan with the official V1R3 benchmark in DISA STIG Viewer to confirm. |
| "Fully STIG" | Not achievable by automation alone. Some findings are site-specific or manual (GRUB password, disk encryption, DoD CA certs, SSP-dependent items). See *Known gaps*. |

> **Do not use the upstream `ssg-rhel10-ds.xml` on Rocky.** Tested: all 473 rules evaluate `notapplicable`
> because the content is gated on RHEL's CPE. Rocky's package ships `ssg-rl10-ds.xml` which works.

## Quick start

### A) Fresh install (recommended: gives you the partitioning)
1. Edit `kickstart/rocky10-stig.ks`: set `ADMIN_HASH` (`openssl passwd -6`) and your SSH key. The install aborts if the placeholder remains.
2. Boot the Rocky 10.2 installer with `inst.ks=<url> fips=1`. (`fips=1` on the installer line is what makes the installed system FIPS-capable.)
3. First boot: `stig-firstboot.service` runs `harden.sh`, reboots as needed, and finishes with a scan.
   Reports: `/var/log/rocky10-stig/`.

Layout (LVM, XFS, UEFI, >= 60 GiB disk): `/boot/efi`, `/boot`, `/`, swap, `/home`, `/tmp`, `/var/tmp`, `/var`,
`/var/log`, `/var/log/audit`, with `nodev,nosuid,noexec` where the STIG requires it.

### B) Existing host
```bash
sudo ./scripts/harden.sh --admin-user youradmin --reboot
```
Re-runnable; resumes after each reboot (FIPS -> remediation -> verification). Use `--scan-only` to audit without changing anything.
Existing hosts that lack the separate mount points keep `partition_for_*` findings; repartitioning a live system is intentionally not automated.

### C) Ansible (fleet)
```bash
ansible-playbook -i ansible/inventory.example.ini ansible/site.yml -e admin_user=stigadmin
```

## Not-breaking-the-OS guard rails
- **Preflight** refuses to run unless a non-root `wheel` user with a real password exists (STIG removes root SSH login and passwordless sudo, and locks accounts after 3 failed logins).
- Backup tarball of `/etc` and boot config in `/var/backups/rocky10-stig/` before changes (take a VM snapshot too).
- rpm scriptlet temp dir moved to `/var/lib/rpm-tmp`, because the STIG's `noexec` on `/var/tmp` otherwise breaks `dnf` installs.
- Red Hat-only checks (`installed_OS_is_vendor_supported`, `ensure_redhat_gpgkey_installed`) are excluded; the Rocky key is checked instead.
- Remediation runs twice (dependent rules), and everything is idempotent.

## Known gaps / decisions for you
- **Disk encryption** (`encrypt_partitions`): off by default because LUKS needs a passphrase at each boot. Set `ENCRYPT=1` + passphrase in the kickstart `%pre`, or accept the risk per your SSP.
- **GRUB password** (`grub2_password`): only enforced if you pass `--grub-password-file`.
- **usbguard / usb-storage disabled**: the STIG blocks USB storage; on physical hosts the usbguard policy is generated from devices attached at hardening time.
- **Vendor FIPS validation**: Rocky's crypto modules are not (yet) CMVP-validated; FIPS *mode* is on, but you will need your AO to accept that.
- Everything excluded is listed in `config/excluded_rules.txt` with the reason.

## Layout
```
config/stig.conf            paths, profile (stig | stig_gui)
config/excluded_rules.txt   rules removed from the profile, with reasons
scripts/harden.sh           orchestrator (preflight, backup, FIPS, remediate, verify)
scripts/supplemental.sh     V1R3 delta + Rocky-specific fixes
scripts/verify.sh           scan + HTML report + failing-rule list
kickstart/rocky10-stig.ks   partitioning + FIPS + first-boot hardening
ansible/                    fleet wrapper that handles reboots
```
