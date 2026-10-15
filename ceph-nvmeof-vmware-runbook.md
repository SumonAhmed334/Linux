# Ceph NVMe-oF Gateway + VMware Integration Runbook

Nested vSphere + Ceph NVMe-oF lab: ceph01–03 (cephadm, podman), stor-gw01 (NTP), lab-esxi01–04.

---

## PART 1 — Node preparation (ceph01, ceph02, ceph03)

The same block is run on each node; only the hostname and IP values change.

### ceph01 (100.66.69.220)

```bash
# ===== RUN ON: ceph01 (100.66.69.220) =====
# ---------- ceph01 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph01
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph01 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph01 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.201 and 100.66.66.201
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph01 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost

100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.161  lab-esxi04.vsphere.local lab-esxi04

100.66.69.220  ceph01.vsphere.local ceph01
100.66.69.221  ceph02.vsphere.local ceph02
100.66.69.222  ceph03.vsphere.local ceph03
EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.220

# ---------- ceph01 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph01 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph01 : verify ----------
lsblk
for ip in 100.66.69.220 100.66.69.221 100.66.69.105; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

### ceph02 (100.66.69.202)

```bash
# ===== RUN ON: ceph02 (100.66.69.202) =====
# ---------- ceph02 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph02
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph02 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph02 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.202 and 100.66.66.202
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph02 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost

100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.161  lab-esxi04.vsphere.local lab-esxi04

100.66.69.220  ceph01.vsphere.local ceph01
100.66.69.221  ceph02.vsphere.local ceph02
100.66.69.222  ceph03.vsphere.local ceph03
EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.221

# ---------- ceph02 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph02 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph02 : verify ----------
lsblk
for ip in 100.66.69.220 100.66.69.222 100.66.69.105; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

### ceph03 (100.66.69.203)

```bash
# ===== RUN ON: ceph03 (100.66.69.203) =====
# ---------- ceph03 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph03
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph03 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph03 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.203 and 100.66.66.203
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph03 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost

100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.161  lab-esxi04.vsphere.local lab-esxi04

100.66.69.220  ceph01.vsphere.local ceph01
100.66.69.221  ceph02.vsphere.local ceph02
100.66.69.222  ceph03.vsphere.local ceph03

EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.203

# ---------- ceph03 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph03 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph03 : verify ----------
lsblk
for ip in 100.66.69.220 100.66.69.221 100.66.69.105; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

---

## PART 2 — Bootstrap the cluster

### Install cephadm and bootstrap (ceph01)

```bash
# ===== RUN ON: ceph01 (100.66.69.220) =====
curl -sLo /usr/local/sbin/cephadm https://download.ceph.com/rpm-tentacle/el9/noarch/cephadm
chmod 755 /usr/local/sbin/cephadm

cat > /root/cephadm-ssh-config <<'EOF'
Host *
  User root
  Port 8022
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ConnectTimeout 30
EOF

cephadm bootstrap \
  --mon-ip 100.66.69.220 \
  --ssh-config /root/cephadm-ssh-config \
  --skip-monitoring-stack
```

### Show the cluster public key (ceph01)

```bash
# ===== RUN ON: ceph01 (100.66.69.220) =====
cat /etc/ceph/ceph.pub
```

### Authorize the key on ceph02

```bash
# ===== RUN ON: ceph02 (100.66.69.221) =====
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'PASTE_CEPH_PUB_KEY_HERE' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

### Authorize the key on ceph03

```bash
# ===== RUN ON: ceph03 (100.66.69.222) =====
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'PASTE_CEPH_PUB_KEY_HERE' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

---

## PART 3 — Add hosts and place daemons

```bash
# ===== RUN ON: ceph01 =====
cephadm shell
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph cephadm check-host ceph02 100.66.69.202
ceph cephadm check-host ceph03 100.66.69.203

ceph orch host add ceph02 100.66.69.202
ceph orch host add ceph03 100.66.69.203
ceph orch host ls

ceph orch apply mon --placement="ceph01,ceph02,ceph03"
ceph orch apply mgr --placement="ceph01,ceph02"
ceph -s
```

---

## 5.6 Create the OSDs

Still inside `cephadm shell` on ceph01. Confirm the orchestrator sees exactly the six disks you expect, and nothing else:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch device ls
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch daemon add osd ceph01:/dev/sdb
ceph orch daemon add osd ceph01:/dev/sdc
ceph orch daemon add osd ceph02:/dev/sdb
ceph orch daemon add osd ceph02:/dev/sdc
ceph orch daemon add osd ceph03:/dev/sdb
ceph orch daemon add osd ceph03:/dev/sdc

ceph orch ps --daemon-type osd
ceph osd tree
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph osd tree
```

### Tuning, CRUSH rule and pools

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph config set osd osd_memory_target 1073741824     # 1 GiB per OSD at 16 GB RAM per node
ceph config set osd osd_mclock_profile high_client_ops

ceph osd crush rule create-replicated hdd-rule default host hdd

ceph osd pool create nvmeof-cfg 32 32 replicated hdd-rule
rbd pool init nvmeof-cfg

ceph osd pool create vmfs-flash 64 64 replicated hdd-rule
ceph osd pool set vmfs-flash size 3
ceph osd pool set vmfs-flash min_size 2
rbd pool init vmfs-flash

ceph time-sync-status
ceph df
ceph -s
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph osd crush rule rename flash-rule hdd-rule
ceph osd crush rule ls
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph config show osd.0 | grep mclock
ceph config help osd_mclock_max_capacity_iops_hdd
```

---

## PART 6 — NVMe-oF Gateway Configuration

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph mgr module ls | grep -i nvmeof
ceph mgr module enable nvmeof              # if the line above showed it disabled

ceph orch apply nvmeof --pool nvmeof-cfg --group gw-lab --placement="ceph01,ceph02,ceph03"
ceph orch ps --daemon-type nvmeof
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch ls --service-type nvmeof --export
```

```bash
# ===== RUN ON: each Ceph node =====
grep -i huge /proc/meminfo
free -h
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof subsystem add --help
ceph nvmeof listener add --help
ceph nvmeof namespace add --help
```

### 6.2 Create the subsystem — and read the NQN back

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof subsystem add --nqn nqn.2016-06.io.spdk:lab01
ceph nvmeof subsystem list
```

The gateway appends the gateway-group name to the NQN you asked for. What you created as `nqn.2016-06.io.spdk:lab01` is listed as:

```
nqn.2016-06.io.spdk:lab01.gw-lab
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
NQN=nqn.2016-06.io.spdk:lab01.gw-lab       # paste exactly what subsystem list showed
echo $NQN
```

### 6.3 Listeners — one per gateway

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof listener add --nqn $NQN --host_name ceph01 --traddr 100.66.69.201 --trsvcid 4420
ceph nvmeof listener add --nqn $NQN --host_name ceph02 --traddr 100.66.69.202 --trsvcid 4420
ceph nvmeof listener add --nqn $NQN --host_name ceph03 --traddr 100.66.69.203 --trsvcid 4420

ceph nvmeof listener list --nqn $NQN
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.201 100.66.69.202 100.66.69.203; do
  nc -z -w2 $ip 4420 && echo "$ip:4420 open" || echo "$ip:4420 CLOSED"
done
```

### 6.4 RBD images and namespaces

Six images at 40 GiB — the arithmetic and the MAX AVAIL ceiling are in 5.1:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
rbd create vmfs-flash/ds01 --size 40G
rbd create vmfs-flash/ds02 --size 40G
rbd create vmfs-flash/ds03 --size 40G
rbd create vmfs-flash/ds04 --size 40G
rbd create vmfs-flash/ds05 --size 40G
rbd create vmfs-flash/ds06 --size 40G

rbd ls -l vmfs-flash
```

#### Namespaces — block size is not optional

ESXi requires 512-byte namespaces. A 4 K namespace connects cleanly and then presents no usable device, which across every storage vendor is the most common cause of "ESXi can't see my storage". ceph-nvmeof defaults to 512, but this build sets it explicitly so the intent is in the command rather than in a default that could change:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds01 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds02 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds03 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds04 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds05 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds06 --block_size 512

ceph nvmeof namespace list --nqn $NQN
```

#### Load-balancing groups — measured, not assumed

This build auto-balances. With `--load_balancing_group` omitted, 1.7.23 assigns groups round-robin, so six namespaces land two per group with no intervention. The namespace list above should show groups 1,2,3,1,2,3.

That was tested deliberately: the first three were added without the flag and landed in groups 1, 2 and 3 respectively. Confirm it on your own build before relying on it. If all three land in group 1, your build does not auto-balance, and every namespace must then carry the flag explicitly or the whole cluster's client traffic ends up on one gateway while the other two idle:

```bash
# ===== RUN ON: ceph01, inside cephadm shell — ONLY if your build did not auto-balance =====
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds04 --block_size 512 --load_balancing_group 1
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds05 --block_size 512 --load_balancing_group 2
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds06 --block_size 512 --load_balancing_group 3
```

---

## PART 7 — VMware Integration

### 7.1 Register ESXi host NQNs

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi01'
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi02'
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi03'

ceph nvmeof host list --nqn $NQN
```

### 7.2 Connect lab-esxi04

Step 1 — check the NVMe port groups and vmk tags:

```bash
# ===== RUN ON: lab-esxi01 (100.66.69.161) =====
esxcli network vswitch standard portgroup policy failover get -p NVME-A
esxcli network vswitch standard portgroup policy failover get -p NVME-B
esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
```

Step 2 — prove the storage path, now against the addresses NVMe/TCP will actually use:

```bash
# ===== RUN ON: lab-esxi04 (100.66.69.161) =====
vmkping -I vmk2 -d -s 1472 100.66.69.220
vmkping -I vmk2 -d -s 1472 100.66.69.221
vmkping -I vmk2 -d -s 1472 100.66.69.222
vmkping -I vmk3 -d -s 1472 100.66.69.220
vmkping -I vmk3 -d -s 1472 100.66.69.221
vmkping -I vmk3 -d -s 1472 100.66.69.222
```

Step 3 — list the NVMe adapters:

```bash
# ===== RUN ON: lab-esxi01 (100.66.69.161) =====
esxcli nvme adapter list
```

Step 4 — connect both adapters to all three gateways. Six controllers is the target: two fabrics × three gateways.

```bash
# ===== RUN ON: lab-esxi01 (100.66.69.161) =====
esxcli nvme fabrics discover -a vmhba65 -i 100.66.69.220 -p 8009

esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.220 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.221 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.222 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.220 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.221 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.222 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab

esxcli nvme controller list
esxcli nvme namespace list
esxcli storage core device list | grep -iE "Display Name|Block Size"
```

Step 5 — verify ANA distribution. This is what proves the three gateways are actually sharing the load:

```bash
# ===== RUN ON: lab-esxi01 (100.66.69.161) =====
for d in $(esxcli storage core device list | grep '^eui\.'); do
  echo "== $d"
  esxcli storage core path list -d $d | grep -E 'Runtime Name:|State:'
done

esxcli storage hpp device list | grep -E '^eui|Path Selection Scheme|Working Path'
```

---

## 7.5 Create the datastores and move the lab onto Ceph

Create the VMFS once, from any one host. The others pick it up on rescan.

The vCenter → New Datastore wizard does this with no arithmetic and is the easier route. The CLI version is below because it is exact, scriptable and leaves a record of what was done.

Every namespace is 40960 MB, which is 83,886,080 sectors of 512 bytes. GPT reserves the last 34 for the secondary header, so the usable end is 83,886,046 on all six — the same number every time.

If you ever change the namespace size, the formula and a lookup table for the common sizes are in 10.5:

```
sectors      = size_in_MB × 2048
last usable  = sectors − 34
```

```bash
# ===== RUN ON: lab-esxi04 (100.66.69.161) =====
esxcli storage core device list | grep '^eui\.'
```

Take the six `eui.*` names from that output. For the first one:

```bash
# ===== RUN ON: lab-esxi04 (100.66.69.161) =====
partedUtil mklabel /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7 gpt
partedUtil getUsableSectors /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7
```

Confirm that prints `34 83886046`, then:

```bash
# ===== RUN ON: lab-esxi04 (100.66.69.161) =====
partedUtil setptbl /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7 gpt \
  "1 2048 83886046 AA31E02A400F11DB9590000C2911D1B8 0"

vmkfstools -C vmfs6 -S lab-nvme-ds01 /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7:1
```

`AA31E02A400F11DB9590000C2911D1B8` is the VMFS partition type GUID. It is the same on every device.

The remaining five in one pass — substitute your own `eui.*` names, keeping each paired with the datastore name that matches its NSID (the mapping is in the table in 7.2):

```bash
# ===== RUN ON: lab-esxi04 (100.66.69.161) =====
for pair in \
  "eui.9162389c18e04af6982a389f0b07a768 lab-nvme-ds02" \
  "eui.552097d44ab54b0baad9101784e07eac lab-nvme-ds03" \
  "eui.fdb17d20f8d34576ae73df1e2ead0a76 lab-nvme-ds04" \
  "eui.c07b900445294fffa07d7618acc94f02 lab-nvme-ds05" \
  "eui.9c15af2f14234f1294f92e18ca6a4faa lab-nvme-ds06" ; do
  set -- $pair
  partedUtil mklabel /vmfs/devices/disks/$1 gpt
  partedUtil setptbl /vmfs/devices/disks/$1 gpt "1 2048 83886046 AA31E02A400F11DB9590000C2911D1B8 0"
  vmkfstools -C vmfs6 -S $2 /vmfs/devices/disks/$1:1
done

esxcli storage filesystem list | grep lab-nvme
```

Six VMFS-6 volumes, each about 39.75 GB — VMFS-6 takes roughly 1.2 GB of a 40 GiB device for metadata, so that figure is correct, not a shortfall. Then on the other two hosts:

```bash
# ===== RUN ON: lab-esxi02 and lab-esxi03 =====
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

### Prove I/O actually crosses both fabrics

```bash
# ===== RUN ON: lab-esxi01 (100.66.69.161) =====
time dd if=/dev/zero of=/vmfs/volumes/lab-nvme-ds01/iotest.bin bs=1M count=4096

esxcli storage core path stats get -p vmhba65:C0:T0:L0 | grep -E 'Successful|Blocks Written'
esxcli storage core path stats get -p vmhba66:C0:T0:L0 | grep -E 'Successful|Blocks Written'

rm -f /vmfs/volumes/lab-nvme-ds01/iotest.bin
```

Blocks Written should be within a few percent across the two paths. On the live build it was 4,328,116 against 4,313,203 — 0.3% apart.

The throughput figure is not a result. 4 GiB took 98 seconds, about 42 MB/s. That is six 10k SAS spindles absorbing size=3 replication with no separate WAL/DB device — roughly 125 MB/s of raw spindle work, which is about right. It says the path works. It says nothing about production on NVMe OSDs. Record it in 8.4 as a lab artefact.

### Move the test VMs

- Place or Storage vMotion `lab-vm01`–`03` across `lab-nvme-ds02` … `lab-nvme-ds06`, at least one VM per load-balancing group — use the table in 7.2 to pick datastores owned by different gateways.
- Watch `stall-watch` inside each guest during the migration. This is the first real write load the NVMe/TCP path carries, and a migration that finishes with no stall lines is a meaningful result — record it.
- Confirm the heartbeat datastores are `lab-nvme-ds01` and `lab-nvme-ds02`, set in 4.8 — two datastores owned by different gateways.
