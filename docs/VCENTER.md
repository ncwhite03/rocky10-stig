# Deploying on vCenter / vSphere

## VM spec
| Setting | Value |
|---|---|
| Guest OS | Linux > Red Hat Enterprise Linux 10 (or 9 if 10 isn't listed) |
| Firmware | **EFI** (the kickstart assumes UEFI). Secure Boot may stay on. |
| CPU / RAM | 2+ vCPU, 4+ GiB (OpenSCAP remediation is memory-hungry; 8 GiB is comfortable) |
| Disk | **One** disk, >= 60 GiB (80 recommended), thin is fine. The kickstart installs to the largest disk; add data disks *after* install. |
| Controller / NIC | Paravirtual SCSI or NVMe / VMXNET3 |
| CD/DVD | Datastore ISO from `scripts/build-iso.sh`, "Connect at power on" |
| Network | Must reach `dl.rockylinux.org` and `github.com` (or your internal mirrors, see below) |

## Steps
1. Prepare the kickstart: set `ADMIN_HASH` (`openssl passwd -6`) and your SSH key in `kickstart/rocky10-stig.ks`.
2. Build the ISO (on a Rocky box): `sudo dnf install -y lorax && ./scripts/build-iso.sh Rocky-10.2-x86_64-dvd.iso rocky10-stig.iso`
3. Upload `rocky10-stig.iso` to a datastore (vSphere Client > Storage > Files > Upload).
4. Create the VM per the table above and attach the ISO. Power on and **do nothing**: the installer boots with `fips=1` and the kickstart.
5. The VM reboots after install, then `stig-firstboot.service` hardens it, rebooting twice (FIPS, then remediation). Allow ~20-40 minutes.
6. Log in as `stigadmin` with your key (root SSH is disabled). Check `/var/log/rocky10-stig/harden.log` and `report-*.html`; the last line should say "Done".

Take a vSphere snapshot of the finished VM before putting it into service.

## Scripted with govc (optional)
```bash
export GOVC_URL=vcenter.example.com GOVC_USERNAME=... GOVC_PASSWORD=... GOVC_DATACENTER=DC1 GOVC_DATASTORE=ds1 GOVC_NETWORK="VM Network"
govc datastore.upload rocky10-stig.iso iso/rocky10-stig.iso
govc vm.create -g rhel9_64Guest -firmware efi -c 4 -m 8192 -disk 80GB -disk.controller pvscsi \
   -net.adapter vmxnet3 -iso iso/rocky10-stig.iso -on=false rocky10-stig
govc device.cdrom.insert -vm rocky10-stig iso/rocky10-stig.iso   # if not attached by -iso
govc vm.power -on rocky10-stig
```

## Template workflow
Hardening once and cloning is fine, but regenerate SSH host keys per clone and remember FIPS/audit state is per-VM:
run `harden.sh --scan-only` on each clone, and use `ansible/site.yml` for fleet-wide re-application.

## No internet from the VM network
- Point the `url`/`repo` lines in the kickstart at your internal Rocky mirror (Satellite/Pulp/Artifactory), or use `cdrom` with the full DVD ISO.
- Mirror this repo internally and change the `git clone` URL in the kickstart `%post`.
- `scap-security-guide` comes from the Rocky repos, so no other download is needed.

## Pin to 10.2
`pub/rocky/10/` always points at the latest 10.x. To stay on 10.2, use the vault path
(`https://dl.rockylinux.org/vault/rocky/10.2/BaseOS/x86_64/os/`) once 10.2 is superseded.

## Troubleshooting
- Installer drops to a prompt: `FATAL` from `%pre` (placeholder not replaced, disk < 60 GiB) -- see `Alt+F2` / `/tmp/pre-anaconda-logs`.
- FIPS stage loops: `harden.sh` aborts if `fips_enabled` is still 0 after its reboot; check `fips-mode-setup --check` and `dmesg | grep -i fips`.
- Locked out: use the vSphere web console as `stigadmin`; faillock clears with `faillock --user stigadmin --reset` (needs another admin or single-user boot).
