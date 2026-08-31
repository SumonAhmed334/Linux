# Ubuntu 24.04 Production NTP Server + Ubuntu Client + Windows Client এর Complete Configuration

*By Ikbal Hossain — [linkedin.com/in/ikbal-hossain-4b317b353](https://www.linkedin.com/in/ikbal-hossain-4b317b353)*

---

## 1. বর্তমান Time ও Timezone Check করুন

```bash
timedatectl
```

### Recommended Architecture

```
Internet
   │
   ▼
Public NTP Servers
   │
   ▼
┌────────────────────────┐
│ Ubuntu 24.04 NTP Server│
│ Timezone: Asia/Dhaka   │
│ IP: 192.168.1.10       │
│ UDP Port: 123          │
└────────────┬───────────┘
             │
   ┌────────────┼─────────────┐
   │            │             │
   ▼            ▼             ▼
Web Server   DB Server    App Server
Chrony       Chrony       Chrony
Client       Client       Client
```

---

## 2. Bangladesh Timezone সেট করুন

Ubuntu Server-এ Bangladesh timezone হলো:

```
Asia/Dhaka
```

Command:

```bash
sudo timedatectl set-timezone Asia/Dhaka
```

আবার Check করুন:

```bash
timedatectl
```

---

## 3. Chrony Install করুন

Ubuntu 24.04-এ NTP synchronization-এর জন্য Chrony ব্যবহার করা ভালো।

```bash
sudo apt update
sudo apt install chrony -y
```

Service চালু করুন:

```bash
sudo systemctl enable --now chrony
```

Status দেখুন:

```bash
sudo systemctl status chrony
```

---

## 4. NTP Server Configure করুন

Configuration file open করুন:

```bash
sudo vim /etc/chrony/chrony.conf
```

Default pool বা server configuration প্রয়োজন অনুযায়ী রেখে/পরিবর্তন করে নিচের মতো configure করতে পারেন:

```ini
# ==========================================
# Production NTP Server - Ubuntu 24.04
# Timezone: Asia/Dhaka (UTC+6)
# ==========================================

# Upstream NTP Servers
pool 0.pool.ntp.org iburst maxsources 4
pool 1.pool.ntp.org iburst maxsources 4
pool 2.pool.ntp.org iburst maxsources 4
pool 3.pool.ntp.org iburst maxsources 4

# Drift File
driftfile /var/lib/chrony/chrony.drift

# Initial Clock Synchronization
makestep 1.0 3

# Real Time Clock Sync
rtcsync

# Allow Internal Network Clients
allow 192.168.1.0/24

# Optional additional networks
# allow 192.168.10.0/24
# allow 10.10.0.0/16

# NTP Server Port
port 123

# Logging
log tracking measurements statistics
logdir /var/log/chrony

# Local fallback clock
# Only enable if you want this server to continue
# serving time during an Internet outage.
local stratum 10
```

আপনার LAN অন্য subnet হলে পরিবর্তন করবেন।

উদাহরণ:

```
allow 192.168.10.0/24
```

অথবা একাধিক Network:

```
allow 192.168.1.0/24
allow 192.168.10.0/24
allow 10.0.0.0/8
```

> `allow` না দিলে অন্য Client Server আপনার NTP Server থেকে সময় নিতে পারবে না।

---

## 5. Chrony Restart করুন

```bash
sudo systemctl restart chrony
```

তারপর:

```bash
sudo systemctl status chrony
```

---

## 6. NTP Time Sources Check করুন

```bash
chronyc sources -v
```

আরও সহজভাবে:

```bash
chronyc sources
```

যে Source-এর সামনে `^*` থাকবে সেটি বর্তমানে প্রধান synchronized time source।

---

## 7. Synchronization Status Check

```bash
chronyc tracking
```

`Leap status : Normal` হলে সাধারণত synchronization ঠিক আছে।

---

## 8. Firewall-এ NTP Port Allow করুন

NTP UDP Port:

```
UDP 123
```

UFW ব্যবহার করলে:

```bash
sudo ufw allow 123/udp
```

Check:

```bash
sudo ufw status
```

---

## 9. অন্য Ubuntu Server-কে এই NTP Server ব্যবহার করানো — Client

ধরি আপনার NTP Server IP:

```
192.168.1.10
```

Client Server-এ Chrony install করুন:

```bash
sudo apt update
sudo apt install chrony -y
```

Configuration open করুন:

```bash
sudo vim /etc/chrony/chrony.conf
```

Public pool-এর পরিবর্তে আপনার Internal NTP Server যোগ করুন:

```ini
# ======================================
# Ubuntu 24.04 NTP Client Configuration
# ======================================

# Internal Production NTP Server
server 192.168.1.10 iburst

# Drift File
driftfile /var/lib/chrony/chrony.drift

# Step clock if offset is large during startup
makestep 1.0 3

# Synchronize system clock to RTC
rtcsync
```

তারপর:

```bash
sudo systemctl enable --now chrony
sudo systemctl restart chrony
```

Check করুন:

```bash
chronyc sources -v
```

এবং:

```bash
chronyc tracking
```

---

## গুরুত্বপূর্ণ বিষয়

NTP Server এবং Timezone আলাদা বিষয়।

- **NTP** = সঠিক UTC time synchronize করে
- **Timezone Asia/Dhaka** = Server-এ Bangladesh Local Time (UTC+6) প্রদর্শন করে

অর্থাৎ সব Server-এ:

```bash
sudo timedatectl set-timezone Asia/Dhaka
```

এবং Client-গুলোকে আপনার Internal NTP Server থেকে সময় নিতে configure করা যাবে।

---

## Windows Server / Windows 10 / Windows 11 NTP Client

ধরি আপনার NTP Server:

```
192.168.1.10
```

> **গুরুত্বপূর্ণ:** Command Prompt বা PowerShell অবশ্যই **Run as Administrator** হিসেবে Open করবেন।

### Step 1: Windows Time Service Stop করুন

```shell
net stop w32time
```

### Step 2: Existing Configuration Remove করুন

```shell
w32tm /unregister
```

তারপর আবার Service Register করুন:

```shell
w32tm /register
```

Service Start করুন:

```shell
net start w32time
```

> Domain Controller বা Active Directory Domain Environment-এ `w32tm /unregister` করার আগে সতর্ক থাকুন। Domain-এর Time Hierarchy Configuration নষ্ট হতে পারে।

### Step 3: Internal NTP Server Configure করুন

```shell
w32tm /config /manualpeerlist:"192.168.1.10,0x8" /syncfromflags:manual /reliable:NO /update
```

এখানে:

- `192.168.1.10` = আপনার Ubuntu NTP Server
- `0x8` = Client Mode

### Step 4: Windows Time Service Restart করুন

```shell
net stop w32time
net start w32time
```

### Step 5: Force Time Synchronization

```shell
w32tm /resync /force
```

### Step 6: Verify NTP Configuration

```shell
w32tm /query /configuration
```

Source Check:

```shell
w32tm /query /source
```

Expected:

```
192.168.1.10
```

Synchronization Status:

```shell
w32tm /query /status
```

Peer Check:

```shell
w32tm /query /peers
```
