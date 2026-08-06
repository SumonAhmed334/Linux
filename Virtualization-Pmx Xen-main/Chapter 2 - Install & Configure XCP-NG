# Chapter 2
# Install & Configure XCP-ng

## Course
**Virtualization / Containerization Using Xen, KVM & LXC (XCP-ng & Proxmox)**

---

# Chapter Objectives

After completing this chapter, students will be able to:

- Install XCP-ng on physical hardware
- Perform initial host configuration
- Connect to the host using Xen Orchestra or XCP-ng Center
- Configure Local, ZFS and NFS Storage
- Upload ISO images
- Create and manage Virtual Machines
- Allocate CPU, Memory and Storage resources
- Create Snapshots
- Configure VM Replication
- Perform Live Migration
- Understand Disaster Recovery concepts
- Perform Backup & Restore
- Troubleshoot common issues

---

# Session 2.1
# Install XCP-ng & Complete the Lab Preparation

---

## Learning Objectives

At the end of this session students will be able to:

- Prepare installation media
- Install XCP-ng
- Configure networking
- Configure management interface
- Verify successful installation

---

# What is XCP-ng?

XCP-ng (Xen Cloud Platform - Next Generation) is an enterprise-grade open-source virtualization platform based on the Xen Hypervisor.

It allows multiple virtual machines to run on a single physical server with enterprise features such as:

- Live Migration
- High Availability
- VM Snapshots
- Storage Management
- Resource Pooling
- Centralized Management

---

# Lab Requirements

## Hardware

| Component | Recommended |
|------------|-------------|
| CPU | Intel VT-x / AMD-V Supported |
| RAM | 16 GB Minimum (32 GB Recommended) |
| Storage | 500 GB SSD |
| Network | 1 Gbps Ethernet |
| USB Drive | 8 GB |

---

## Software

- XCP-ng ISO
- Rufus/Balena Etcher
- Windows PC
- SSH Client
- Web Browser

---

# Installation Steps

## Step 1

Download XCP-ng ISO

https://xcp-ng.org

---

## Step 2

Create Bootable USB

Tools

- Rufus
- Balena Etcher

---

## Step 3

Configure BIOS

Enable

- Intel VT-x
- Intel VT-d
- AMD-V
- IOMMU

Set Boot Mode

- UEFI (Recommended)

---

## Step 4

Boot from USB

Select

```
Install XCP-ng
```

---

## Step 5

Accept License Agreement

Press

```
Accept
```

---

## Step 6

Select Installation Disk

Example

```
Samsung SSD
```

or

```
NVMe Drive
```

---

## Step 7

Configure Keyboard Layout

Example

```
US English
```

---

## Step 8

Configure Root Password

Example

```
Strong Password
```

---

## Step 9

Configure Management Network

Example

```
IP Address : 192.168.10.20
Netmask    : 255.255.255.0
Gateway    : 192.168.10.1
DNS        : 8.8.8.8
```

---

## Step 10

Complete Installation

Remove USB

Reboot

---

# Verify Installation

Console should display

```
Management IP

Hostname

Memory

CPU

Storage
```

---

# Session 2.2
# Basic Configuration of XCP-ng & Access with XCP-ng Center

---

## Learning Objectives

Students will learn

- Configure Host
- Configure Time
- Configure DNS
- Configure NTP
- Configure Network
- Access XCP-ng Center

---

# Host Configuration

Check Host Information

```
xe host-list
```

Check Version

```
xe host-param-get uuid=<HOST-UUID> param-name=software-version
```

---

# Network Configuration

Display Physical NICs

```
xe pif-list
```

Display Networks

```
xe network-list
```

---

# Configure NTP

Example

```
pool.ntp.org
```

---

# Configure DNS

Example

```
Primary DNS

8.8.8.8

Secondary DNS

1.1.1.1
```

---

# Access XCP-ng Center

Install

```
XCP-ng Center
```

Connect

```
Host IP

Username

root

Password
```

---

# Dashboard Overview

Students should identify

- CPU Usage
- Memory Usage
- Storage
- Networks
- Running VMs
- Alerts

---

# Session 2.3
# Storage Configuration for XCP-ng with ZFS & NFS

---

## Storage Types

- Local Storage
- NFS Storage
- ZFS Storage
- iSCSI
- Fibre Channel

---

# Local Storage

Advantages

- Fast
- Simple
- Good for Lab

Disadvantages

- Cannot share across hosts

---

# NFS Storage

Advantages

- Shared Storage
- Supports Live Migration
- Easy Backup

Example

```
NFS Server

192.168.10.50

Export

/export/vmstorage
```

---

# ZFS Storage

Benefits

- Data Integrity
- Compression
- Snapshots
- Replication
- High Performance

---

# Storage Architecture

```
SSD

↓

ZFS Pool

↓

NFS Export

↓

XCP-ng Storage Repository

↓

Virtual Machines
```

---

# Storage Repository Types

- EXT
- LVM
- NFS
- ISO Library

---

# Session 2.4
# Upload ISO & Create Virtual Machine

---

# Upload ISO

Supported ISO

- Ubuntu
- Debian
- Rocky Linux
- Windows Server
- AlmaLinux

---

# Create Virtual Machine

Wizard

```
New VM

↓

Select Template

↓

CPU

↓

Memory

↓

Disk

↓

Network

↓

ISO

↓

Finish
```

---

# Example VM

```
Hostname

ubuntu-server

vCPU

2

RAM

4096 MB

Disk

50 GB

Network

LAN
```

---

# Install Operating System

Examples

- Ubuntu Server
- Rocky Linux
- Windows Server

---

# Session 2.5
# Understand & Modify Resources for Virtual Machine

---

# Virtual Resources

- CPU
- Memory
- Storage
- Network

---

# CPU Allocation

Example

```
2 vCPU

4 vCPU

8 vCPU
```

---

# Memory Allocation

Example

```
2 GB

4 GB

8 GB

16 GB
```

---

# Disk Expansion

Increase

```
50 GB

↓

100 GB
```

---

# Add Additional Disk

Example

```
Database Disk

Backup Disk

Log Disk
```

---

# Network Configuration

Multiple NICs

```
LAN

Management

Storage

Backup
```

---

# Session 2.6
# Snapshot, Replication & Live Migration

---

# Snapshot

Purpose

- Rollback
- Testing
- Upgrade Protection

Workflow

```
VM

↓

Snapshot

↓

Upgrade

↓

Problem?

↓

Restore Snapshot
```

---

# Replication

Purpose

- Business Continuity
- Disaster Recovery

Example

```
Primary Host

↓

Secondary Host

↓

Replica VM
```

---

# Live Migration

Move VM

```
Host A

↓

Host B

(No Downtime)
```

Requirements

- Shared Storage
- Same Network
- Compatible CPU
- Resource Pool

---

# Session 2.7
# Disaster Recovery Planning, Backup & Restore

---

# Why Backup?

Protect against

- Hardware Failure
- User Error
- Ransomware
- Accidental Deletion

---

# Backup Types

- Full Backup
- Incremental Backup
- Differential Backup

---

# Backup Strategy

```
Daily

↓

Weekly

↓

Monthly

↓

Offsite Copy
```

---

# Restore Process

```
Backup

↓

Select Restore Point

↓

Restore VM

↓

Verify Services
```

---

# Disaster Recovery Plan

Checklist

- Backup Verification
- Recovery Testing
- Documentation
- Recovery Time Objective (RTO)
- Recovery Point Objective (RPO)

---

# Best Practices

- Use Shared Storage
- Maintain Multiple Backups
- Test Restore Regularly
- Keep Configuration Backups
- Monitor Backup Jobs
- Document Recovery Procedures

---

# Session 2.8
# Q&A Session and Class Review

---

## Topics to Review

Students should understand:

- XCP-ng Architecture
- Installation Process
- Host Configuration
- Network Configuration
- Storage Repository
- ZFS Storage
- NFS Storage
- ISO Management
- VM Creation
- Resource Allocation
- Snapshots
- Live Migration
- Replication
- Backup & Restore
- Disaster Recovery

---

# Hands-on Lab

### Lab 1
Install XCP-ng on a physical server.

### Lab 2
Configure the management network and verify connectivity.

### Lab 3
Connect to the host using XCP-ng Center.

### Lab 4
Create an NFS Storage Repository.

### Lab 5
Upload an Ubuntu Server ISO.

### Lab 6
Create an Ubuntu virtual machine and complete the OS installation.

### Lab 7
Modify the VM's CPU, RAM, and disk resources.

### Lab 8
Create a snapshot, perform a test change, and restore from the snapshot.

### Lab 9
Simulate a backup and restore process.

---

# Chapter Summary

In this chapter, you learned how to:

- Install XCP-ng on physical hardware
- Perform initial host configuration
- Access and manage the host using XCP-ng Center
- Configure Local, ZFS, and NFS storage repositories
- Upload ISO images and deploy virtual machines
- Manage VM resources such as CPU, memory, storage, and networking
- Use snapshots for quick recovery
- Understand replication and live migration
- Develop backup and disaster recovery strategies
- Apply enterprise best practices for managing an XCP-ng environment

**Next Chapter:** Install & Configure Proxmox VE
