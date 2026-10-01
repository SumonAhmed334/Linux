# ESXi 8: Making the Hosts File, SSH and ESXi Shell Persist Across Reboots

**Environment:** Nested vSphere + Ceph NVMe-oF Lab (Dell R450, ESXi 8)
**Affected hosts:** lab-esxi01, lab-esxi02, lab-esxi03 (the same fix applies to the physical R450)

---

## 1. Problem

After deploying a new ESXi host and rebooting, two things were lost:

1. **SSH** was disabled automatically.
2. **ESXi Shell** (local console shell) was not enabled after reboot.
3. **Manual entries in `/etc/hosts`** disappeared.

---

## 2. Root Cause

### SSH and ESXi Shell
- By default the SSH and ESXi Shell services on ESXi are set to "start manually", so they stay stopped after a reboot.
- SSH and ESXi Shell are two separate services. SSH is for remote login over the network. ESXi Shell is for the local console (DCUI, Alt+F1).
- If `ESXiShellTimeOut` / `ESXiShellInteractiveTimeOut` are non-zero, SSH and the shell are also disabled automatically after a timeout.

### Hosts file
- On ESXi 8, `/etc/hosts` starts with the header: *"Do not modify this file directly, please use esxcli."*
- The file is **regenerated from ConfigStore at every boot**. Editing it with `vi` only changes the temporary in-memory file, so the edit is lost on reboot.
- Running `/sbin/auto-backup.sh` does not help here, because manual hosts entries are not stored in ConfigStore.

---

## 3. What Was Done and Why

### Step A: Make SSH and ESXi Shell persistent

```bash
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell
esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i 0
esxcli system settings advanced set -o /UserVars/ESXiShellInteractiveTimeOut -i 0
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1
/sbin/auto-backup.sh
```

| Command | Purpose |
|---|---|
| `enable_ssh` | Sets the SSH service policy to "Start and stop with host", so it starts automatically after reboot |
| `start_ssh` | Starts SSH immediately |
| `enable_esx_shell` | Sets the ESXi Shell service policy to "Start and stop with host", so it starts automatically after reboot |
| `start_esx_shell` | Starts ESXi Shell immediately |
| `ESXiShellTimeOut = 0` | Disables the automatic timeout that turns SSH/Shell off |
| `ESXiShellInteractiveTimeOut = 0` | Stops idle sessions from being closed automatically |
| `SuppressShellWarning = 1` | Hides the "SSH is enabled" warning banner in the UI |
| `auto-backup.sh` | Saves the configuration to the boot bank so it survives a reboot |

### Step B: Make the hosts file persistent using `local.sh`

`/etc/rc.local.d/local.sh` is an ESXi startup script. It runs **at the end of boot**, after `/etc/hosts` has been regenerated from ConfigStore. Re-adding the entries here means they are present after every reboot.

```bash
vi /etc/rc.local.d/local.sh
```

Add the following **before** the final `exit 0` line:

```sh
add() { grep -qw "$2" /etc/hosts || echo "$1 $2.vsphere.local $2" >> /etc/hosts; }
add 100.66.69.110 vcenter803
add 100.66.69.101 esxi8-dell-r450
add 100.66.69.105 stor-gw01
add 100.66.69.121 lab-esxi01
add 100.66.69.122 lab-esxi02
add 100.66.69.123 lab-esxi03
add 100.66.69.201 ceph01
add 100.66.69.202 ceph02
add 100.66.69.203 ceph03
```

**How the code works:**

- `add()` is a small helper function. `$1` is the IP address and `$2` is the hostname.
- `grep -qw "$2" /etc/hosts` checks whether the hostname already exists in the file.
- If it does not exist, `echo ... >> /etc/hosts` appends the line.
- If it already exists, nothing happens, so **no duplicate entries** are created. This matters because ESXi generates its own hostname entry (for example `lab-esxi02` on esxi02).
- Because of this guard, **the same code can be used on all three hosts** without editing it per host.

### Step C: Set permissions, test, and save

```bash
chmod +x /etc/rc.local.d/local.sh
sh /etc/rc.local.d/local.sh
cat /etc/hosts
/sbin/auto-backup.sh
```

| Command | Purpose |
|---|---|
| `chmod +x` | Ensures the script is executable |
| `sh local.sh` | Runs the script manually to confirm the entries appear without a reboot |
| `cat /etc/hosts` | Verifies the result |
| `auto-backup.sh` | Saves the `local.sh` change to the boot bank; without it the change can be lost on reboot |

### Step D: Reboot and verify

```bash
reboot
# after boot:
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'
```

Result: SSH and ESXi Shell start automatically and the hosts entries are present after reboot.

In the Host Client (Actions > Services), the menu should show **"Disable Secure Shell (SSH)"** and **"Disable ESXi shell"**. The menu shows the action you can take, so "Disable" means the service is currently running.

---

## 4. What Did Not Work

| Attempt | Why it failed |
|---|---|
| Editing `/etc/hosts` directly with `vi` | The file is regenerated at boot, so the edit is lost |
| Running `auto-backup.sh` after the edit | Manual hosts entries are not saved to ConfigStore |
| `grep -q lab-esxi01 /etc/hosts` | This only tests for a string and writes nothing, so the file was not changed |

---

## 5. Troubleshooting

```bash
# 1. Confirm the first line of the script is correct
head -5 /etc/rc.local.d/local.sh          # should be #!/bin/sh

# 2. Confirm the script runs at boot
grep -i local.sh /var/log/syslog.log

# 3. Check whether execInstalledOnly blocks local.sh
esxcli system settings kernel list -o execInstalledOnly

# 4. Confirm the code is placed before "exit 0"
cat /etc/rc.local.d/local.sh
```

Any code placed after `exit 0` is never executed.

---

## 6. Notes

- Always run `/sbin/auto-backup.sh` before powering off or resetting a nested host, otherwise recent configuration changes may be lost.
- If a host is added or an IP changes, update the `add` lines in `local.sh` and run `auto-backup.sh` again.
- If vCenter applies a Host Profile, it can override the SSH policy. Check Host > Configure > Services > SSH and confirm it is set to "Start and stop with host".
- DNS is not used in this setup. Name resolution relies on the hosts entries added by `local.sh`.

---

## 7. Summary

| Issue | Solution |
|---|---|
| SSH and ESXi Shell disabled after reboot | `enable_ssh` + `enable_esx_shell` + timeouts set to 0 + `auto-backup.sh` |
| Hosts file reset on reboot | Re-add entries from `/etc/rc.local.d/local.sh` |
| Duplicate entries | `grep -qw` guard in the `add()` function |
| Saving configuration | `/sbin/auto-backup.sh` |
