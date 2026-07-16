# TACACS+ Full Configuration Reference — Server (Ubuntu) + Switch (Huawei VRP)

This is the complete, corrected configuration based on your working setup, including the fixes applied during troubleshooting.

---

# PART A — SERVER SIDE (Ubuntu, tac_plus F4.0.4.28)

## A1. Service file

Location: `/etc/systemd/system/tacacs.service`

```ini
[Unit]
Description=TACACS+ Server
After=network.target

[Service]
ExecStart=/usr/local/sbin/tac_plus -C /etc/tacacs/tac_plus.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## A2. Config file

Location: `/etc/tacacs/tac_plus.conf`

```conf
# --- Global Settings ---
key = "T@cacs$ecretKey2024!"
accounting file = /var/log/tacacs+/tac_plus.acct
logging = local6

# --- TACACS Clients (allow all — restrict to specific IPs in production) ---
host = 0.0.0.0/0 {
    key = "T@cacs$ecretKey2024!"
}

# -----------------------------------------
# USER GROUPS
# -----------------------------------------
group = netadmin {
    default service = permit
    service = exec {
        priv-lvl = 15
    }
}

group = readonly {
    default service = deny
    service = exec {
        priv-lvl = 1
    }
    cmd = show { permit .* }
    cmd = display { permit .* }
    cmd = ping { permit .* }
    cmd = quit { permit .* }
    cmd = exit { permit .* }
}

group = netops {
    default service = deny
    service = exec {
        priv-lvl = 7
    }
    cmd = show { permit .* }
    cmd = display { permit .* }
    cmd = ping { permit .* }
    cmd = interface { permit .* }
    cmd = ip { permit .* }
    cmd = shutdown { permit .* }
    cmd = no { permit .* }
    cmd = write { permit .* }
    cmd = commit { permit .* }
    cmd = quit { permit .* }
    cmd = exit { permit .* }
}

# -----------------------------------------
# LOCAL USERS
# -----------------------------------------
user = admin01 {
    name = "Network Administrator"
    member = netadmin
    login = cleartext Admin@1234
}

user = ops01 {
    name = "Network Operator"
    member = netops
    login = des aB3xK9mN2pLqR7sT
}

user = monitor01 {
    name = "Read-Only Monitor"
    member = readonly
    login = des zP2mK8nQ4rLxV6wY
}
```

**Note on the fix applied:** the original config had `default authentication = file /etc/passwd` incorrectly placed inside the `host { }` block — this is a global directive and was removed since local users are already defined directly in this file.

## A3. Install / Validate / Start — Step by Step

```bash
# 1. Confirm binary and version
tac_plus -v

# 2. Backup existing config before edits
sudo cp /etc/tacacs/tac_plus.conf /etc/tacacs/tac_plus.conf.bak

# 3. Validate syntax before starting
/usr/local/sbin/tac_plus -C /etc/tacacs/tac_plus.conf -P

# 4. Check nothing else holds port 49
sudo ss -tulnp | grep :49

# 5. Enable + start service
sudo systemctl enable tacacs
sudo systemctl restart tacacs
sudo systemctl status tacacs

# 6. Confirm listening
sudo ss -tulnp | grep tac_plus

# 7. Allow firewall access from switch management subnet
sudo ufw allow from 192.168.20.0/24 to any port 49 proto tcp
sudo ufw reload

# 8. Watch logs live while testing from switch
sudo journalctl -u tacacs -f
```

---

# PART B — SWITCH SIDE (Huawei VRP, e.g. S5320 / NMC-DR-SW03)

## B1. Enter configuration mode

```
system-view
```

## B2. Configure TACACS+ server template

```
hwtacacs-server template tacacs-server
 hwtacacs-server authentication 192.168.45.6
 hwtacacs-server authorization 192.168.45.6
 hwtacacs-server accounting 192.168.45.6
 hwtacacs-server source-ip 192.168.20.81
 hwtacacs-server shared-key cipher T@cacs$ecretKey2024!
quit
```

> `source-ip` must be the interface IP the switch actually uses to reach the server — mismatches here cause silent failures.

## B3. Configure AAA schemes

```
aaa
 authentication-scheme TACACS-AUTH
  authentication-mode hwtacacs local
 authorization-scheme TACACS-AUTHOR
  authorization-mode hwtacacs local
 accounting-scheme TACACS-ACC
  accounting-mode hwtacacs
```

> `hwtacacs local` keeps local fallback active if the TACACS+ server becomes unreachable — this is what saved your access when TACACS+ login failed. Keep this fallback enabled.

## B4. Bind schemes to domains

Huawei VRP treats **admin logins** (SSH/Telnet/console) differently from regular user logins — admin-type sessions route through `default_admin`, not `default` or a custom domain, unless overridden. Bind TACACS+ to *both* the domain you intend to use for admin logins and any other domain you use:

```
 domain default_admin
  authentication-scheme TACACS-AUTH
  authorization-scheme TACACS-AUTHOR
  accounting-scheme TACACS-ACC

 domain tacacs-domain
  authentication-scheme TACACS-AUTH
  authorization-scheme TACACS-AUTHOR
  accounting-scheme TACACS-ACC
  hwtacacs-server tacacs-server
quit
```

## B5. Apply to VTY lines (commonly missed step)

```
user-interface vty 0 4
 authentication-mode aaa
quit
```

> **This is the step to double-check if login still fails after everything else looks correct.** Confirm the VTY range you're actually connecting through matches the one configured here — some switches split ranges (e.g. `vty 0 4` vs `vty 16 20`) for different session types, and only the configured range will use AAA.

## B6. Save configuration

```
save
y
```

## B7. Verification commands (run on switch)

```
display current-configuration configuration aaa
display current-configuration configuration vty
display current-configuration configuration ssh
display hwtacacs-server statistics template tacacs-server
```

---

# PART C — END-TO-END TEST PROCEDURE

1. **Keep an existing working session open** (console or already-authenticated session) before testing — never test AAA changes without a fallback session.
2. On server: `sudo journalctl -u tacacs -f`
3. On switch: `ping <tacacs_server_ip>` then `telnet <tacacs_server_ip> 49` (expect "connected" then immediate close — this is normal, it just proves port reachability).
4. Open a **new** session and log in with a TACACS+-defined user (e.g. `admin01` / `Admin@1234`).
5. Confirm on server: log lines appear showing the auth request/response.
6. Confirm on switch: login succeeds and lands at the expected privilege level (test with `system-view` if priv-lvl 15).
7. Run `display hwtacacs-server statistics template tacacs-server` — request/response counters should increment.

---

# PART D — TROUBLESHOOTING MAP (issues hit so far)

| Symptom | Cause | Fix |
|---|---|---|
| `tac_plus` fails to start, exit-code 1 | `default authentication = file /etc/passwd` incorrectly placed inside `host {}` block | Remove the line — global directive, not per-host |
| `Illegal major version specified: found 255 wanted 192` in logs | Telnet test sending non-TACACS+ bytes | Expected/harmless — confirms port reachability only |
| Repeated "Access denied" for `admin01`, no server log entry appears | Login routed through `default_admin` domain which had no scheme bound (falls back to local, user doesn't exist locally) | Bind `authentication-scheme` / `authorization-scheme` / `accounting-scheme` to `default_admin` |
| Still "Access denied" after domain fix, still no server-side log entry | VTY line not applying `authentication-mode aaa`, or wrong VTY range in use | Check `display current-configuration configuration vty`; confirm correct range has `authentication-mode aaa` |
| Locked out of SSH entirely | All AAA attempts failing before reaching local fallback, or typo in password | Use existing console/local session; log in as a known local user (`sumon`, `faisal`, `level3`) with local (non-TACACS+) password |

---

*This reflects the actual working state reached during setup on NMC-DR-SW03 / tacacs server 192.168.45.6. Update IPs, keys, and domain names if reused on another device.*
