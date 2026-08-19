# OpenMediaVault Installation Guide — Ubuntu 22.04 LTS

Step-by-step guide to install OpenMediaVault (OMV) on top of an existing Ubuntu 22.04 Server installation using the official `omv-install` script.

---

## 1. Prerequisites

- A clean **Ubuntu 22.04 LTS Server** install (minimal/server install recommended — do NOT use Desktop edition).
- Root or sudo access.
- Static IP configured (recommended before install, so the web UI stays reachable).
- At least 2 GB RAM, 2 CPU cores, and a small OS disk (8–16 GB) separate from the disks you intend to use for storage/RAID.
- Internet access on the box during install.

> ⚠️ OMV expects to fully manage networking, users, and services on this machine. Avoid installing it on a box you're already using for unrelated production workloads.

---

## 2. Update the base system

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

After reboot, log back in via SSH or console.

---

## 3. Set a static IP (recommended)

Edit netplan config (adjust interface name and subnet to match your environment):

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

Example:

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: no
      addresses:
        - 192.168.10.50/24
      routes:
        - to: default
          via: 192.168.10.1
      nameservers:
        addresses: [192.168.10.1, 1.1.1.1]
```

Apply it:

```bash
sudo netplan apply
```

---

## 4. Download and run the official OMV install script

OMV provides an official installer script that converts an Ubuntu/Debian base into OMV.

```bash
wget -O - https://github.com/openmediavault/installScript/raw/master/install | sudo bash
```

What this script does:
- Adds the OMV APT repository (Debian-based, matched to your Ubuntu base).
- Installs all required OMV packages (`openmediavault`, `omv-*` plugins base, Postfix, etc.).
- Purges/reconfigures some system services (Postfix, NetworkManager conflicts) to match OMV's expected configuration.
- Reboots automatically at the end (or prompts you to).

> ⏱️ This step can take 10–20 minutes depending on your connection and package mirrors.

If the script prompts about Postfix configuration, choose **"No configuration"** (OMV manages mail itself if needed later).

---

## 5. Reboot and verify services

```bash
sudo reboot
```

After reboot, check that the core OMV services are running:

```bash
sudo systemctl status openmediavault-engined
sudo systemctl status nginx
```

Both should show `active (running)`.

---

## 6. Access the Web UI

From a browser on the same network:

```
http://<server-ip>
```

Default login credentials:

| Field    | Value      |
|----------|------------|
| Username | `admin`    |
| Password | `openmediavault` |

**Change this password immediately** after first login (Section 8).

---

## 7. Initial post-install checklist

1. **General Settings → Web Administration Password** — change the default `admin` password.
2. **System → Date & Time** — set correct timezone (e.g. `Asia/Dhaka`).
3. **System → Network** — confirm the interface/IP OMV detected matches your static config.
4. **System → Update Management** — check for and apply OMV package updates.
5. **Storage → Disks** — verify all physical disks intended for storage are visible (wipe/initialize as needed under **Storage → File Systems**).

---

## 8. Change the default admin password

Web UI:
`System → General Settings → Web Administration → Password` → set new password → **Save** → **Apply**.

Or via CLI:

```bash
sudo omv-firstaid
```
Select the option to reset the admin web password.

---

## 9. (Optional) Configure storage — quick overview

1. **Storage → Disks** — see attached disks.
2. **Storage → RAID Management** (if using software RAID) — create array first.
3. **Storage → File Systems** — create a filesystem (EXT4/XFS/BTRFS) on the disk or RAID array, then mount it.
4. **Storage → Shared Folders** — create a shared folder pointing to a path on the mounted filesystem.
5. **Services → SMB/CIFS** (or NFS) — enable the service, then add the shared folder as a share and set permissions.

---

## 10. (Optional) Install useful plugins

Web UI: `System → Plugins`, search and install as needed:

- `openmediavault-omvextrasorg` — enables extra repos and plugin management (install this first).
- `openmediavault-smart` — S.M.A.R.T. disk monitoring.
- `openmediavault-backup` — config backup.
- `openmediavault-nut` — UPS monitoring.

---

## 11. Firewall notes (if UFW is enabled)

If UFW is active, allow the web UI and required services:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow samba
sudo ufw allow ssh
```

---

## 12. Troubleshooting

| Issue | Fix |
|---|---|
| Web UI not reachable | Check `sudo systemctl status nginx openmediavault-engined`; confirm IP with `ip a` |
| Locked out of admin password | Run `sudo omv-firstaid` from console/SSH |
| Disks not showing in Storage → Disks | Run `sudo omv-salt deploy run mountpoint` or reboot; check `lsblk` on CLI |
| Install script fails on Postfix prompt | Re-run script; choose "No configuration" for Postfix |
| Network interface renamed/missing after install | Recheck `/etc/netplan/*.yaml`, run `sudo netplan apply` |

---

## References

- Official OMV install script: `https://github.com/openmediavault/installScript`
- OMV documentation: `https://docs.openmediavault.org`
