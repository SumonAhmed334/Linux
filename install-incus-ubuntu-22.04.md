# Installing Incus on Ubuntu 22.04 LTS (Jammy)

Incus is not in Ubuntu 22.04's default repositories (native `apt install incus` only works on 24.04+), so we'll use the official **Zabbly** repository, maintained by the Incus project lead. This gives you fully supported, up-to-date packages.

All commands below are run as **root** (matches your `node1` prompt). If you're using a regular user with sudo, prefix commands with `sudo`.

---

## 1. Update the system

```bash
apt update && apt upgrade -y
```

## 2. Install prerequisites

```bash
apt install -y curl gnupg apt-transport-https ca-certificates
```

## 3. Create the keyrings directory and import the Zabbly GPG key

```bash
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
```

(Optional) Verify the key fingerprint matches `4EFC 5906 96CB 15B8 7C73 A3AD 82CC 8797 C838 DCFD`:

```bash
gpg --show-keys --fingerprint /etc/apt/keyrings/zabbly.asc
```

## 4. Add the Zabbly repository

Zabbly offers a few channels:
- `lts-7.0` — Incus 7.0.x LTS (recommended for production/stability)
- `stable` — latest release of Incus
- `daily` — untested daily builds (avoid on production)

Create the source file (using `lts-7.0`, adjust if you prefer `stable`):

```bash
cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-lts-7.0.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-7.0
Suites: jammy
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
```

> If you'd rather track the newest releases instead of LTS, replace `lts-7.0` with `stable` in both the filename and the `URIs` line.

## 5. Refresh package cache

```bash
apt update
```

You should see a line referencing `https://pkgs.zabbly.com/incus/lts-7.0 ...` (or `stable`) in the output — this confirms the repo is active.

## 6. Install Incus

```bash
apt install -y incus
```

To also support **virtual machines** (not just containers), install QEMU support:

```bash
apt install -y incus qemu-system
```

Optional web UI:

```bash
apt install -y incus-ui-canonical
```

## 7. Verify installation

```bash
incus version
```

## 8. Add your user to the `incus-admin` group (skip if working purely as root)

```bash
usermod -aG incus-admin $USER
```

Then log out and back in, or run:

```bash
newgrp incus-admin
```

This lets a non-root user manage Incus without `sudo`.

## 9. Initialize Incus

Run the interactive setup wizard:

```bash
incus admin init
```

For a standard single-server setup, pressing **Enter** to accept the defaults for every question is fine. It will walk you through:
- Storage backend (e.g. `zfs`, `btrfs`, `dir`, `lvm`) and pool size
- Network bridge creation (for container/VM networking)
- Whether to make Incus available over the network (skip unless you need remote API access)
- Whether to create a default image alias

## 10. Test it

Launch a test container:

```bash
incus launch images:ubuntu/22.04 test-container
```

Check it's running:

```bash
incus list
```

Get a shell inside it:

```bash
incus exec test-container -- bash
```

Clean up the test container when done:

```bash
incus delete test-container --force
```
# Incus Macvlan & GUI Troubleshooting Guide

## Goal

-   Ubuntu Incus host: `192.168.77.111`
-   Container: obtain IP from `192.168.77.0/24`
-   Enable Incus HTTPS API/UI.

## 1. Verify host networking

``` bash
ip -br a
ip route
ping -c 4 192.168.77.1
```

Expected host IP:

``` text
192.168.77.111/24
```

------------------------------------------------------------------------

## 2. Create a macvlan network

``` bash
incus network create lan --type=macvlan parent=ens33
```

Verify:

``` bash
incus network list
incus network show lan
```

------------------------------------------------------------------------

## 3. Attach the network to the container

If `eth0` already exists:

``` bash
incus config device set vm-001 eth0 network=lan
```

If not:

``` bash
incus config device add vm-001 eth0 nic network=lan
```

Restart the container:

``` bash
incus restart vm-001
```

------------------------------------------------------------------------

## 4. Inside the container

``` bash
incus exec vm-001 -- bash

ip link set eth0 up
dhclient eth0

ip -br a
ip route
```

Expected:

``` text
192.168.77.128/24
```

------------------------------------------------------------------------

## 5. Verify from the host

``` bash
incus info vm-001
```

Look for:

``` text
inet: 192.168.77.128/24
```

------------------------------------------------------------------------

## 6. Important macvlan limitation

The Incus host **cannot communicate** directly with its macvlan
containers.

Works: - Windows PC -\> Container - Router -\> Container - Internet -\>
Container

Does not work: - Ubuntu Host -\> Container

This is expected Linux macvlan behavior.

------------------------------------------------------------------------

# Incus HTTPS API / GUI

## Check configuration

``` bash
incus info
incus config show
```

If:

``` text
addresses: []
```

then configure:

``` bash
incus config set core.https_address 192.168.77.111:8443
systemctl restart incus
```

Verify:

``` bash
incus config get core.https_address
ss -tlnp | grep 8443
```

Expected:

``` text
LISTEN 192.168.77.111:8443
```

Test:

``` bash
curl -k https://192.168.77.111:8443
```

If port 8443 is still not listening:

``` bash
journalctl -u incus -n 100 --no-pager
```

------------------------------------------------------------------------

# VMware Requirements

VMware Workstation VM network adapter should be:

-   Bridged

Not:

-   NAT
-   Host-only

------------------------------------------------------------------------

# Connectivity Tests

From Windows:

``` cmd
ping 192.168.77.218
ssh root@192.168.77.218
```

From host:

``` bash
incus list
incus info vm-001
```

---

## Useful everyday commands

| Task | Command |
|---|---|
| List instances | `incus list` |
| Launch a container | `incus launch images:<distro>/<version> <name>` |
| Launch a VM | `incus launch images:<distro>/<version> <name> --vm` |
| Stop an instance | `incus stop <name>` |
| Start an instance | `incus start <name>` |
| Delete an instance | `incus delete <name>` |
| Shell into instance | `incus exec <name> -- bash` |
| Show instance info | `incus info <name>` |
| List images | `incus image list` |

---

## Uninstalling Incus (if needed)

```bash
apt remove --purge -y incus incus-ui-canonical
rm /etc/apt/sources.list.d/zabbly-incus-lts-7.0.sources
rm /etc/apt/keyrings/zabbly.asc
apt update
```

---

## Notes specific to your setup

- Since `node1` appears to be a server you administer directly as root, you can skip the `incus-admin` group step and just run `incus` commands as root.
- If this machine already runs Docker, LXC, or KVM/libvirt, there's no conflict — Incus can coexist, but double-check bridge/network interface names during `incus admin init` to avoid overlapping with existing bridges (e.g. `docker0`, `virbr0`).
- If you plan to run this in production serving other infra (like your Zimbra/TACACS+ boxes), consider using `lts-7.0` rather than `stable`, and keep automatic upgrades of Incus disabled/controlled so you can test before updating.
