# TACACS+ Deployment Notes (tac_plus F4.0.4.28 on Ubuntu 22.04 + Huawei VRP)

Reconstructed from the server shell history and the switch/server logs shared during troubleshooting.
Secrets (shared key, passwords, hashes) are replaced with placeholders. Do not paste real values into this file.

## 1. Final setup at a glance

| Item | Value |
|---|---|
| TACACS+ server | Ubuntu 22.04.5, host `tacacs`, IP `192.168.102.34/28` (ens18) |
| Daemon | Shrubbery tac_plus **F4.0.4.28** (classic flat-file syntax), built from source |
| Binary | `/usr/local/sbin/tac_plus` |
| Config | `/etc/tacacs/tac_plus.conf` (backup: `tac_plus.conf.bak`) |
| systemd unit | `/etc/systemd/system/tacacs.service` (service name `tacacs`) |
| Accounting log | `/var/log/tacacs+/tac_plus.acct` (created on first accounting record) |
| Port | TCP 49 (UFW inactive) |
| Switch | Huawei S-series, VRP V200R008C00SPC500, `TEST-SW-RND-NAC` (banner says NMC-DR-SW03), mgmt IP `192.168.20.81` (Vlanif54) |
| Switch SSH port | 2313 |
| TACACS user | `ops01` (group `netops`) |
| Login form | `ops01@tacacs-domain` (domain is stripped before it is sent to the server) |

## 2. Install timeline (from history)

1. Network check: `ip -br a`, `ping` the gateway and the switch.
2. Dependencies: `apt install build-essential flex bison libwrap0-dev git`.
3. Source: `git clone https://github.com/facebook/tac_plus.git`, then `cd tacacs-F4.0.4.28`.
4. Build: `./configure --prefix=/usr/local && make && make install && ldconfig`, then `tac_plus -v`.
5. Directories: `mkdir -p /etc/tacacs /var/log/tacacs+`.
6. Password hash: `tac_pwd` (DES crypt, only the first 8 characters of the password count).
7. Config written to `/etc/tacacs/tac_plus.conf`, syntax-checked with `tac_plus -C ... -P`.
8. systemd unit created with `ExecStart=/usr/local/sbin/tac_plus -G -C /etc/tacacs/tac_plus.conf`, then `daemon-reload`, `enable`, `restart`.
9. Verified with `ss -tulnp | grep :49` and `systemctl status tacacs`.
10. Timezone set to `Asia/Dhaka` so log times match the switch.
11. Debug turned on (`-d 1023`) via `sed` on the unit file for troubleshooting.
12. OS admin accounts `faisal` and `sumon` created and added to `sudo`.
13. Final config edits (history 242-251, content not in the history) and restart. TACACS login now works.

## 3. Server configuration (template)

```conf
key = "<SHARED_KEY>"
accounting file = /var/log/tacacs+/tac_plus.acct

group = netops {
    default service = deny
    service = exec {
        priv-lvl = 7
    }
    cmd = show    { permit .* }
    cmd = display { permit .* }
    cmd = ping    { permit .* }
    cmd = interface { permit .* }
    cmd = ip      { permit .* }
    cmd = shutdown { permit .* }
    cmd = no      { permit .* }
    cmd = write   { permit .* }
    cmd = commit  { permit .* }
    cmd = quit    { permit .* }
    cmd = exit    { permit .* }
}

user = ops01 {
    name = "Network Operator"
    member = netops
    login = des <HASH_FROM_tac_pwd>
}
```

Notes:
- Classic syntax only: `key =`, `group = {}`, `user = {}`. The `id = spawnd` / `host = world` syntax from the guide you followed belongs to tac_plus-ng and does not work with F4.0.4.28.
- A global `key` is enough. The log line `no host named 192.168.20.81` is normal when there is no `host =` block.
- To change a password: run `tac_pwd`, paste the hash into `login = des ...`, then `systemctl restart tacacs`.
- Huawei needs `cmd = system-view { permit .* }` in the group if operators must enter system-view.

## 4. systemd unit

```ini
[Unit]
Description=TACACS+ Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tac_plus -G -C /etc/tacacs/tac_plus.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Normal operation uses no `-d` flag. `-d 1023` is for troubleshooting only (see section 8).

## 5. Huawei switch configuration (what the working setup needs)

```
hwtacacs-server template tacacs-server
 hwtacacs-server authentication 192.168.102.34
 hwtacacs-server authorization 192.168.102.34
 hwtacacs-server accounting 192.168.102.34
 hwtacacs-server source-ip 192.168.20.81
 hwtacacs-server shared-key cipher <SHARED_KEY>
 undo hwtacacs-server user-name domain-included
#
aaa
 authentication-scheme TACACS-AUTH
  authentication-mode hwtacacs local
 authorization-scheme TACACS-AUTHOR
  authorization-mode hwtacacs local
 accounting-scheme TACACS-ACC
  accounting-mode hwtacacs
 domain tacacs-domain
  authentication-scheme TACACS-AUTH
  authorization-scheme TACACS-AUTHOR
  accounting-scheme TACACS-ACC
  hwtacacs-server tacacs-server
#
user-interface vty 0 4
 authentication-mode aaa
 protocol inbound all
#
stelnet server enable
ssh server port 2313
ssh authentication-type default password
ssh user ops01
ssh user ops01 authentication-type password
ssh user ops01 service-type stelnet
ssh user ops01@tacacs-domain
ssh user ops01@tacacs-domain authentication-type password
ssh user ops01@tacacs-domain service-type stelnet
```

Login command from a workstation:

```bash
ssh -p 2313 \
  -o KexAlgorithms=+diffie-hellman-group14-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  ops01@tacacs-domain@192.168.20.81
```

## 6. Problems hit and what each one meant

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | No log file found | Wrong paths used (`/var/log/tac_plus.acct`, `/etc/tacacs+/`). Real paths are `/var/log/tacacs+/` and `/etc/tacacs/`. | Use the paths in section 1. Daemon messages go to `journalctl -u tacacs`. |
| 2 | Debug run exits instantly | Running `tac_plus` by hand while the service already holds port 49. Also `-d 128` was combined with `ls` flags by mistake. | `systemctl stop tacacs` before a manual debug run. |
| 3 | tcpdump showed 0 packets | Switch was not sending TACACS traffic: login used the `default_admin` domain, which has no TACACS scheme. | Log in as `user@tacacs-domain` so the `tacacs-domain` AAA domain is used. |
| 4 | Server log: `no user/group named ops01@tacacs-domain` | Switch sent the domain with the username. | `undo hwtacacs-server user-name domain-included` in the template. |
| 5 | Server log: `Null reply packet, expecting CONTINUE` | Server sent the `Password:` prompt, switch never returned the password. | See cause 6. |
| 6 | Server sends `Password:` then waits forever; switch log `SSH_FAIL ... User password authentication failed` | The switch SSH layer rejected the user before TACACS could check the password. There was no `ssh user ops01...` entry, and later the `ops01@tacacs-domain` entry had no `authentication-type` or `service-type`. | Add the full set of `ssh user` lines for both `ops01` and `ops01@tacacs-domain`, then `save`. |
| 7 | Login with `sumon@tacacs-domain` failed | `sumon` is a local switch account, not in `tac_plus.conf`. | Use local accounts without the domain. |
| 8 | Hash seemed wrong | `tac_pwd` was run a second time with the hash as input, which produced a new, unrelated hash. | Run `tac_pwd` once with the plain password. |
| 9 | Login worked days earlier, then failed | Not fully diagnosed from the logs. The server side was healthy throughout (user found, `Password:` sent). The last changes visible are on the switch SSH user entries. | Check `display current-configuration \| include ssh user` and `display logbuffer \| include SSH_FAIL` first when this recurs. |

Key diagnostic rule: if the server log shows `Read AUTHEN/CONT` a second time after `Password:`, the password reached the server and the result follows. If it does not, the switch (SSH or AAA layer) is the problem, not the password.

## 7. Quick troubleshooting checklist

Server:
```bash
systemctl status tacacs
ss -tlnp | grep :49
journalctl -u tacacs -f
tcpdump -ni any port 49
tac_plus -C /etc/tacacs/tac_plus.conf -P      # syntax check
```

Switch:
```
display hwtacacs-server template tacacs-server
display current-configuration configuration aaa
display current-configuration | include ssh
display logbuffer | include SSH_FAIL
ping 192.168.102.34
```

Isolating the layer:
- Telnet bypasses the `ssh user` entries, so a telnet login to `192.168.20.81` with `ops01@tacacs-domain` tests TACACS alone.
- `tacacs_client -u ops01 -k '<key>' -H 192.168.102.34 authenticate` (from `pip install tacacs_plus`) tests the server without the switch.

## 8. Security cleanup still to do

1. **Remove `-d 1023` from the service.** The debug log prints the shared key in clear text on every packet (`PACKET: key=...`). Edit `/etc/systemd/system/tacacs.service`, then `systemctl daemon-reload && systemctl restart tacacs`. Also run `undo debugging all` on the switch.
2. **Rotate the shared key** on both server and switch. The old key was shown in logs and in this troubleshooting. Use letters and digits only to avoid `$` and `!` problems.
3. **Change the `ops01` password** and regenerate the hash with `tac_pwd`. The plain password was typed in shell history and shared in chat.
4. **Clear shell history** after secrets were typed: `history -c`. Remove the `login = des ...` and `perl/python crypt(...)` lines that contain the password from `~/.bash_history`.
5. **Restrict port 49** to the switch management addresses. UFW is currently inactive.
6. **Authorization fallback:** `authorization-cmd 3 hwtacacs` has no `local` fallback. Use `authorization-cmd 3 hwtacacs local` so a server outage cannot lock out command access.
7. **Keep a local fallback account** on the switch (`sumon`, `faisal`, `level3` exist) and keep console access when changing AAA.
8. **Stale file:** `/etc/systemd/system/tac_plus.service` was read in history and may be a leftover from an earlier attempt. Confirm it is unused (`systemctl cat tac_plus`) and remove it if so, to avoid two units fighting over port 49.
9. **`ops01` privilege is `priv-lvl = 7` with `default service = deny`.** Add only the commands operators really need.
10. **Back up** `/etc/tacacs/tac_plus.conf` and the switch config (`save`) once everything is stable.

## 9. Gaps in this document

- The final contents of `/etc/tacacs/tac_plus.conf` after the last edits (history 242-251) were not in the history, so section 3 reflects the earlier verified config.
- The exact change that restored login after the failure on 25-26 Oct was not captured. The logs point at the switch SSH user entries, but this is an inference.
