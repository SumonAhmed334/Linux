# Nextcloud Installation Guide — Ubuntu 22.04 LTS (Apache + MariaDB + PHP 8.2)

Verified, working step-by-step guide to install Nextcloud on Ubuntu 22.04 Server. This version has been tested end-to-end and includes the PHP 8.2 fix required by current Nextcloud releases (Ubuntu 22.04 ships PHP 8.1 by default, which is too old).

---

## 1. Prerequisites

- Ubuntu 22.04 LTS Server (minimal install), root/sudo access.
- A domain name pointing to this server's public IP (optional, only needed for Let's Encrypt SSL). Not required for LAN-only use.
- At least 2 GB RAM, 2 CPU cores, and enough disk space for your data.
- Static IP configured on the server.

---

## 2. Update the system

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

---

## 3. Install Apache

```bash
sudo apt install apache2 -y
sudo systemctl enable --now apache2
```

Allow HTTP/HTTPS through UFW if enabled:

```bash
sudo ufw allow "Apache Full"
```

---

## 4. Install MariaDB and create the Nextcloud database

```bash
sudo apt install mariadb-server -y
sudo mysql_secure_installation
```

Answer the prompts: set root password, remove anonymous users, disallow remote root login, remove test DB, reload privileges — answer **Yes** to all.

Create the database and user:

```bash
sudo mysql -u root -p
```

```sql
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ncuser'@'localhost' IDENTIFIED BY 'YourStrongPasswordHere';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncuser'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> Replace `YourStrongPasswordHere` with a real strong password and note it down — you'll enter it in the web setup wizard (Step 10) as **Database password**.

**Sanity checks (optional but recommended before moving on):**
```bash
mysql -u ncuser -p'YourStrongPasswordHere' -e "SHOW DATABASES;" nextcloud
sudo mysql -u root -p -e "SELECT User,Host FROM mysql.user WHERE User='ncuser';"
sudo mysql -u root -p -e "SHOW GRANTS FOR 'ncuser'@'localhost';"
```
You should see the `nextcloud` DB listed, a single `ncuser | localhost` row, and a `GRANT ALL PRIVILEGES ON nextcloud.*` line.

---

## 5. Install PHP 8.2 (required — PHP 8.1 is NOT sufficient)

Current Nextcloud releases require **PHP 8.2 or newer**. Ubuntu 22.04's default repos only carry PHP 8.1, so add Ondřej Surý's repository directly from `packages.sury.org` (do **not** use `add-apt-repository ppa:ondrej/php` — it queries Launchpad's API and commonly hangs/times out on servers with restricted or slow outbound access).

```bash
sudo apt install -y ca-certificates apt-transport-https gnupg2
sudo curl -sSLo /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php.list
sudo apt update
```

Install PHP 8.2 and required extensions:

```bash
sudo apt install php8.2 libapache2-mod-php8.2 \
  php8.2-gd php8.2-mysql php8.2-curl php8.2-mbstring php8.2-intl \
  php8.2-gmp php8.2-bcmath php8.2-xml php8.2-imagick php8.2-zip \
  php8.2-cli php8.2-common php8.2-opcache php8.2-readline \
  php8.2-fileinfo -y
```

Disable PHP 8.1's Apache module (if previously installed) and enable 8.2:

```bash
sudo a2dismod php8.1 2>/dev/null
sudo a2enmod php8.2
sudo systemctl restart apache2
php -v
```

Confirm the output shows `PHP 8.2.x`.

### Tune PHP for Nextcloud

```bash
sudo nano /etc/php/8.2/apache2/php.ini
```

Set/adjust these values:

```ini
memory_limit = 512M
upload_max_filesize = 1G
post_max_size = 1G
max_execution_time = 300
date.timezone = Asia/Dhaka
```

Restart Apache:

```bash
sudo systemctl restart apache2
```

---

## 6. Download and extract Nextcloud

```bash
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip
sudo apt install unzip -y
unzip latest.zip
sudo mv nextcloud /var/www/
```

Set correct ownership:

```bash
sudo chown -R www-data:www-data /var/www/nextcloud
sudo chmod -R 750 /var/www/nextcloud
```

---

## 7. Configure Apache virtual host

```bash
sudo nano /etc/apache2/sites-available/nextcloud.conf
```

```apache
<VirtualHost *:80>
    DocumentRoot /var/www/nextcloud
    ServerName nextcloud.sumonahmed.xyz

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
```

Enable the site and required Apache modules, and disable the default site so Nextcloud is served on `/`:

```bash
sudo a2ensite nextcloud.conf
sudo a2dissite 000-default.conf
sudo a2enmod rewrite headers env dir mime setenvif
sudo systemctl restart apache2
```

**Verify before browsing:**
```bash
apache2ctl configtest        # should say "Syntax OK"
apache2ctl -S                # confirm nextcloud.conf is listed as active vhost
sudo ufw status               # if active, ensure 80/tcp (or "Apache Full") is allowed
curl -I http://localhost      # should return HTTP/1.1 200 OK
```

---

## 8. Set the server hostname and local DNS resolution (optional, for domain-based access)

If you want to reach the server by its domain name (e.g. `nextcloud.sumonahmed.xyz`) instead of the raw IP — useful since `ServerName` in the vhost is already set to a domain — and you don't have public DNS pointing here (or don't want to expose it publicly), set the hostname and add a local hosts entry on the **server itself**:

```bash
sudo hostnamectl set-hostname nextcloud.sumonahmed.xyz
sudo nano /etc/hosts
```

Add/confirm a line mapping the server's LAN IP to the domain:

```
192.168.102.37 nextcloud.sumonahmed.xyz nextcloud
```

Verify:
```bash
cat /etc/hosts
hostnamectl
```

> This only makes the name resolve **on the server itself** (e.g. for `curl`, cron jobs, `occ` commands). For your **browser/client machine** to resolve `nextcloud.sumonahmed.xyz` to `192.168.102.37`, you need one of:
> - An internal DNS server (e.g. your Technitium DNS instance) with an A record for `nextcloud.sumonahmed.xyz → 192.168.102.37`, or
> - A matching entry in the client machine's own hosts file (`C:\Windows\System32\drivers\etc\hosts` on Windows, `/etc/hosts` on Linux/Mac):
>   ```
>   192.168.102.37 nextcloud.sumonahmed.xyz
>   ```
>
> Since `sumonahmed.xyz` is a real public domain (used elsewhere for your GitLab setup), be careful not to confuse this internal-only mapping with a real public DNS record — they're independent, and a public A record for this subdomain pointing elsewhere would override this for anyone outside your LAN.

---

## 9. Access the Web UI

From a browser on the same network:

```
http://<server-ip>
```

e.g. `http://192.168.102.37`

Or, once local DNS/hosts resolution is set up per Step 8:

```
http://nextcloud.sumonahmed.xyz
```

---

## 10. Run the web-based setup

Fill in the setup wizard:

- **Administration account name / password** — the Nextcloud admin login (separate from the DB user).
- **Data folder** — default `/var/www/nextcloud/data` is fine, or point to a separate mounted disk for storage.
- **Database configuration** → **MySQL/MariaDB**:
  - Database user: `ncuser`
  - Database password: the password you set in Step 4
  - Database name: `nextcloud`
  - Database host: `localhost`

Click **Install**.

> If you get `SQLSTATE[HY000] [1045] Access denied for user 'ncuser'@'localhost'`, the password typed in the form doesn't match what MariaDB has. Reset it explicitly and retry:
> ```bash
> sudo mysql -u root -p -e "ALTER USER 'ncuser'@'localhost' IDENTIFIED BY 'YourNewStrongPassword'; FLUSH PRIVILEGES;"
> ```
> Then re-enter that exact password in the web form.

---

## 11. Secure the install with Let's Encrypt SSL (optional, needs a real domain)

```bash
sudo apt install certbot python3-certbot-apache -y
sudo certbot --apache -d nextcloud.yourdomain.com
```

Certbot will auto-edit the vhost for HTTPS and set up auto-renewal.

---

## 12. Post-install hardening & tuning

1. **Enable a caching layer (recommended)** — install Redis for file locking/caching:
   ```bash
   sudo apt install redis-server php8.2-redis -y
   ```
   Then add to `/var/www/nextcloud/config/config.php`:
   ```php
   'memcache.local' => '\OC\Memcache\APCu',
   'memcache.locking' => '\OC\Memcache\Redis',
   'redis' => [
        'host' => 'localhost',
        'port' => 6379,
   ],
   ```

2. **Set up cron for background jobs** (instead of AJAX):
   ```bash
   sudo crontab -u www-data -e
   ```
   Add:
   ```
   */5 * * * * php -f /var/www/nextcloud/cron.php
   ```
   Then in Nextcloud admin settings (**Basic settings**), switch background jobs to **Cron**.

3. **Trusted domains** — if accessing via multiple hostnames/IPs, edit:
   ```bash
   sudo nano /var/www/nextcloud/config/config.php
   ```
   Add extra entries to the `trusted_domains` array.

4. **Run the built-in security/setup check**: Admin panel → **Settings → Administration → Overview** — resolve any warnings shown. Common fixes:
   ```bash
   sudo -u www-data php /var/www/nextcloud/occ db:add-missing-indices
   sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
   ```

---

## 13. Troubleshooting

| Issue | Fix |
|---|---|
| "This version of Nextcloud requires at least PHP 8.2" | You're on PHP 8.1 — follow Step 5 to install PHP 8.2 via `packages.sury.org` and switch the Apache module |
| `add-apt-repository ppa:ondrej/php` hangs / KeyboardInterrupt | Launchpad API access is slow/blocked; skip it and use the `packages.sury.org` method in Step 5 instead |
| `apt install php8.2...` → "Unable to locate package" | The PHP repo wasn't actually added (often because the PPA command above was interrupted). Re-check `/etc/apt/sources.list.d/php.list` exists and re-run `apt update` |
| Web UI not reachable at all | Check `sudo systemctl status apache2`; confirm IP with `ip -br a`; check `apache2ctl -S` shows `nextcloud.conf` as active vhost; check UFW |
| `nextcloud_error.log` is empty, page won't load | Traffic isn't reaching Apache — check firewall/network path between client and server, not Apache config |
| `SQLSTATE[HY000] [1045] Access denied for user 'ncuser'` | Password mismatch — reset with `ALTER USER 'ncuser'@'localhost' IDENTIFIED BY '...'` and re-enter exactly in the form |
| Upload fails on large files | Recheck `upload_max_filesize` / `post_max_size` in `/etc/php/8.2/apache2/php.ini`, restart Apache |
| "Access through untrusted domain" error | Add your IP/hostname to `trusted_domains` in `config.php` |
| "Some columns are missing indices" warning | Run `occ db:add-missing-indices` (Step 12.4) |
| Permission errors after moving/copying files | Re-run `sudo chown -R www-data:www-data /var/www/nextcloud` |

---

## References

- Official install docs: `https://docs.nextcloud.com/server/latest/admin_manual/installation/`
- Server tuning guide: `https://docs.nextcloud.com/server/latest/admin_manual/installation/server_tuning.html`
- PHP packages (Sury repo): `https://packages.sury.org/php/`
