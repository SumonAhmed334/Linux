# Installing GitLab CE on Rocky Linux (8 / 9)

A step-by-step guide to install GitLab Community Edition on Rocky Linux 8 or 9.

## Prerequisites

- Rocky Linux server (8 or 9)
- Minimum 4GB RAM (8GB+ recommended for production; add swap if you're on 4GB — see Troubleshooting)
- Root or sudo access
- Domain name pointed to your server (recommended for production, needed for Let's Encrypt)

## Installation Steps

### 1. Update System Packages

```bash
sudo dnf update -y
```

A reboot may be required afterward if the kernel was updated:

```bash
sudo needs-restarting -r
sudo reboot   # only if the previous command says a reboot is needed
```

### 2. Install Required Dependencies

```bash
sudo dnf install -y curl policycoreutils-python-utils openssh-server perl postfix
```

> Note: the package is `policycoreutils-python-utils`, not `policycoreutils` — it provides the SELinux management tools (`semanage`, etc.) that GitLab's installer needs on Rocky Linux 8/9, which run SELinux in enforcing mode by default.

### 3. Enable and Start Services

```bash
sudo systemctl enable --now sshd
sudo systemctl enable --now postfix
```

### 4. Add the GitLab Repository

```bash
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh | sudo bash
```

This adds the `gitlab_gitlab-ce` repo and imports GitLab's GPG signing keys.

### 5. Install GitLab CE

```bash
sudo EXTERNAL_URL="http://your-domain-or-ip" dnf install -y gitlab-ce
```

Example:

```bash
sudo EXTERNAL_URL="http://gitlab.example.com" dnf install -y gitlab-ce
```

This step downloads a large package (1GB+) and can take a while depending on your connection.

### 6. Configure GitLab

```bash
sudo gitlab-ctl reconfigure
```

This can take several minutes on first run — it sets up PostgreSQL, Redis, Puma, Nginx, etc.

### 7. Configure the Firewall (if `firewalld` is active)

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### 8. Get the Initial Root Password

GitLab no longer prompts you to set a password in the browser. Instead it auto-generates one on first install:

```bash
sudo cat /etc/gitlab/initial_root_password
```

**This file is deleted automatically 24 hours after the first `reconfigure`**, so grab the password (or change it) before then.

### 9. Access the Web Interface

Open a browser and go to the URL you set as `EXTERNAL_URL` (e.g. `http://gitlab.example.com`). Log in as `root` with the password from step 8, then change it immediately under **User Settings > Password**.

## Post-Installation Configuration

### Configure HTTPS (recommended for production)

1. Edit the config file:

    ```bash
    sudo nano /etc/gitlab/gitlab.rb
    ```

2. Update the external URL to HTTPS:

    ```ruby
    external_url 'https://gitlab.example.com'
    ```

3. Enable Let's Encrypt:

    ```ruby
    letsencrypt['enable'] = true
    letsencrypt['contact_emails'] = ['admin@example.com']
    ```

4. Reconfigure:

    ```bash
    sudo gitlab-ctl reconfigure
    ```

> Make sure port 80 is reachable from the internet during this step — Let's Encrypt's HTTP-01 challenge needs it, even though your final site will run on 443.

### Configure Email (optional)

Edit `/etc/gitlab/gitlab.rb`:

```bash
sudo nano /etc/gitlab/gitlab.rb
```

Add SMTP settings (example for Gmail — use an app password, not your account password):

```ruby
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.gmail.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "your@gmail.com"
gitlab_rails['smtp_password'] = "your-app-password"
gitlab_rails['smtp_domain'] = "gmail.com"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['gitlab_email_from'] = "your@gmail.com"
```

Then reconfigure:

```bash
sudo gitlab-ctl reconfigure
```

## Maintenance Commands

| Task | Command |
|---|---|
| Check status | `sudo gitlab-ctl status` |
| Start all services | `sudo gitlab-ctl start` |
| Stop all services | `sudo gitlab-ctl stop` |
| Restart all services | `sudo gitlab-ctl restart` |
| Create backup | `sudo gitlab-backup create` |
| Tail logs | `sudo gitlab-ctl tail` |
| Reconfigure after config change | `sudo gitlab-ctl reconfigure` |

## Troubleshooting

### Memory issues / low RAM

GitLab is memory-hungry (PostgreSQL + Redis + Puma + Sidekiq + Nginx all running at once). If you're on 4GB RAM, add swap:

```bash
sudo dd if=/dev/zero of=/swapfile bs=1G count=4
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### `%posttrans` scriptlet errors during install

If the `gitlab-ce` install fails partway with a scriptlet/SELinux-related error, it's usually an SELinux context issue. Confirm `policycoreutils-python-utils` was installed **before** `gitlab-ce`, then re-run:

```bash
sudo gitlab-ctl reconfigure
```

### Check SELinux status

```bash
sudo sestatus
```

If SELinux is enforcing and something is being blocked, check `/var/log/audit/audit.log` for `AVC denied` entries rather than disabling SELinux outright.
