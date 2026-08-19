# Ubuntu 24.04 Server — Install & Prepare Guide

> Install Ubuntu Server **Minimized/Minimal**, without LVM, with SSH server only.
> Version: v1.02 — Jul 2025

---

## 1. Base System Update & Packages

```bash
apt update
apt full-upgrade -y

apt install qemu-guest-agent locales locales-all openssh-server vim htop net-tools ifupdown tmux wireguard mtr wget curl traceroute frr -y
apt install --install-recommends linux-generic-hwe-24.04 -y
```

---

## 2. GRUB Configuration

```bash
vim /etc/default/grub
```

Set the following:

```ini
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=
GRUB_TIMEOUT=20
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="netcfg/do_not_use_netplan=true"
```

Apply changes:

```bash
update-grub
```

---

## 3. Legacy Network Configuration (`/etc/network/interfaces`)

```bash
vim /etc/network/interfaces
```

```ini
########### Legacy Network Configuration
auto lo
iface lo inet loopback

auto ens18
iface ens18 inet static
    address 172.16.198.175/24
    gateway 172.16.198.1
```

Save & exit, then remove netplan:

```bash
apt autoremove -y --purge netplan.io resolvconf
rm -fr /etc/netplan
```

---

## 4. DNS Configuration

Disable `systemd-resolved` and set static resolvers:

```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved.service
rm -fr /etc/resolv.conf
touch /etc/resolv.conf

echo "nameserver 9.9.9.9" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 1.0.0.3" >> /etc/resolv.conf
```

---

## 5. System Limits (`/etc/security/limits.conf`)

```bash
vim /etc/security/limits.conf
```

Add:

```ini
root soft     nproc          1024000
root hard     nproc          1024000
root soft     nofile         1024000
root hard     nofile         1024000
# End of file
```

---

## 6. Kernel / Network Tuning (`/etc/sysctl.conf`)

```bash
vim /etc/sysctl.conf
```

Add:

```ini
net.ipv4.ip_forward=1
fs.file-max = 2097152
net.ipv4.tcp_max_orphans = 60000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_syn_backlog = 100000
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_synack_retries = 2
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 100000
net.core.netdev_max_backlog = 100000
net.core.optmem_max = 25165824
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.core.rmem_default = 25165824
net.core.rmem_max = 25165824
net.ipv4.tcp_rmem = 20480 12582912 25165824
net.ipv4.udp_rmem_min = 16384
net.core.wmem_default = 25165824
net.core.wmem_max = 25165824
net.ipv4.tcp_wmem = 20480 12582912 25165824
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 50

### Optional: disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
# End of file
```

---

## 7. Swap Setup

```bash
sudo swapoff /swap.img
sudo fallocate -l 8G /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img

sudo swapoff /swapfile
sudo fallocate -l 8G /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Reload font cache after installing new fonts:

```bash
fc-cache -fv
```

---

## 8. Locale Configuration

```bash
apt -y install locales locales-all

localectl set-locale LANG=en_US.UTF-8 LANGUAGE="en_US:en"
export LANG=en_US.UTF-8

cd /root/
echo "LANG=en_US.UTF-8" >> .profile
echo "LANG=en_US.UTF-8" >> .bashrc
source .profile
source .bashrc
```

---

## 9. SSH Server Configuration

```bash
vim /etc/ssh/sshd_config
```

Set:

```ini
Port 8022
PermitRootLogin yes
UseDNS no
```

Save & exit.

**For a VM:**

```bash
systemctl enable ssh
systemctl restart ssh
systemctl status ssh
```

**For an LXC container:**

```bash
systemctl disable ssh.socket
systemctl enable ssh
systemctl restart ssh
```

Verify listening ports and add SSH keys:

```bash
netstat -tulpn

vim .ssh/authorized_keys
rm -fr /etc/update-motd.d/*
```

---

## 10. Disable systemd-networkd

```bash
systemctl disable systemd-networkd
systemctl stop systemd-networkd
systemctl status systemd-networkd
```

---

## 11. Timezone & Reboot

```bash
dpkg-reconfigure tzdata   # Set Time Zone to Asia/Dhaka

reboot
```

---

## 12. Install FileBrowser

```bash
wget https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/addon/filebrowser-quantum.sh
bash filebrowser-quantum.sh
cat /usr/local/community-scripts/fq-config.yaml
```

---

## 13. Remaining / TODO Items

- Install SNMP client
- Install NTP client
- Configure WireGuard client
- Configure remote rsyslog

---

## 14. Fix APT Sources

```bash
cat /etc/apt/sources.list.d/ubuntu.sources
```

```ini
Types: deb
URIs: https://mirrors.cloud.tencent.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
```

**Alternative mirrors:**

```ini
# deb https://mirrors.cicku.me/linuxmint/packages wilma main upstream import backport
deb https://repo.extreme-ix.org/ubuntu noble main restricted universe multiverse
deb https://repo.extreme-ix.org/ubuntu noble-updates main restricted universe multiverse
deb https://repo.extreme-ix.org/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
```

---

## 15. Option 2 — Classic `/etc/network/interfaces` Setup

```bash
sudo apt install ifupdown
sudo apt purge netplan.io
sudo ln -sf /dev/null /etc/systemd/system-generators/netplan

sudo vim /etc/network/interfaces
```

```ini
# loopback
auto lo
iface lo inet loopback

# ethernet -- modify as per your interface name
auto ens18
iface ens18 inet static
  address 192.168.1.100
  netmask 255.255.255.0
  gateway 192.168.1.1
  dns-nameservers 8.8.8.8 8.8.4.4
```

```bash
sudo systemctl restart networking
sudo /etc/init.d/networking restart

sudo rm -rf /usr/share/netplan /etc/netplan
```

---

## 16. Passwordless Sudo

```bash
sudo visudo
```

Add at the end of the file:

```ini
username ALL=(ALL) NOPASSWD:ALL
```

**OR** create a dedicated sudoers drop-in file:

```bash
sudo nano /etc/sudoers.d/nopasswd_reza
```

```ini
reza ALL=(ALL) NOPASSWD:ALL
```

---

## 17. Install Docker

```bash
apt install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y
apt remove docker docker-engine docker.io containerd runc
apt update
apt install ca-certificates curl gnupg lsb-release

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
```

---

## 18. SSH Key Agent Setup

```bash
chmod 700 .ssh/
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa
```

---

## 19. Proxmox Cluster Notes

`/etc/pve/datacenter.cfg`:

```ini
keyboard: en-us
migration: type=insecure, network=192.168.155.0/24
```

```bash
pvecm expected 1
systemctl stop pve-cluster
pmxcfs -l
```

---

## 20. ZFS L2ARC & ARC Tuning

**L2ARC write max (64 MiB example):**

```bash
echo "options zfs l2arc_write_max=67108864" >> /etc/modprobe.d/zfs.conf
update-initramfs -u -k all
reboot
```

Runtime tuning (256 MB write max):

```bash
echo 268435456 > /sys/module/zfs/parameters/l2arc_write_max
echo 0 > /sys/module/zfs/parameters/l2arc_noprefetch
echo 1 > /sys/module/zfs/parameters/l2arc_rebuild_enabled
```

**Set ARC max size to 32 GiB (34359738368 bytes):**

```bash
echo 34359738368 > /sys/module/zfs/parameters/zfs_arc_max
echo 3 > /proc/sys/vm/drop_caches
```

Persist via `/etc/modprobe.d/zfs.conf`:

```bash
nano /etc/modprobe.d/zfs.conf
```

```ini
options zfs zfs_arc_max=34359738368
options zfs l2arc_write_max=268435456
```

```bash
update-initramfs -u -k all
reboot
```

---

## 21. Proxmox Host Network Example (Public + Private Bridge)

```ini
auto lo
iface lo inet loopback

auto eno1
# real IP address
iface eno1 inet static
        address  198.51.100.5/24
        gateway  198.51.100.1

auto vmbr0
# private sub network
iface vmbr0 inet static
        address  10.10.10.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0

        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o eno1 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '10.10.10.0/24' -o eno1 -j MASQUERADE
```

---

## 22. ZFS Pool Creation

### 22.1 Install ZFS Utilities

```bash
sudo add-apt-repository ppa:jonathonf/zfs
sudo apt update
sudo apt install zfsutils-linux gdisk
```

### 22.2 Identify Available Disks

```bash
sudo fdisk -l | grep sd* | grep GiB   # list available disks
```

Example output:

```
Disk /dev/sda: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdc: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdf: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdb: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdd: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sde: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdg: 279.37 GiB, 299966445568 bytes, 585871964 sectors
Disk /dev/sdh: 232.87 GiB, 250023444480 bytes, 488327040 sectors
```

Identify the OS disk (here `sda`):

```bash
sudo fdisk -l | more
```

```
Device     Boot   Start       End   Sectors   Size Id Type
/dev/sda1  *       2048   1050623   1048576   512M  b W95 FAT32
/dev/sda2       1052670 585871359 584818690 278.9G  5 Extended
/dev/sda5       1052672 585871359 584818688 278.9G 83 Linux
```

- `sdh` → SSD used as ZFS read cache (L2ARC)
- Data disks → `sdb, sdc, sdd, sde, sdf, sdg`

### 22.3 Find Disk IDs

```bash
ls -la /dev/disk/by-id/
```

Example (truncated):

```
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_01000000 -> ../../sdb
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_02000000 -> ../../sdc
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_03000000 -> ../../sdd
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_04000000 -> ../../sde
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_05000000 -> ../../sdf
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_06000000 -> ../../sdg
lrwxrwxrwx 1 root root   9 Jun 29 09:43 scsi-0HP_LOGICAL_VOLUME_07000000 -> ../../sdh

lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c3ec64937950785d1504e -> ../../sdh
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c7a52ca05eec4e0afb73d -> ../../sdd
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c7d1b4b8d5a871e56535c -> ../../sde
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c840d4ccf29d8bbfb351f -> ../../sdg
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c84793a4ef7c5740c9b1c -> ../../sdb
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001c8c1e2292e6dd06954823 -> ../../sdf
lrwxrwxrwx 1 root root   9 Jun 29 09:43 wwn-0x600508b1001cda713c46c79584b9ca22 -> ../../sdc
```

> Use the `wwn-*` disk IDs for pool creation — they are stable across reboots.

### 22.4 Wipe Disks

```bash
sgdisk --zap-all /dev/sdb
sgdisk --zap-all /dev/sdc
sgdisk --zap-all /dev/sdd
sgdisk --zap-all /dev/sde
sgdisk --zap-all /dev/sdf
sgdisk --zap-all /dev/sdg
sgdisk --zap-all /dev/sdh
```

### 22.5 Create Pools

**Mirror pool example:**

```bash
sudo zpool create -o ashift=12 -f vol1 mirror \
  wwn-0x5000c5003c300e57 \
  wwn-0x5000c5004320e41f
```

**Single-partition pool:**

```bash
sudo zpool create -o ashift=12 -f n2vol1 wwn-0x600605b007f6c16027d30b892e8240fe-part4
```

**RAIDZ2 pool (6 disks):**

```bash
sudo zpool create -o ashift=12 -f vmx4vol1 raidz2 \
  wwn-0x600508b1001c84793a4ef7c5740c9b1c \
  wwn-0x600508b1001cda713c46c79584b9ca22 \
  wwn-0x600508b1001c7a52ca05eec4e0afb73d \
  wwn-0x600508b1001c7d1b4b8d5a871e56535c \
  wwn-0x600508b1001c8c1e2292e6dd06954823 \
  wwn-0x600508b1001c840d4ccf29d8bbfb351f
```

**Add SSD read cache (`/dev/sdh`):**

```bash
sudo zpool add -f vmx4vol1 cache wwn-0x600508b1001c3ec64937950785d1504e

sudo zpool status
```

### 22.6 Tune Pool Properties

```bash
sudo zfs set sync=disabled vmx4vol1
sudo zfs set compress=lz4 vmx4vol1
sudo zfs set atime=off vmx4vol1
sudo zfs set xattr=sa vmx4vol1
sudo zfs set relatime=off vmx4vol1
sudo zfs set acltype=posixacl vmx4vol1

sudo zfs set sync=disabled ctvol1
sudo zfs set compress=lz4 ctvol1
sudo zfs set atime=off ctvol1
sudo zfs set xattr=sa ctvol1
sudo zfs set relatime=off ctvol1
sudo zfs set acltype=posixacl ctvol1
```

### 22.7 Create Datasets

```bash
sudo zfs create vmx4vol1/iso
sudo zfs create vmx4vol1/lxc
sudo zfs create vmx4vol1/kvm
```
