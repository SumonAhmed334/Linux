# Chapter 3
# Install & Configure Proxmox VE

## Course
**Virtualization / Containerization Using Xen, KVM & LXC (XCP-ng & Proxmox)**

---

# Chapter Objectives

After completing this chapter, participants will be able to:

- Install Proxmox VE on physical hardware
- Perform initial system configuration
- Explore the Proxmox Web Interface (Web UI)
- Configure networking and storage
- Create and manage Virtual Machines (KVM)
- Create and manage Linux Containers (LXC)
- Allocate and modify CPU, Memory, Storage, and Network resources
- Create snapshots
- Configure replication and migration
- Perform backup and restore
- Implement Disaster Recovery (DR) strategies
- Apply virtualization best practices

---

# Session 3.1
# Install Proxmox VE & Complete the Lab Preparation

---

## Learning Objectives

At the end of this session, students will be able to:

- Install Proxmox VE
- Configure management networking
- Configure hostname and DNS
- Access the Web UI
- Verify the installation

---

# What is Proxmox VE?

Proxmox Virtual Environment (PVE) is an open-source enterprise virtualization platform built on Debian Linux.

It supports both:

- **KVM (Kernel-based Virtual Machine)** for Virtual Machines
- **LXC (Linux Containers)** for lightweight container virtualization

Proxmox also provides:

- High Availability (HA)
- Live Migration
- Backup & Restore
- Built-in Firewall
- Clustering
- ZFS & Ceph Support
- Software Defined Storage

---

# Lab Requirements

## Recommended Hardware

| Component | Recommended |
|------------|-------------|
| CPU | Intel VT-x / AMD-V |
| RAM | 16 GB Minimum (32 GB Recommended) |
| Storage | 500 GB SSD/NVMe |
| Network | 1 Gbps Ethernet |
| USB Drive | 8 GB |

---

## Software

- Proxmox VE ISO
- Rufus / Balena Etcher
- Ubuntu Server ISO
- Rocky Linux ISO
- Windows Server ISO
- SSH Client
- Web Browser

---

# Installation Steps

## Step 1

Download the latest Proxmox VE ISO.

---

## Step 2

Create a bootable USB using Rufus or Balena Etcher.

---

## Step 3

Configure BIOS

Enable:

- Intel VT-x
- Intel VT-d
- AMD-V
- IOMMU

---

## Step 4

Boot from the USB drive and select:

```
Install Proxmox VE
```

---

## Step 5

Accept the License Agreement.

---

## Step 6

Select the installation disk.

Example:

```
NVMe SSD
```

---

## Step 7

Configure:

- Country
- Time Zone
- Keyboard Layout

---

## Step 8

Set:

- Root Password
- Email Address

---

## Step 9

Configure Management Network

Example

```
Hostname

pve01.lab.local

IP Address

192.168.10.100

Gateway

192.168.10.1

DNS

8.8.8.8
```

---

## Step 10

Complete Installation

Remove installation media and reboot.

---

# Verify Installation

Open a browser:

```
https://192.168.10.100:8006
```

Login

```
Username

root

Realm

Linux PAM

Password

********
```

---

# Session 3.2
# Basic Configuration & Explore the Web UI

---

## Learning Objectives

Students will learn:

- Navigate the Web UI
- Configure repositories
- Update the system
- Configure networking
- Configure time synchronization
- Manage users and permissions

---

# Proxmox Dashboard

Explore the following sections:

- Datacenter
- Cluster
- Node
- Virtual Machines
- Containers
- Storage
- Network
- Firewall
- Backup
- Tasks
- Shell

---

# Initial Configuration Checklist

- Configure Hostname
- Configure DNS
- Configure NTP
- Update Packages
- Configure Repository
- Verify Time Zone

---

# Network Configuration

Example

```
Management Bridge

vmbr0

↓

Physical NIC

eno1
```

---

# Linux Bridge

```
Internet

↓

Switch

↓

eno1

↓

vmbr0

↓

VMs & Containers
```

---

# User Management

Create:

- Administrator
- Operator
- Read-only User

Assign roles using Role-Based Access Control (RBAC).

---

# Session 3.3
# Storage Configuration & Create Virtual Machine

---

## Storage Types Supported

- Local Directory
- Local-LVM
- ZFS
- NFS
- SMB/CIFS
- iSCSI
- Ceph
- GlusterFS

---

# Local Storage

Suitable for:

- Home Labs
- Small Environments
- Single Host Deployments

---

# ZFS Storage

Advantages

- Data Integrity
- Compression
- Snapshots
- Replication
- RAID Support

---

# NFS Storage

Advantages

- Shared Storage
- Centralized Backup
- Live Migration Support

Example

```
NFS Server

192.168.10.50

Export

/export/proxmox
```

---

# Create a Virtual Machine

Wizard

```
Create VM

↓

General

↓

OS

↓

System

↓

Disk

↓

CPU

↓

Memory

↓

Network

↓

Finish
```

---

## Example VM

```
Name

Ubuntu-Server

CPU

2 vCPU

RAM

4096 MB

Disk

50 GB

Bridge

vmbr0
```

---

# Install Operating System

Examples

- Ubuntu Server
- Debian
- Rocky Linux
- AlmaLinux
- Windows Server

---

# Session 3.4
# Create LXC Container and Explore It

---

## What is an LXC Container?

LXC (Linux Containers) is an operating-system-level virtualization technology.

Containers:

- Share the host kernel
- Consume fewer resources
- Start quickly
- Are ideal for lightweight workloads

---

# LXC vs Virtual Machine

| Feature | LXC | Virtual Machine |
|----------|-----|-----------------|
| Kernel | Shared | Dedicated |
| Startup Time | Seconds | Minutes |
| Resource Usage | Low | Higher |
| Performance | Near Native | High |
| OS Support | Linux Only | Linux & Windows |

---

# Create an LXC Container

Wizard

```
Create CT

↓

Template

↓

Root Disk

↓

CPU

↓

Memory

↓

Network

↓

DNS

↓

Finish
```

---

## Example Container

```
Hostname

web01

CPU

2 Cores

Memory

2048 MB

Storage

20 GB

Bridge

vmbr0
```

---

# Container Management

Students should practice:

- Start
- Stop
- Shutdown
- Restart
- Console Access
- Clone
- Delete

---

# Session 3.5
# Understand & Modify Resources for Virtual Machines & Containers

---

# CPU Management

Example

```
2 vCPU

↓

4 vCPU
```

---

# Memory Management

Example

```
4 GB

↓

8 GB
```

---

# Storage Expansion

```
50 GB

↓

100 GB
```

---

# Add Additional Virtual Disk

Example

- Database Disk
- Backup Disk
- Log Disk

---

# Network Configuration

Examples

- vmbr0
- VLAN
- Bond Interface

---

# Hot Plug Features

Proxmox supports:

- CPU Hot Plug
- Memory Hot Plug
- Disk Resize

(Some features depend on the guest operating system.)

---

# Session 3.6
# Snapshot, Replication & Migration

---

# Snapshot

Purpose

- Testing
- Upgrade Rollback
- Safe Configuration Changes

Workflow

```
VM

↓

Snapshot

↓

Upgrade

↓

Rollback if Needed
```

---

# Replication

Purpose

- Synchronize VM data between nodes
- Improve Disaster Recovery

Example

```
Node-1

↓

Replication

↓

Node-2
```

---

# Live Migration

Move a running VM from one node to another with minimal downtime.

Requirements

- Cluster Configuration
- Shared Storage (or compatible migration method)
- Compatible CPU
- Network Connectivity

---

# Offline Migration

Move a powered-off VM between storage or nodes.

---

# Session 3.7
# Disaster Recovery Planning, Backup & Restore

---

# Why Disaster Recovery?

To protect services from:

- Hardware Failure
- Power Failure
- Human Error
- Malware/Ransomware
- Site Failure

---

# Backup Types

- Full Backup
- Incremental Backup
- Differential Backup

---

# Proxmox Backup Options

- Local Storage
- NFS
- SMB/CIFS
- Proxmox Backup Server (PBS)

---

# Backup Schedule

Example

```
Daily

↓

Weekly

↓

Monthly

↓

Offsite Backup
```

---

# Restore Process

```
Backup

↓

Select Restore Point

↓

Restore VM/Container

↓

Verify Services
```

---

# Disaster Recovery Checklist

- Verify Backups
- Test Recovery Procedures
- Maintain Documentation
- Monitor Backup Jobs
- Store Offsite Copies
- Review RTO and RPO

---

# Best Practices

- Enable scheduled backups
- Use separate backup storage
- Test restores regularly
- Keep configuration backups
- Monitor storage capacity
- Maintain updated documentation

---

# Session 3.8
# Q&A Session and Class Review

---

## Topics to Review

Students should understand:

- Proxmox Architecture
- Installation Process
- Web UI Navigation
- Network Configuration
- Storage Management
- Virtual Machine Deployment
- LXC Container Deployment
- Resource Management
- Snapshots
- Replication
- Live Migration
- Backup & Restore
- Disaster Recovery

---

# Hands-on Lab

### Lab 1

Install Proxmox VE on a physical server.

---

### Lab 2

Configure the management network and verify Web UI access.

---

### Lab 3

Create a Linux Bridge (vmbr0) and verify connectivity.

---

### Lab 4

Configure Local and NFS storage.

---

### Lab 5

Upload an Ubuntu Server ISO.

---

### Lab 6

Create a KVM Virtual Machine and install Ubuntu Server.

---

### Lab 7

Create an LXC container using a Debian template.

---

### Lab 8

Modify CPU, Memory, and Storage resources for both the VM and the LXC container.

---

### Lab 9

Create a snapshot, perform changes, and restore from the snapshot.

---

### Lab 10

Perform a backup and restore of both a Virtual Machine and an LXC container.

---

# Chapter Summary

In this chapter, you learned how to:

- Install Proxmox VE on enterprise hardware
- Configure the management network and initial settings
- Explore and use the Proxmox Web UI
- Configure Local, ZFS, and NFS storage
- Create and manage KVM Virtual Machines
- Create and manage LXC Containers
- Modify CPU, Memory, Disk, and Network resources
- Use snapshots for safe rollback
- Configure replication and migration
- Perform backup and restore operations
- Develop Disaster Recovery strategies for production environments

---

# Key Takeaways

- **KVM** provides full hardware virtualization suitable for Linux and Windows guests.
- **LXC** offers lightweight Linux container virtualization with near-native performance.
- Proxmox VE combines KVM and LXC into a single enterprise management platform.
- Proper storage, networking, backup, and disaster recovery planning are essential for a reliable virtualization environment.
- Regular monitoring, testing, and documentation are critical for production deployments.

---

## Next Chapter

**Chapter 4 – Advanced Virtual Networking, Storage Management & High Availability**
