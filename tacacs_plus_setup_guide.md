# TACACS+ Implementation Guide (Ubuntu Server + Network Devices)

This guide walks through installing and configuring `tac_plus` (TACACS+ daemon) on an Ubuntu server, and integrating it with network devices (e.g., Huawei switches) for centralized AAA (Authentication, Authorization, Accounting).

---

## 1. Prerequisites

- Ubuntu Server (18.04/20.04/22.04)
- Root or sudo access
- A static IP for the TACACS+ server
- Network devices (switches/routers) that support TACACS+ client configuration
- Port **49/TCP** open between devices and the server (default TACACS+ port)

---

## 2. Install TACACS+ Daemon

```bash
sudo apt update
sudo apt install tacacs+ -y
```

Check installed version:

```bash
tac_plus -v
```

> Note: The Ubuntu repo package is often older (`tac_plus F4.0.4.x`). If you need a newer build, compile from source (shrubbery/tac_plus-ng), but the repo version is sufficient for most setups.

---

## 3. Check for Port Conflicts (Port 49)

Before configuring, confirm nothing else is bound to port 49:

```bash
sudo ss -tulnp | grep :49
```

If another service (or a leftover `tac_plus` process) is already bound:

```bash
sudo systemctl stop tacacs_plus
sudo pkill tac_plus
```

Then restart cleanly after configuration is done.

---

## 4. Configure `/etc/tacacs+/tac_plus.conf`

Backup the default config first:

```bash
sudo cp /etc/tacacs+/tac_plus.conf /etc/tacacs+/tac_plus.conf.bak
```

Example working configuration:

```conf
# Shared secret key - must match on network device
key = "YourSharedSecretKey"

# Accounting log file
accounting file = /var/log/tac_plus.acct

# User group definition
group = admins {
    default service = permit
    service = exec {
        priv-lvl = 15
    }
    cmd = show {
        permit .*
    }
    cmd = configure {
        permit .*
    }
}

# User definition
user = sumon {
    member = admins
    login = des Y0urHashedOrPlainPassword
}
```

**Important syntax notes (common mistakes):**
- Every `{ }` block must be properly closed — mismatched braces are the #1 cause of `tac_plus` refusing to start.
- `key` must be identical (case-sensitive) on both server and network device.
- Use `login = cleartext "password"` for testing, switch to `des` or `PAM` for production.

Validate config syntax before starting:

```bash
sudo tac_plus -C /etc/tacacs+/tac_plus.conf -P
```

---

## 5. Start and Enable the Service

```bash
sudo systemctl enable tacacs_plus
sudo systemctl restart tacacs_plus
sudo systemctl status tacacs_plus
```

Confirm it's listening on port 49:

```bash
sudo ss -tulnp | grep tac_plus
```

---

## 6. Allow Port 49 Through Firewall

```bash
sudo ufw allow from <switch_ip> to any port 49 proto tcp
sudo ufw reload
```

If using `iptables` directly:

```bash
sudo iptables -A INPUT -p tcp -s <switch_ip> --dport 49 -j ACCEPT
```

---

## 7. Configure the Network Device (Example: Huawei S5320)

```text
# Enable TACACS+ template
hwtacacs-server template TAC_TEMPLATE
hwtacacs-server authentication <tacacs_server_ip>
hwtacacs-server authorization <tacacs_server_ip>
hwtacacs-server accounting <tacacs_server_ip>
hwtacacs-server shared-key cipher YourSharedSecretKey

# Source IP - MUST match the interface that can reach the TACACS+ server
hwtacacs-server source-ip <switch_management_ip>

# AAA domain binding
aaa
 authentication-scheme tacacs_auth
  authentication-mode hwtacacs
 authorization-scheme tacacs_author
  authorization-mode hwtacacs
 accounting-scheme tacacs_acct
  accounting-mode hwtacacs
 domain default
  authentication-scheme tacacs_auth
  authorization-scheme tacacs_author
  accounting-scheme tacacs_acct
  hwtacacs-server TAC_TEMPLATE

# Apply to VTY lines (this step is commonly missed)
user-interface vty 0 4
 authentication-mode aaa
```

**Common pitfalls to check:**
- `hwtacacs-server source-ip` must be the IP the switch actually uses to reach the server (wrong source IP is a frequent cause of silent auth failures).
- The **domain must be explicitly linked** to the AAA schemes — if the switch uses a non-default domain (e.g. via `local-user domain` or login binding), the default domain config alone won't apply.
- VTY lines must reference `authentication-mode aaa`, not `authentication-mode password` or `aaa local`.
- Routing: confirm the switch has a valid route to the TACACS+ server (`ping -a <source_ip> <tacacs_server_ip>`).

---

## 8. Test Authentication

On the Ubuntu server, watch logs live while testing login from the switch:

```bash
sudo tail -f /var/log/tac_plus.acct
sudo journalctl -u tacacs_plus -f
```

For deeper debugging, run `tac_plus` in the foreground with debug flags (stop the service first):

```bash
sudo systemctl stop tacacs_plus
sudo tac_plus -C /etc/tacacs+/tac_plus.conf -d 16 -G
```

Debug flags reference:
- `1` = packet debug
- `2` = hex dump
- `16` = authentication debug
- `32` = authorization debug
- `64` = accounting debug
- `-G` = full debug

Then attempt login from the switch console/SSH and watch the output.

---

## 9. Fallback / Local Authentication (Recommended Safety Net)

Always keep local authentication as a fallback in case the TACACS+ server is unreachable:

```text
aaa
 authentication-scheme tacacs_auth
  authentication-mode hwtacacs local
```

This prevents total lockout if the server goes down.

---

## 10. Ongoing Maintenance Checklist

- [ ] Rotate/monitor `/var/log/tac_plus.acct` (add to logrotate)
- [ ] Keep shared keys in a password manager, not plaintext notes
- [ ] Document which devices point to which TACACS+ server/template
- [ ] Test failover to local auth periodically
- [ ] Review `group`/`cmd` authorization rules when adding new admins

---

## Quick Troubleshooting Table

| Symptom | Likely Cause |
|---|---|
| `tac_plus` won't start | Config brace mismatch or syntax error |
| "Address already in use" on port 49 | Old `tac_plus` process still running, or another service bound to 49 |
| Switch times out reaching server | Firewall rule missing, or wrong `source-ip` on switch |
| Auth fails with correct password | Shared key mismatch (case-sensitive) |
| Auth works but no privilege/command access | `service = exec` / `priv-lvl` or `cmd` block missing/misconfigured |
| Works on console but not VTY | VTY lines not set to `authentication-mode aaa` |
| Auth works only sometimes | Domain not linked to AAA scheme, falls back to local |

---

*Generated as a reference guide — adjust IPs, keys, and usernames to match your environment before deploying.*
