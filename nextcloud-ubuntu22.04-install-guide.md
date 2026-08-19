# Nextcloud Installation Guide — Ubuntu 22.04 LTS (Apache + MariaDB + PHP 8.1)

Step-by-step guide to install Nextcloud from scratch on Ubuntu 22.04 Server using the classic LAMP stack (Apache, MariaDB, PHP), with optional Let's Encrypt SSL.

---

## 1. Prerequisites

- Ubuntu 22.04 LTS Server (minimal install), root/sudo access.
- A domain name pointing to this server's public IP (if you want SSL via Let's Encrypt). Not required for LAN-only use.
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
CREATE USER 'ncuser'@'localhost' IDENTIFIED BY 'StrongPasswordHere';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncuser'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> Replace `StrongPasswordHere` with a real strong password and keep it noted — you'll need it during the Nextcloud web setup.

---

## 5. Install PHP 8.1 and required extensions

Ubuntu 22.04 ships PHP 8.1 by default, which is compatible with current Nextcloud releases.

```bash
sudo apt install php8.1 libapache2-mod-php8.1 \
  php8.1-gd php8.1-mysql php8.1-curl php8.1-mbstring php8.1-intl \
  php8.1-gmp php8.1-bcmath php8.1-xml php8.1-imagick php8.1-zip \
  php8.1-cli php8.1-common php8.1-opcache php8.1-readline \
  php8.1-fileinfo -y
```

### Tune PHP for Nextcloud

Edit the Apache PHP config:

```bash
sudo nano /etc/php/8.1/apache2/php.ini
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
    ServerName nextcloud.yourdomain.com

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

Enable the site and required Apache modules:

```bash
sudo a2ensite nextcloud.conf
sudo a2enmod rewrite headers env dir mime setenvif ssl
sudo systemctl restart apache2
```

---

## 8. Run the web-based setup

Open in a browser:

```
http://<server-ip-or-domain>
```

Fill in the setup wizard:
- **Create an admin account** (username/password for Nextcloud itself, separate from DB user).
- **Data folder** — default `/var/www/nextcloud/data` is fine, or point to a separate mounted disk for storage.
- **Database configuration** → choose **MySQL/MariaDB**:
  - Database user: `ncuser`
  - Database password: (the one you set in Step 4)
  - Database name: `nextcloud`
  - Database host: `localhost`

Click **Finish setup**.

---

## 9. Secure the install with Let's Encrypt SSL (optional, needs a real domain)

```bash
sudo apt install certbot python3-certbot-apache -y
sudo certbot --apache -d nextcloud.yourdomain.com
```

Certbot will auto-edit the vhost for HTTPS and set up auto-renewal.

---

## 10. Post-install hardening & tuning

1. **Enable a caching layer (recommended)** — install Redis for file locking/caching:
   ```bash
   sudo apt install redis-server php8.1-redis -y
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
   Then in Nextcloud admin settings (`Basic settings`), switch background jobs to **Cron**.

3. **Trusted domains** — if accessing via multiple hostnames/IPs, edit:
   ```bash
   sudo nano /var/www/nextcloud/config/config.php
   ```
   Add extra entries to the `trusted_domains` array.

4. **Run the built-in security/setup check**: Admin panel → **Settings → Administration → Overview** — resolve any warnings shown (missing PHP modules, missing indices, etc.). Common fixes:
   ```bash
   sudo -u www-data php /var/www/nextcloud/occ db:add-missing-indices
   sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
   ```

---

## 11. Troubleshooting

| Issue | Fix |
|---|---|
| "Access through untrusted domain" error | Add your IP/hostname to `trusted_domains` in `config.php` |
| Upload fails on large files | Recheck `upload_max_filesize` / `post_max_size` in `php.ini`, restart Apache |
| Blank page / 500 error | Check `sudo tail -f /var/log/apache2/nextcloud_error.log` |
| Slow performance | Enable Redis + APCu caching (Step 10.1), switch cron mode (Step 10.2) |
| "Some columns are missing indices" warning | Run `occ db:add-missing-indices` (Step 10.4) |
| Permission errors after moving/copying files | Re-run `sudo chown -R www-data:www-data /var/www/nextcloud` |

---

## References

- Official install docs: `https://docs.nextcloud.com/server/latest/admin_manual/installation/`
- Server tuning guide: `https://docs.nextcloud.com/server/latest/admin_manual/installation/server_tuning.html`
