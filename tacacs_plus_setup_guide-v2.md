# TACACS+ Full Configuration: Linux Server + Huawei + Cisco

Server: Ubuntu 22.04, Shrubbery `tac_plus` (classic flat-file syntax).
Clients: Huawei VRP switch and Cisco Catalyst 2960-Plus (IOS).

Secrets are placeholders. Replace every `<...>` before use and never paste real keys or passwords into notes or chats.

## 0. Values to fill in

| Placeholder | Meaning | Known value |
|---|---|---|
| `<TACACS_SERVER_IP>` | Linux TACACS+ server | `192.168.102.34` |
| `<SHARED_KEY>` | Shared secret, identical on server and every switch | choose a new one (see section 10) |
| `<HUAWEI_MGMT_IP>` | Huawei switch management IP (Vlanif54) | `192.168.20.81` |
| `<CISCO_MGMT_IP>` | Cisco switch management IP | not provided |
| `<CISCO_SOURCE_INTERFACE>` | Cisco interface whose IP the server expects (e.g. `Vlan1`) | not provided |
| `<OPS01_HASH>` | DES hash from `tac_pwd` for `ops01` | generate in section 4 |
| `<CISCOADMIN_HASH>` | DES hash from `tac_pwd` for `ciscoadmin` | generate in section 4 |
| `<LOCAL_RECOVERY_PASSWORD>` | Cisco local `breakglass` password | choose a new one |

## 1. Architecture and accounts

```
[Admin PC] --SSH--> [Huawei / Cisco switch] --TCP 49--> [TACACS+ server 192.168.102.34]
```

| Account | Where it lives | Used for | Privilege |
|---|---|---|---|
| `ops01` | TACACS server, group `netops` | Huawei login as `ops01@tacacs-domain` | `priv-lvl = 7` |
| `ciscoadmin` | TACACS server, group `cisco-admin` | Cisco login (plain `ciscoadmin`) | `priv-lvl = 15` |
| `sumon`, `faisal`, `level3` | Huawei local users | Huawei fallback | 15 |
| `breakglass` | Cisco local user | Cisco fallback | 15 |

Note on versions: the logs and shell history shared so far came from a server running F4.0.4.28. The install steps below use the F4.0.4.32 tarball. I have not compared the two releases, so run the syntax check in section 4 and test one login before relying on the new binary.

## 2. Server install (Shrubbery tarball, no GitHub)

Source: https://shrubbery.net/pub/tac_plus/tacacs-F4.0.4.32.tar.gz

### 2.1 Dependencies

```bash
apt update
apt install -y build-essential flex bison libwrap0-dev wget
```

### 2.2 Download, build, install

```bash
cd /home/tacacs
wget https://shrubbery.net/pub/tac_plus/tacacs-F4.0.4.32.tar.gz
tar -xvzf tacacs-F4.0.4.32.tar.gz
cd tacacs-F4.0.4.32
./configure --prefix=/usr/local
make
make install
ldconfig
tac_plus -v
```

If the tarball was downloaded on another machine, copy it first:
`scp tacacs-F4.0.4.32.tar.gz <user>@192.168.102.34:/home/tacacs/`

The folder name has no `+` in it. The binary installs to `/usr/local/sbin/tac_plus` and `tac_pwd` to `/usr/local/bin`.

### 2.3 If upgrading an existing server

```bash
systemctl stop tacacs
cp -a /usr/local/sbin/tac_plus /usr/local/sbin/tac_plus.old
cp -a /etc/tacacs/tac_plus.conf /etc/tacacs/tac_plus.conf.pre-upgrade
# build and install as in 2.2, then:
tac_plus -C /etc/tacacs/tac_plus.conf -P
systemctl start tacacs
```

Rollback: stop the service, copy `tac_plus.old` back over `/usr/local/sbin/tac_plus`, start the service. While the service is stopped, both switches fall back to local users, so keep a console session open.

### 2.4 Directories and systemd unit

```bash
mkdir -p /etc/tacacs /var/log/tacacs+
```

`/etc/systemd/system/tacacs.service`:

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

```bash
systemctl daemon-reload
systemctl enable tacacs
```

Do not add `-d 1023` for normal operation. Debug level 1023 prints the shared key into the log on every packet.

## 3. Time zone (so logs match the switches)

```bash
timedatectl set-timezone Asia/Dhaka
```

## 4. Server configuration `/etc/tacacs/tac_plus.conf`

### 4.1 Generate password hashes

```bash
tac_pwd      # run once per user, type the plain password once, copy the hash it prints
```

Do not feed a hash back into `tac_pwd`; that produces a different, useless hash. DES crypt only reads the first 8 characters of a password, so use passwords that differ within the first 8 characters.

### 4.2 Config file

```conf
# ---- Global ----
key = "<SHARED_KEY>"
accounting file = /var/log/tacacs+/tac_plus.acct

# ---- Huawei operators ----
group = netops {
    default service = deny
    service = exec {
        priv-lvl = 7
    }
    cmd = show        { permit .* }
    cmd = display     { permit .* }
    cmd = ping        { permit .* }
    cmd = interface   { permit .* }
    cmd = ip          { permit .* }
    cmd = shutdown    { permit .* }
    cmd = no          { permit .* }
    cmd = write       { permit .* }
    cmd = commit      { permit .* }
    cmd = quit        { permit .* }
    cmd = exit        { permit .* }
    cmd = system-view { permit .* }
}

# ---- Cisco admins (no command authorization yet) ----
group = cisco-admin {
    default service = permit
    service = exec {
        priv-lvl = 15
    }
}

# ---- Users ----
user = ops01 {
    name = "Network Operator"
    member = netops
    login = des <OPS01_HASH>
}

user = ciscoadmin {
    name = "Cisco Administrator"
    member = cisco-admin
    login = des <CISCOADMIN_HASH>
}
```

Notes:
- Classic syntax only. The `id = spawnd` and `host = world` style belongs to tac_plus-ng and will not parse here.
- A single global `key` covers every switch. The log line `no host named <switch-ip>` is normal when there are no `host =` blocks.
- `cmd = system-view` was added to `netops` because Huawei operators need it to enter configuration mode. Remove it if `ops01` should be read-only.
- `priv-lvl = 7` for `ops01` is what the server grants. If Huawei command authorization is off, the switch may still apply the VTY privilege set locally (`user privilege level 15`). Test what `ops01` can actually do after login.
- Optional per-switch keys: add `host = <ip> { key = "<KEY>" }` blocks above the groups. Validate with `-P` before restarting, since I have not tested `host` blocks against your build.

### 4.3 Validate and start

```bash
tac_plus -C /etc/tacacs/tac_plus.conf -P      # prints the parsed config, errors show here
systemctl restart tacacs
systemctl status tacacs
ss -tlnp | grep :49
```

Expected: `active (running)` and `tac_plus` listening on `0.0.0.0:49` and `[::]:49`.

## 5. Server firewall

UFW is inactive today. If you enable it, allow SSH first or you will lock yourself out of the server.

```bash
ufw allow OpenSSH
ufw allow from 192.168.20.81 to any port 49 proto tcp      # Huawei
ufw allow from <CISCO_MGMT_IP> to any port 49 proto tcp    # Cisco
ufw enable
ufw status
```

Use the IP each switch uses as its TACACS source (see the source-ip and source-interface settings below).

## 6. Huawei switch (VRP V200R008C00SPC500)

Log in with a local account first (console or `ssh -p 2313 sumon@192.168.20.81`) and keep that session open.

### 6.1 HWTACACS template

```
system-view
hwtacacs-server template tacacs-server
 hwtacacs-server authentication 192.168.102.34
 hwtacacs-server authorization 192.168.102.34
 hwtacacs-server accounting 192.168.102.34
 hwtacacs-server source-ip 192.168.20.81
 hwtacacs-server shared-key cipher <SHARED_KEY>
 undo hwtacacs-server user-name domain-included
 quit
```

`undo hwtacacs-server user-name domain-included` is required. Without it the switch sends `ops01@tacacs-domain` and the server answers `no user/group named ops01@tacacs-domain`.

### 6.2 AAA schemes and domain

```
aaa
 authentication-scheme TACACS-AUTH
  authentication-mode hwtacacs local
  quit
 authorization-scheme TACACS-AUTHOR
  authorization-mode hwtacacs local
  quit
 accounting-scheme TACACS-ACC
  accounting-mode hwtacacs
  quit
 domain tacacs-domain
  authentication-scheme TACACS-AUTH
  authorization-scheme TACACS-AUTHOR
  accounting-scheme TACACS-ACC
  hwtacacs-server tacacs-server
  quit
 quit
```

`hwtacacs local` means the switch falls back to local users only when the server is unreachable. If the server answers and rejects the login, there is no fallback.

### 6.3 Remote access and SSH users

The SSH layer rejects any user that has no `ssh user` entry, before the password ever reaches TACACS. This was the root cause of the long login failure. Both names are needed because the login name carries the domain.

```
stelnet server enable
ssh server port 2313
ssh authentication-type default password
ssh user ops01
ssh user ops01 authentication-type password
ssh user ops01 service-type stelnet
ssh user ops01@tacacs-domain
ssh user ops01@tacacs-domain authentication-type password
ssh user ops01@tacacs-domain service-type stelnet
user-interface vty 0 4
 authentication-mode aaa
 protocol inbound all
 quit
```

Optionally restrict VTY to SSH: `protocol inbound ssh`. Do this only after SSH login works, and keep console access.

### 6.4 Save and verify

```
return
save
display hwtacacs-server template tacacs-server
display current-configuration configuration aaa
display current-configuration | include ssh
display logbuffer | include SSH_FAIL
```

`display hwtacacs-server template` should show `Domain-included : No` and the server IP `192.168.102.34:49`.

### 6.5 Login from a workstation

```bash
ssh -p 2313 \
  -o KexAlgorithms=+diffie-hellman-group14-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  ops01@tacacs-domain@192.168.20.81
```

### 6.6 Command authorization (optional, later)

`authorization-cmd 3 hwtacacs` with no `local` has no fallback. If the server is down or a command is not permitted, commands stop working. Use the fallback form and only after the server `netops` group lists every command operators need:

```
aaa
 authorization-scheme TACACS-AUTHOR
  authorization-cmd 3 hwtacacs local
```

## 7. Cisco Catalyst 2960-Plus (IOS)

Keep a console or existing admin session open for the whole procedure.

### 7.1 Check the current state

```
enable
show version
show ip interface brief
show running-config | section aaa
show running-config | section tacacs
show running-config | section line vty
```

IOS 15.2(7)E3 or later uses the `tacacs server` block shown below. Older releases need the legacy `tacacs-server host` form (7.3). Do not use both.

### 7.2 SSH prerequisites (skip what already exists)

```
configure terminal
hostname <CISCO_HOSTNAME>
ip domain-name <YOUR_DOMAIN>
crypto key generate rsa modulus 2048
ip ssh version 2
end
```

### 7.3 TACACS+ and AAA

```
configure terminal

! Local recovery account (different password from ciscoadmin)
username breakglass privilege 15 secret <LOCAL_RECOVERY_PASSWORD>

aaa new-model

! TACACS+ server (IOS 15.2(7)E3 and later)
tacacs server TACACS-SERVER
 address ipv4 192.168.102.34
 key <SHARED_KEY>
 timeout 5
 exit

! Legacy IOS instead of the block above:
! tacacs-server host 192.168.102.34 timeout 5 key <SHARED_KEY>

! Send TACACS+ packets from the management interface
ip tacacs source-interface <CISCO_SOURCE_INTERFACE>

aaa authentication login VTY-TACACS group tacacs+ local
aaa authentication login CONSOLE local
aaa authorization exec default group tacacs+ local

line console 0
 login authentication CONSOLE
 exit

line vty 0 15
 login authentication VTY-TACACS
 transport input ssh
 exit

end
```

The server must see the same source IP the firewall allows. If `ip tacacs source-interface` is not set, the switch uses the egress interface IP, which may not be what you allowed.

### 7.4 Test before saving

Open a new SSH session (keep the old one):

```bash
ssh ciscoadmin@<CISCO_MGMT_IP>
```

Then on the switch:

```
show privilege
show running-config | section aaa
show running-config | section tacacs
```

Expected: `Current privilege level is 15`. On the TACACS server, watch the attempt:

```bash
journalctl -u tacacs -f
tcpdump -ni any host <CISCO_MGMT_IP> and tcp port 49
```

### 7.5 Accounting and save

Once login and privilege are correct:

```
configure terminal
aaa accounting exec default start-stop group tacacs+
end
copy running-config startup-config
```

### 7.6 Command authorization

Do not enable `aaa authorization commands 15 ...` yet. `cisco-admin` has no per-command policy, and enabling it without one can block admin commands. When you want it, first add explicit `cmd = ... { permit .* }` lines to the server group, test with a spare session, then enable it with a local fallback.

## 8. Test matrix

| Test | Expected |
|---|---|
| `ss -tlnp \| grep :49` on server | `tac_plus` on `0.0.0.0:49` |
| `ping 192.168.102.34` from each switch | replies |
| Huawei SSH `ops01@tacacs-domain` | login, server log shows `AUTHEN/START` then `AUTHEN/CONT` twice |
| Cisco SSH `ciscoadmin` | login, `show privilege` returns 15 |
| Server stopped, then login with local user | local fallback works |
| Wrong password | login refused, server log shows the reject |
| Accounting | `/var/log/tacacs+/tac_plus.acct` appears and grows |

Reading the server log: after `Writing AUTHEN/GETPASS` (`Password:`), a second `Read AUTHEN/CONT` means the password reached the server. If it never arrives, the switch (SSH layer or AAA) is the problem, not the password.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| tcpdump shows 0 packets on port 49 | Switch not sending TACACS traffic: wrong domain (Huawei `default_admin`), no route, ACL, or wrong source IP | Log in as `user@tacacs-domain`; check `ping` and the source-ip or source-interface |
| `no user/group named ops01@tacacs-domain` | Domain sent to server | `undo hwtacacs-server user-name domain-included` |
| Server sends `Password:` then waits, Huawei logs `SSH_FAIL ... User password authentication failed` | Missing or incomplete `ssh user` entries | Add all three `ssh user` lines for both `ops01` and `ops01@tacacs-domain` |
| `Null reply packet, expecting CONTINUE` | Switch never returned the password (same cause as above) | Same fix |
| Cisco login falls to local only | Server unreachable from the Cisco source IP, or wrong key | Check source interface, firewall, and that the key matches exactly |
| Key mismatch (garbled or rejected packets) | Different key on server and switch, or special characters | Use letters and digits only and re-enter on both ends |
| `ssh ... no matching key exchange` on old Huawei | Old SSH algorithms | Add `-o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa` |
| Locked out | AAA changed without a fallback | Console login with a local account; always keep one session open and a local user |

Quick commands:

```bash
# server
systemctl status tacacs
journalctl -u tacacs -f
tcpdump -ni any port 49
tac_plus -C /etc/tacacs/tac_plus.conf -P
```

```
# Huawei
display hwtacacs-server template tacacs-server
display logbuffer | include SSH_FAIL
terminal monitor
terminal debugging
debugging hwtacacs all
undo debugging all
```

To test the server alone, without a switch: `pip install tacacs_plus`, then `tacacs_client -u ops01 -k '<SHARED_KEY>' -H 192.168.102.34 authenticate`.

## 10. Security checklist

1. Rotate the shared key on the server and on both switches. The old key and the `ops01` password were shown in logs and chats. Use letters and digits only (no `$`, `!`, `?`), 20 or more characters.
2. Run the service without `-d`. Confirm with `systemctl cat tacacs`, then `systemctl daemon-reload && systemctl restart tacacs`.
3. Change the `ops01` password and generate a fresh hash with `tac_pwd`. Give `ciscoadmin` and `breakglass` different passwords.
4. Clear shell history that contains secrets (`history -c`, then edit `~/.bash_history`).
5. Restrict TCP 49 to the switch management IPs (section 5).
6. Keep local fallback accounts and console access on both switches.
7. Use `authorization-cmd 3 hwtacacs local` on Huawei, not the no-fallback form.
8. Check for a leftover `/etc/systemd/system/tac_plus.service`; if it is unused, remove it so two units cannot compete for port 49.
9. Rotate `/var/log/tacacs+/tac_plus.acct` with logrotate once it grows.
10. Save both switch configs (`save` on Huawei, `copy running-config startup-config` on Cisco) and back up `/etc/tacacs/tac_plus.conf`.

## 11. What I could not confirm

- The live contents of `/etc/tacacs/tac_plus.conf` (including whether `cisco-admin` and `ciscoadmin` already exist). Compare with `cat /etc/tacacs/tac_plus.conf` and keep your working entries.
- The Cisco IOS version, management IP, and source interface. Section 7 uses placeholders for them.
- Whether F4.0.4.32 behaves identically to F4.0.4.28 with your config.
