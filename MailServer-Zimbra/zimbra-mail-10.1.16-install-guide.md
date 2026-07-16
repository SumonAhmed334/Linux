# Zimbra OSE 10.1.16 Installation Guide (Annotated)
**Date:** 07-APRIL-2026
**Target host:** `103.118.87.130` → `mail2.sumonahmed.xyz`

> This is your original command list with explanations added under each block, so you (or anyone else) can understand *why* each step exists, not just *what* it does.

---

## 1. SSH Access

```bash
ssh mailserver@103.118.87.130 ssh-port: 22
mailserver | 12345@Fhl
```

**Explanation:** Initial SSH login credentials for the server. `ssh-port: 22` just notes the port used (default SSH port). Consider rotating this password after setup and disabling password auth in favor of SSH keys once the server is live.

---

## 2. Disable systemd-resolved and Set Static DNS

```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved.service
rm -fr /etc/resolv.conf
touch /etc/resolv.conf
echo "nameserver 9.9.9.9" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 1.0.0.3" >> /etc/resolv.conf
```

**Explanation:** Ubuntu's default `systemd-resolved` manages `/etc/resolv.conf` as a symlink to a stub resolver, which can interfere with mail server DNS lookups (especially reverse DNS / PTR checks that Zimbra relies on for anti-spam). This block:
- Stops and disables that service so it no longer manages DNS.
- Deletes the symlinked `resolv.conf` and replaces it with a plain file.
- Hardcodes DNS resolvers: Quad9 (`9.9.9.9`), Google (`8.8.8.8`), and a Cloudflare-family resolver (`1.0.0.3`, which filters malware).

⚠️ Note: later in the guide this file gets overwritten again with only `8.8.8.8` and `1.0.0.3` — that's likely intentional (final DNS state), just be aware the first block's `9.9.9.9` entry doesn't persist.

---

## 3. Locale Configuration

```bash
apt -y install locales locales-all
dpkg-reconfigure locales     # select en_US.UTF-8
update-locale LANG=en_US.UTF-8 LANGUAGE="en_US:en"
export LANG=en_US.UTF-8

cd /root/
echo "export LANG=en_US.UTF-8" >> .profile
echo "export LANG=en_US.UTF-8" >> .bashrc
```

**Explanation:** Zimbra requires a UTF-8 locale to be properly configured — installation fails or behaves oddly without it. This installs all locale data, sets `en_US.UTF-8` as the system default, and persists the `LANG` variable in root's shell startup files so it survives reboots and new SSH sessions.

---

## 4. Netplan Static IP Configuration

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      dhcp6: false
      link-local: []
      addresses:
      - 103.118.87.130/26
      optional: true
      routes:
        - to: default
          via: 103.118.87.129
      nameservers:
        addresses:
        - 8.8.8.8
        - 1.0.0.3
```

**Explanation:** This is a Netplan YAML config (normally placed in `/etc/netplan/*.yaml`) that assigns a **static IP** to interface `ens18`:
- Disables DHCP for IPv4/IPv6.
- Assigns `103.118.87.130` with a `/26` subnet mask (64 addresses).
- Sets the default gateway to `103.118.87.129`.
- Sets DNS resolvers directly at the network layer (belt-and-suspenders with the `resolv.conf` edits above).

A mail server needs a static IP because its IP is tied to reverse DNS (PTR) records and sender reputation — a changing IP would break mail deliverability.

---

## 5. Install Required Packages

```bash
sudo apt update
sudo apt install nano wget bind9utils telnet perl ufw tar resolvconf net-tools tzdata vim bind9-dnsutils inetutils-ping telnet -y
sudo apt install libgmp3-dev libjson-perl sqlite3 lsb-release
sudo ufw disable
```

**Explanation:** Installs Zimbra's prerequisite packages and general admin utilities:
- `bind9utils` / `bind9-dnsutils` — DNS diagnostic tools (`dig`, `nslookup`).
- `perl`, `libjson-perl`, `libgmp3-dev` — Zimbra/Perl script dependencies.
- `sqlite3` — used by some Zimbra components.
- `lsb-release` — Zimbra's installer checks OS identity via this.
- `ufw disable` — turns off the local firewall entirely. **This is a strong step** — normally you'd configure `ufw` rules for the mail ports instead of disabling it outright. If this server sits behind another firewall/security group (cloud provider level), this may be acceptable; otherwise consider re-enabling `ufw` with proper rules after install (25, 80, 110, 143, 443, 465, 587, 993, 995, 7071, etc.).

---

## 6. Hostname and Timezone

```bash
hostnamectl set-hostname mail2.sumonahmed.xyz
timedatectl set-timezone Asia/Dhaka
```

**Explanation:** Sets the machine's FQDN hostname (Zimbra installer requires the hostname to match a resolvable FQDN) and sets the system timezone to `Asia/Dhaka` — important for accurate timestamps in mail headers and logs.

---

## 7. Stop and Disable Postfix

```bash
systemctl stop postfix
systemctl disable postfix
```

**Explanation:** Ubuntu ships with Postfix pre-installed by default in many setups. Zimbra bundles and manages its own Postfix instance, so the system's stock Postfix must be stopped and disabled to avoid a port conflict on 25/587/465.

---

## 8. /etc/hosts Entry

```bash
vim /etc/hosts
103.118.87.131 mail2.sumonahmed.xyz mail
```

**Explanation:** Adds a local hosts-file mapping so the hostname resolves locally even before/independent of DNS propagation. ⚠️ Note the IP here is `103.118.87.131`, which differs from the `103.118.87.130` used everywhere else in the guide — double-check this isn't a typo, since a mismatched IP here can cause Zimbra's install-time hostname resolution check to behave unexpectedly.

---

## 9. DNS Resolver Re-confirmation

```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved.service
rm -fr /etc/resolv.conf
touch /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 1.0.0.3" >> /etc/resolv.conf

nslookup mail2.sumonahmed.xyz
```

**Explanation:** Reasserts the static DNS config (in case anything reset it) and verifies the hostname resolves correctly with `nslookup` before proceeding — Zimbra's installer performs its own resolution check and will fail early if this isn't correct. The sample output confirms `mail2.sumonahmed.xyz` resolves to `103.118.87.130` via the local server.

---

## 10. Download and Extract Zimbra OSE

```bash
# Source: https://maldua.github.io/zimbra-foss/downloads/
# Repo:   https://github.com/maldua/zimbra-foss/releases

cd /opt/
wget https://github.com/maldua/zimbra-foss/releases/download/zimbra-foss-build-ubuntu-22.04%2F10.1.16.p1/zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616.tgz
tar -xvf zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616.tgz

cd zcs-10.1.16_GA_4200001.UBUNTU22_64.20260310121616/
./install.sh
```

**Explanation:** This downloads a community-maintained **Zimbra OSE (Open Source Edition)** build from the `maldua/zimbra-foss` GitHub project — since Zimbra Collaboration stopped publishing free OSE builds officially, this is a third-party rebuild for Ubuntu 22.04. It's extracted to `/opt/` and the interactive installer (`install.sh`) is run. During the install you'll be prompted for domain name, admin password, and which components to enable (LDAP, mailboxd, MTA, spam/antivirus, etc.).

**Admin credentials captured during install:**
```
admin-password: wP_H!five@111101
admin@mail2.sumonahmed.xyz
```

**Access points after install:**
```
Zimbra Admin Console: https://103.118.87.130:7071
Web Client:            https://103.118.87.130
```

🔒 **Security note:** These are live credentials in plaintext. Store them in a password manager and remove/redact them from any shared or archived copy of this document.

---

## 11. Post-Install Zimbra Tuning

```bash
su - zimbra -c "zmprov mcf zimbraModernWebClientDisabled TRUE"
su - zimbra -c "zmprov mc default zimbraPrefClientType advanced"
su - zimbra -c "zmlocalconfig -e mailboxd_java_heap_size=4096"
su - zimbra -c "zmlocalconfig -e mailboxd_java_heap_memory_percent=25"
su - zimbra -c "zmlocalconfig -e zimbra_require_interprocess_security=0"

su - zimbra -c "zmcontrol restart"
su - zimbra -c "zmcontrol status"
```

**Explanation:** Fine-tunes Zimbra's behavior post-install:
- `zimbraModernWebClientDisabled TRUE` — disables the newer "Modern" web UI, forcing the classic web client.
- `zimbraPrefClientType advanced` — sets the default web client mode to "Advanced" (the full-featured UI) for new/default accounts.
- `mailboxd_java_heap_size=4096` — sets the mailboxd (mail server Java process) heap to 4096 MB. Tune based on available RAM.
- `mailboxd_java_heap_memory_percent=25` — caps mailboxd's heap at 25% of total system memory as a safety ceiling.
- `zimbra_require_interprocess_security=0` — disables mutual TLS/auth requirements between local Zimbra processes talking to each other on localhost (a common tweak in single-node deployments to reduce local IPC overhead — only safe on trusted, single-server setups).
- `zmcontrol restart` / `status` — restarts all Zimbra services to apply the config changes, then confirms every service came back up.

```bash
reboot
```

**Explanation:** A full reboot to ensure all kernel/network/hostname changes and services come up cleanly from a fresh boot state.

---

## 12. Let's Encrypt SSL Certificate Installation

> Reference: [Zimbra Wiki – Installing a Let's Encrypt SSL Certificate](https://wiki.zimbra.com/wiki/Installing_a_LetsEncrypt_SSL_Certificate)

```bash
sudo apt install -y net-tools dnsutils
hostname --fqdn

netstat -tulpn | grep ":80"   # stop Zimbra's web service if this port is occupied
netstat -tulpn | grep ":443"
```

**Explanation:** Checks whether ports 80/443 are already bound (usually by Zimbra's own nginx proxy). Certbot's `--standalone` mode needs port 80 free to complete the HTTP-01 challenge, so if Zimbra is holding it, you must stop the relevant Zimbra service (`zmproxyctl stop` or similar) before running certbot.

```bash
apt install -y python3 python3-venv libaugeas0
python3 -m venv /opt/certbot/
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot
ln -s /opt/certbot/bin/certbot /usr/local/sbin/certbot
```

**Explanation:** Installs Certbot inside an isolated Python virtual environment (recommended by the official Certbot docs instead of `apt install certbot`, which can be outdated on some distros), then symlinks the binary into `/usr/local/sbin` so it's available system-wide as `certbot`.

```bash
/usr/local/sbin/certbot certonly -d mail2.sumonahmed.xyz --standalone --preferred-chain "ISRG Root X2" --agree-tos --register-unsafely-without-email
```

**Explanation:** Requests a certificate for `mail2.sumonahmed.xyz` using the standalone HTTP challenge method. `--preferred-chain "ISRG Root X2"` requests the newer ISRG Root X2 (ECDSA) chain instead of the default cross-signed chain. `--register-unsafely-without-email` skips providing a contact email (you won't get expiry/renewal notices from Let's Encrypt this way — worth reconsidering).

```bash
cp "/etc/letsencrypt/live/mail2.sumonahmed.xyz/privkey.pem" /opt/zimbra/ssl/zimbra/commercial/commercial.key
chown zimbra:zimbra /opt/zimbra/ssl/zimbra/commercial/commercial.key

wget -O /tmp/ISRG-X2.pem https://letsencrypt.org/certs/isrg-root-x2.pem
rm -f "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
cp "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chain.pem" "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
cat /tmp/ISRG-X2.pem >> "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
chown zimbra:zimbra /etc/letsencrypt -R

cd /tmp
su zimbra -c '/opt/zimbra/bin/zmcertmgr deploycrt comm "/etc/letsencrypt/live/mail2.sumonahmed.xyz/cert.pem" "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"'
rm -f "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"

sleep 2
sudo su zimbra -c '/opt/zimbra/bin/zmcontrol restart'
```

**Explanation:** Deploys the issued cert into Zimbra:
1. Copies the private key into Zimbra's expected commercial-cert path and fixes ownership (Zimbra services run as the `zimbra` user and won't read files owned by `root`).
2. Downloads the ISRG Root X2 root cert and appends it to the intermediate chain — Zimbra needs the **full chain** (intermediate + root) in one file (`chainZimbra.pem`) for `zmcertmgr` to validate it properly.
3. `zmcertmgr deploycrt comm` installs the certificate + chain as Zimbra's "commercial" certificate (Zimbra's term for a CA-signed cert, as opposed to its self-signed default).
4. Cleans up the temporary chain file and restarts all Zimbra services so nginx/mailboxd pick up the new cert.

---

## 13. Auto-Renewal Script + Cron Job

```bash
cat >> /usr/local/sbin/letsencrypt-zimbra << EOF
#!/bin/bash
/usr/local/sbin/certbot certonly -d mail2.sumonahmed.xyz --standalone --preferred-chain "ISRG Root X2" --agree-tos --register-unsafely-without-email
cp "/etc/letsencrypt/live/mail2.sumonahmed.xyz/privkey.pem" /opt/zimbra/ssl/zimbra/commercial/commercial.key
chown zimbra:zimbra /opt/zimbra/ssl/zimbra/commercial/commercial.key
wget -O /tmp/ISRG-X2.pem https://letsencrypt.org/certs/isrg-root-x2.pem
rm -f "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
cp "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chain.pem" "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
cat /tmp/ISRG-X2.pem >> "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
chown zimbra:zimbra /etc/letsencrypt -R
cd /tmp
su zimbra -c '/opt/zimbra/bin/zmcertmgr deploycrt comm "/etc/letsencrypt/live/mail2.sumonahmed.xyz/cert.pem" "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"'
rm -f "/etc/letsencrypt/live/mail2.sumonahmed.xyz/chainZimbra.pem"
sleep 2
sudo su zimbra -c '/opt/zimbra/bin/zmcontrol restart'
EOF
```

**Explanation:** Packages the exact same steps from section 12 into a reusable script at `/usr/local/sbin/letsencrypt-zimbra`, so renewal can be automated without manual intervention.

> ⚠️ **Missing step:** the script content is written but the file isn't made executable. You should add:
> ```bash
> chmod +x /usr/local/sbin/letsencrypt-zimbra
> ```

```bash
vim /etc/crontab
@monthly         root    /usr/local/sbin/letsencrypt-zimbra >/dev/null 2>&1
```

**Explanation:** Adds a monthly cron job (via `/etc/crontab`, run as `root`) that re-requests and redeploys the certificate. Let's Encrypt certs are valid for 90 days, so a monthly run comfortably renews before expiry (certbot's `certonly` will skip re-issuance if the cert isn't close to expiring — though note this script always forces a fresh **certonly** call rather than using `certbot renew`, which is the more standard/idempotent approach and avoids unnecessary rate-limit usage against Let's Encrypt).

---

## Summary Checklist

| Step | Status | Notes |
|---|---|---|
| DNS / resolv.conf configured | ✅ | Static resolvers set |
| Static IP via Netplan | ✅ | `103.118.87.130/26` |
| Locale set to en_US.UTF-8 | ✅ | Required by Zimbra installer |
| Stock Postfix disabled | ✅ | Avoids port conflict |
| Hostname set + verified via nslookup | ✅ | Watch the `.131` vs `.130` discrepancy in `/etc/hosts` |
| Zimbra OSE installed | ✅ | Community build (maldua/zimbra-foss) |
| Java heap tuned | ✅ | 4096 MB / 25% cap |
| Let's Encrypt cert issued & deployed | ✅ | ISRG Root X2 chain |
| Auto-renewal cron configured | ⚠️ | Script needs `chmod +x`; consider `certbot renew` pattern |
| `ufw` firewall | ⚠️ | Currently disabled — re-enable with mail-specific rules if not protected elsewhere |

---

*Generated as an annotated reference version of the original install notes dated 07-APRIL-2026.*
