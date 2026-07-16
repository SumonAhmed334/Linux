# TACACS+ Full Deployment Guide
### Ubuntu 22.04 Server + Network Switch (Cisco / Huawei) End Configuration

---

## 1. Overview

**TACACS+ (Terminal Access Controller Access-Control System Plus)** is used to centralize:
- **Authentication** — who can log in
- **Authorization** — what commands/privilege level they get
- **Accounting** — logging what they did

**Architecture:**

```
[Admin PC] --SSH/Telnet--> [Switch/Router] --TCP/49 (TACACS+)--> [TACACS+ Server: Ubuntu 22.04]
```

This guide uses **tac_plus** (the classic Shrubbery/`tacacs+` daemon, package name `tacacs+` in Ubuntu repos — the same F4.x family you've used before).

---

## 2. Server-Side Setup (Ubuntu 22.04)

### 2.1 Update system & install package

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install tacacs+ -y
```

This installs:
- Binary: `/usr/sbin/tac_plus`
- Config: `/etc/tacacs+/tac_plus.conf`
- Systemd service: `tacacs_plus.service` (or `tac_plus` depending on version — check with `systemctl list-unit-files | grep tac`)

> If the apt package is outdated or missing, you can build from source (tac_plus-ng is the modern actively maintained fork):
> ```bash
> sudo apt install build-essential libssl-dev libwrap0-dev cmake libtalloc-dev -y
> git clone https://github.com/MarcJ/tacacs_plus.git   # or tac_plus-ng repo
> cd tac_plus-ng && cmake . && make && sudo make install
> ```

### 2.2 Check for port 49 conflicts (common issue)

TACACS+ uses **TCP port 49**. Before starting the service, confirm nothing else is bound to it:

```bash
sudo ss -tulnp | grep 49
```

If something else is holding the port (another instance, a stale process, or a container), kill/stop it first:

```bash
sudo lsof -i :49
sudo kill -9 <PID>
```

### 2.3 Configure `/etc/tacacs+/tac_plus.conf`

Back up the default config first:

```bash
sudo cp /etc/tacacs+/tac_plus.conf /etc/tacacs+/tac_plus.conf.bak
```

Example working configuration:

```conf
# ---- Global settings ----
id = spawnd {
    listen = { port = 49 }
    spawn = {
        instances min = 1
        instances max = 10
    }
    background = yes
}

id = tac_plus {
    access log = /var/log/tac_plus/access.log
    accounting log = /var/log/tac_plus/accounting.log

    # Shared secret between server and NAS (switch/router) — must match on both ends
    host = world {
        address = 0.0.0.0/0
        prompt = "Authorized Access Only\n"
        key = "YourStrongSharedSecret123"
    }

    # ---- Group-based command authorization ----
    group = admin_full {
        default service = permit
        service = exec {
            priv-lvl = 15
        }
        cmd = show   { permit .* }
        cmd = config { permit .* }
        cmd = reload { permit .* }
    }

    group = admin_readonly {
        default service = permit
        service = exec {
            priv-lvl = 1
        }
        cmd = show { permit .* }
        cmd = .*   { deny .* }
    }

    # ---- User accounts ----
    user = sumon {
        member = admin_full
        login = des <encrypted_password_here>
        # OR for a quick plain-text test (NOT recommended for production):
        # login = cleartext "TempPass123"
    }

    user = netops1 {
        member = admin_readonly
        login = des <encrypted_password_here>
    }
}
```

**Generate a DES/crypt password hash** to insert into `login = des`:

```bash
python3 -c "import crypt; print(crypt.crypt('YourPassword', crypt.mksalt(crypt.METHOD_CRYPT)))"
```

### 2.4 Create log directory

```bash
sudo mkdir -p /var/log/tac_plus
sudo chown daemon:daemon /var/log/tac_plus
```

### 2.5 Validate config syntax

```bash
sudo tac_plus -C /etc/tacacs+/tac_plus.conf -P
```
(`-P` parses and prints the config without starting the daemon — catches syntax errors early.)

### 2.6 Enable & start the service

```bash
sudo systemctl enable tacacs_plus
sudo systemctl restart tacacs_plus
sudo systemctl status tacacs_plus
```

Watch logs live while testing:

```bash
sudo tail -f /var/log/tac_plus/access.log
journalctl -u tacacs_plus -f
```

### 2.7 Firewall (UFW / iptables)

Allow TCP/49 **only from your management/switch subnet**:

```bash
sudo ufw allow from 192.168.10.0/24 to any port 49 proto tcp
sudo ufw reload
```

### 2.8 Quick local test

Use `tac_plus`'s companion test tool or `telnet`/`nc` to confirm the port is listening:

```bash
sudo ss -tulnp | grep 49
nc -zv <server-ip> 49
```

For a full protocol test, use `test_tac_plus` (bundled with some builds) or simply test from the switch directly (Section 3).

---

## 3. Switch-End Configuration

### 3.1 Cisco IOS / IOS-XE

```cisco
! Enable AAA
aaa new-model

! Define TACACS+ server
tacacs server TAC-SRV1
 address ipv4 <tacacs-server-ip>
 key YourStrongSharedSecret123
 timeout 5

! Group the server(s)
aaa group server tacacs+ TACGROUP
 server name TAC-SRV1

! Authentication for login
aaa authentication login default group TACGROUP local
aaa authentication login VTY_ACCESS group TACGROUP local

! Authorization for commands & exec
aaa authorization exec default group TACGROUP local
aaa authorization commands 15 default group TACGROUP local if-authenticated

! Accounting
aaa accounting exec default start-stop group TACGROUP
aaa accounting commands 15 default start-stop group TACGROUP

! Apply to VTY lines
line vty 0 15
 login authentication VTY_ACCESS
 authorization exec default
 authorization commands 15 default
 transport input ssh

! ALWAYS keep a local fallback account before testing
username localadmin privilege 15 secret LocalBackupPass123
```

> **Critical safety step:** Test in a *separate* VTY line or keep an active console session open while testing. If TACACS+ is misconfigured, you can lock yourself out.

### 3.2 Huawei (VRP — e.g., S5320 series)

This matches your existing environment. Key gotcha from real deployments: the **HWTACACS scheme must be explicitly bound to an AAA domain**, and that domain must be applied to the VTY authentication-mode — this is the step most commonly missed (and matches the unresolved issue in your S5320 setup).

```huawei
# Enable HWTACACS (Huawei's TACACS+ implementation)
hwtacacs-server template TACTPL
hwtacacs-server authentication <tacacs-server-ip>
hwtacacs-server authorization <tacacs-server-ip>
hwtacacs-server accounting <tacacs-server-ip>
hwtacacs-server shared-key cipher YourStrongSharedSecret123

# IMPORTANT: source interface must be the one whose IP is allowed in server ACL / firewall
hwtacacs-server source-ip <switch-mgmt-ip>

quit

# Create AAA scheme and bind to the HWTACACS template
aaa
 authentication-scheme AUTH_TAC
  authentication-mode hwtacacs local
 authorization-scheme AUTHOR_TAC
  authorization-mode hwtacacs local
 accounting-scheme ACC_TAC
  accounting-mode hwtacacs

 # Domain binding — this is the step that's easy to miss
 domain default_admin
  authentication-scheme AUTH_TAC
  authorization-scheme AUTHOR_TAC
  accounting-scheme ACC_TAC
  hwtacacs-server TACTPL

quit

# Apply to VTY (user-interface) lines
user-interface vty 0 4
 authentication-mode aaa
 protocol inbound ssh

# Keep a local fallback user BEFORE testing
aaa
 local-user backupadmin password irreversible-cipher LocalBackupPass123
 local-user backupadmin privilege level 15
 local-user backupadmin service-type ssh
quit
```

**Verification commands (Huawei):**

```huawei
display hwtacacs-server template TACTPL
display aaa domain name default_admin
display current-configuration | include hwtacacs
```

---

## 4. End-to-End Testing

1. Keep your existing console/local session open.
2. Open a **new** SSH session to the switch.
3. Log in using a TACACS+-defined username/password.
4. On the server, confirm the hit in real time:
   ```bash
   sudo tail -f /var/log/tac_plus/access.log
   ```
5. Check `accounting.log` for the session start/stop and command records.
6. Test privilege level restriction by attempting a `configure terminal` (Cisco) or system-view (Huawei) with a read-only user — it should be denied.

---

## 5. Common Pitfalls & Troubleshooting Checklist

| Symptom | Likely Cause | Fix |
|---|---|---|
| `tac_plus` won't start / port 49 in use | Old process still bound to port | `sudo ss -tulnp \| grep 49` → kill stale PID |
| Switch can't reach server | Firewall/ACL blocking TCP/49 | Check `ufw status`, confirm source IP matches switch mgmt/source-interface |
| Authentication fails, "key mismatch" in logs | Shared secret differs between server and switch | Re-check `key`/`shared-key cipher` on both ends — must match exactly, no trailing spaces |
| Huawei: authentication silently falls back to local | AAA domain not linked to VTY / user not matching domain | Verify `domain default_admin` is applied and `authentication-mode aaa` is set on `user-interface vty` |
| User authenticates but gets no commands | Authorization scheme not bound to domain, or `cmd` rules missing in tac_plus.conf group | Recheck `authorization-scheme` binding and group `cmd =` rules |
| Locked out entirely | Fallback local account/session forgotten | Always keep console access + local backup user before enabling AAA |
| tac_plus config won't parse | Syntax error (missing brace, wrong indentation) | Run `tac_plus -C <path> -P` to validate before restart |

---

## 6. Security Hardening Recommendations

- Use a **long random shared key** (20+ chars), rotate periodically.
- Restrict TCP/49 via firewall to only switch/router management IPs.
- Use `des`/`irreversible-cipher` hashed passwords in configs, never cleartext in production.
- Enable accounting on all devices for audit trail.
- Consider running a **secondary TACACS+ server** for redundancy (`hwtacacs-server authentication <ip2>` / additional `tacacs server` block on Cisco) so a single server outage doesn't lock out admin access — fall back to `local` in the authentication scheme as a safety net either way.

---

## 7. Quick Reference — File/Command Summary

| Task | Command |
|---|---|
| Install | `sudo apt install tacacs+ -y` |
| Edit config | `sudo nano /etc/tacacs+/tac_plus.conf` |
| Validate config | `sudo tac_plus -C /etc/tacacs+/tac_plus.conf -P` |
| Restart service | `sudo systemctl restart tacacs_plus` |
| Check status | `sudo systemctl status tacacs_plus` |
| Live logs | `sudo tail -f /var/log/tac_plus/access.log` |
| Check port | `sudo ss -tulnp \| grep 49` |
