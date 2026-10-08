# Rocky Linux 10.2 -- STIG-ready kickstart
#
# What it does: STIG-compliant partitioning (LVM, separate /home /tmp /var /var/log
# /var/log/audit /var/tmp with nodev/nosuid/noexec), FIPS mode, SELinux enforcing,
# then clones this repo and runs the hardening automatically on first boot.
#
# BEFORE USE
#   1. Replace ADMIN_HASH below:   openssl passwd -6      (SHA-512 crypt)
#   2. Replace the sshkey line with your public key (or delete it).
#   3. Boot the installer with:    inst.ks=<url-of-this-file> fips=1
#      ("fips=1" on the installer command line is what makes the *installed*
#       system FIPS-capable from the first boot -- do not skip it.)
#   4. Needs a disk of at least ~60 GiB. UEFI firmware is assumed.

text
reboot
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --activate --hostname=rocky10-stig

# Pick a mirror/URL your environment can reach. With a full DVD ISO, replace with "cdrom".
url --url="https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/"
repo --name=AppStream --baseurl="https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/"

# Root is locked; all admin work goes through a wheel user (STIG disables root SSH).
rootpw --lock
user --name=stigadmin --groups=wheel --iscrypted --password=ADMIN_HASH
sshkey --username=stigadmin "ssh-ed25519 AAAA...REPLACE_ME"

selinux --enforcing
firewall --enabled --ssh
services --enabled=sshd,auditd,rsyslog,chronyd,firewalld
bootloader --location=mbr --append="fips=1 audit=1 audit_backlog_limit=8192"

# Partitioning is generated in %pre so it can pick the right disk and sizes.
%include /tmp/part.ks

%packages
@^minimal-environment
openscap-scanner
scap-security-guide
aide
audit
rsyslog
fapolicyd
firewalld
chrony
sudo
openssh-server
crypto-policies-scripts
policycoreutils-python-utils
git
-telnet-server
-tftp-server
-vsftpd
%end

%pre --erroronfail
#!/bin/bash
# --- tunables -------------------------------------------------------------
ENCRYPT=0                    # 1 = LUKS-encrypt the PV (STIG encrypt_partitions). Needs the
LUKS_PASSPHRASE=""           #     passphrase typed at every boot unless you add TPM2/Clevis later.
# ---------------------------------------------------------------------------

# Refuse to install with the placeholder credentials still in place.
if grep -q 'ADMIN_HASH' /run/install/ks.cfg 2>/dev/null; then
  echo "FATAL: edit ADMIN_HASH in the kickstart first." >&2; exit 1
fi

# Largest non-removable disk.
DISK=$(lsblk -dnb -o NAME,SIZE,TYPE,RM | awk '$3=="disk" && $4==0 {print $2, $1}' | sort -rn | head -1 | awk '{print $2}')
SIZE_GB=$(( $(lsblk -dnb -o SIZE /dev/$DISK) / 1024 / 1024 / 1024 ))
[ "$SIZE_GB" -ge 60 ] || { echo "FATAL: /dev/$DISK is ${SIZE_GB}GiB; need >= 60GiB." >&2; exit 1; }

ENC=""
if [ "$ENCRYPT" = 1 ]; then
  [ -n "$LUKS_PASSPHRASE" ] || { echo "FATAL: ENCRYPT=1 needs LUKS_PASSPHRASE" >&2; exit 1; }
  ENC="--encrypted --passphrase=$LUKS_PASSPHRASE"
fi

NOEXEC="nodev,nosuid,noexec"
cat > /tmp/part.ks <<EOT
ignoredisk --only-use=$DISK
zerombr
clearpart --all --initlabel --drives=$DISK
part /boot/efi --fstype=efi --size=600  --fsoptions="umask=0077,shortname=winnt,nodev,nosuid"
part /boot     --fstype=xfs --size=1024 --fsoptions="nodev,nosuid"
part pv.01     --size=1 --grow $ENC
volgroup rl pv.01
logvol /              --vgname=rl --name=root    --fstype=xfs --size=15360
logvol swap           --vgname=rl --name=swap    --fstype=swap --size=4096
logvol /home          --vgname=rl --name=home    --fstype=xfs --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol /tmp           --vgname=rl --name=tmp     --fstype=xfs --size=5120  --fsoptions="$NOEXEC"
logvol /var/tmp       --vgname=rl --name=var_tmp --fstype=xfs --size=5120  --fsoptions="$NOEXEC"
logvol /var           --vgname=rl --name=var     --fstype=xfs --size=15360 --grow --fsoptions="nodev"
logvol /var/log       --vgname=rl --name=var_log --fstype=xfs --size=8192  --fsoptions="$NOEXEC"
logvol /var/log/audit --vgname=rl --name=audit   --fstype=xfs --size=4096  --fsoptions="$NOEXEC"
EOT
%end

%post --log=/root/ks-post.log
set -x
# Fallback in case fips=1 on the installer cmdline was forgotten.
[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ] || fips-mode-setup --enable || true

# Fetch the automation while the installer has network.
git clone --depth 1 https://github.com/ncwhite03/rocky10-stig.git /opt/rocky10-stig

echo 'ADMIN_USER=stigadmin' > /etc/rocky10-stig.conf
chmod 0600 /etc/rocky10-stig.conf
install -m 0644 /opt/rocky10-stig/scripts/stig-firstboot.service /etc/systemd/system/stig-firstboot.service
systemctl enable stig-firstboot.service
%end
