# Virtualization / Containerization Using Xen, KVM & LXC
## XCP-ng & Proxmox Virtualization Platform

**Course Module:** Session 1 - Introduction to Virtualization

---

# Session 1.1 - Introduction, Objectives and Training Goals

## Introduction

Welcome to the **Virtualization / Containerization Using Xen, KVM & LXC (XCP-ng & Proxmox)** training course.

This course is designed to provide both theoretical knowledge and practical experience in modern virtualization technologies used in enterprise datacenters, cloud infrastructure, and service providers.

By the end of this training, participants will be able to deploy, configure, manage, monitor, and troubleshoot virtual infrastructure using **XCP-ng** and **Proxmox VE**.

---

## Training Objectives

After completing this course, participants will be able to:

- Understand virtualization concepts
- Understand hypervisors and containers
- Install and configure XCP-ng
- Install and configure Proxmox VE
- Create and manage Virtual Machines (VMs)
- Create and manage Linux Containers (LXC)
- Configure virtual networking
- Configure storage repositories
- Perform VM migration
- Perform VM backup and restore
- Configure High Availability (HA)
- Monitor virtualization infrastructure
- Troubleshoot common virtualization problems

---

## Target Audience

- System Administrators
- Linux Administrators
- Cloud Engineers
- Network Engineers
- DevOps Engineers
- IT Students
- Data Center Engineers

---

## Prerequisites

Students should have basic knowledge of:

- Linux Operating System
- Networking Fundamentals
- Basic Storage Concepts
- Computer Hardware

---

# Session 1.2 - Virtualization is Everywhere! Why You Have to Learn It

## What is Virtualization?

Virtualization is the technology that allows multiple operating systems to run on a single physical server.

Instead of purchasing multiple physical servers, one powerful server can host many Virtual Machines (VMs).

---

## Why Virtualization?

Traditional Infrastructure:

```
1 Server
   ↓
1 Operating System
   ↓
1 Application
```

Virtualized Infrastructure:

```
1 Physical Server
      │
Hypervisor
      │
├── VM 1
├── VM 2
├── VM 3
├── VM 4
└── VM 5
```

---

## Why Companies Use Virtualization

- Better Hardware Utilization
- Lower Infrastructure Cost
- Faster Deployment
- Disaster Recovery
- High Availability
- Easy Backup
- Easy Migration
- Scalability
- Cloud Computing Foundation

---

## Industries Using Virtualization

- Banking
- Telecommunications
- Government
- Universities
- Hospitals
- Cloud Providers
- Internet Service Providers
- Data Centers
- Software Companies

---

## Career Opportunities

Learning virtualization opens opportunities such as:

- Linux Administrator
- System Engineer
- Cloud Engineer
- Infrastructure Engineer
- DevOps Engineer
- Platform Engineer
- Site Reliability Engineer (SRE)
- Data Center Engineer

---

# Session 1.3 - Different Types of Virtualization Technology & Software

Virtualization has several categories.

---

## 1. Server Virtualization

Most common virtualization.

Example:

- VMware ESXi
- XCP-ng
- Proxmox VE
- Hyper-V

---

## 2. Desktop Virtualization (VDI)

Users access virtual desktops remotely.

Examples:

- VMware Horizon
- Citrix Virtual Apps
- Microsoft Azure Virtual Desktop

---

## 3. Application Virtualization

Applications run independently from the operating system.

Examples:

- Microsoft App-V
- VMware ThinApp

---

## 4. Storage Virtualization

Multiple storage devices are combined into one storage pool.

Examples:

- Ceph
- TrueNAS
- VMware vSAN
- LizardFS

---

## 5. Network Virtualization

Creates logical networks independent of physical devices.

Examples:

- VMware NSX
- Open vSwitch
- VXLAN
- Geneve

---

## 6. Container Virtualization

Containers share the Linux kernel.

Examples:

- Docker
- LXC
- Incus
- Kubernetes
- Podman

---

## Hypervisor Types

### Type-1 (Bare Metal)

Runs directly on hardware.

Examples:

- VMware ESXi
- XCP-ng
- Microsoft Hyper-V
- XenServer

Advantages

- High Performance
- Enterprise Ready
- Secure

---

### Type-2 (Hosted)

Runs on an operating system.

Examples:

- VMware Workstation
- Oracle VirtualBox

Advantages

- Easy Learning
- Home Lab
- Development

---

# Session 1.4 - Comparison Among VMware ESXi, Xen and KVM

| Feature | VMware ESXi | Xen | KVM |
|----------|-------------|------|------|
| Open Source | No | Yes | Yes |
| Performance | Excellent | Excellent | Excellent |
| Enterprise Support | Excellent | Good | Excellent |
| Linux Integration | Medium | Good | Native |
| Windows Support | Excellent | Excellent | Excellent |
| Container Support | Limited | Through Linux | Excellent |
| Live Migration | Yes | Yes | Yes |
| High Availability | Yes | Yes | Yes |
| Cost | High | Low | Free/Open Source |

---

## VMware ESXi

Advantages

- Industry Standard
- Excellent GUI
- Mature Ecosystem
- Enterprise Features

Disadvantages

- Expensive
- License Required
- Closed Source

---

## Xen Hypervisor

Advantages

- Mature Technology
- Stable
- Lightweight
- Excellent Isolation

Disadvantages

- Smaller Community
- Less Common than KVM

---

## KVM

Advantages

- Built into Linux
- Free
- High Performance
- Large Community
- Cloud Native

Disadvantages

- Linux Only
- Requires Linux Knowledge

---

# Session 1.5 - Why Use XCP-ng & Proxmox?

## Why XCP-ng?

XCP-ng is an enterprise-grade virtualization platform built on the Xen Hypervisor.

Features

- Free and Open Source
- Enterprise Ready
- Live Migration
- High Availability
- Xen Orchestra Support
- VM Snapshots
- Storage Management
- GPU Passthrough
- Stable and Secure

Best Use Cases

- Data Centers
- Production Servers
- Enterprise Infrastructure
- Hosting Providers

---

## Why Proxmox VE?

Proxmox VE is a Debian-based virtualization platform that supports both KVM Virtual Machines and LXC Containers.

Features

- KVM + LXC
- Web GUI
- Built-in Backup
- Built-in Firewall
- Ceph Integration
- ZFS Support
- High Availability
- Live Migration
- Clustering
- Open Source

Best Use Cases

- Small Business
- Enterprise
- Home Lab
- Cloud Infrastructure
- ISP Infrastructure

---

## XCP-ng vs Proxmox

| Feature | XCP-ng | Proxmox |
|----------|---------|----------|
| Hypervisor | Xen | KVM |
| Containers | No Native | Native LXC |
| Web Interface | Xen Orchestra | Built-in |
| Cluster | Yes | Yes |
| Live Migration | Yes | Yes |
| Backup | Yes | Yes |
| ZFS Support | Limited | Excellent |
| Ceph Integration | External | Built-in |
| License Cost | Free | Free |

---

# Session 1.6 - Preparing the Virtual Lab

## Recommended Hardware

### Minimum

- Intel VT-x / AMD-V CPU
- 16 GB RAM
- 250 GB SSD
- Dual-Core Processor

---

### Recommended

- Intel Xeon / AMD EPYC
- 32 GB RAM or Higher
- 1 TB SSD/NVMe
- 4+ CPU Cores
- Gigabit Network

---

## BIOS Settings

Enable:

- Intel VT-x
- Intel VT-d
- AMD-V
- AMD IOMMU
- SR-IOV (Optional)

---

## Software Required

- XCP-ng ISO
- Proxmox VE ISO
- Ubuntu Server ISO
- Windows Server ISO
- Rocky Linux ISO
- Debian ISO

---

## Network Design

```
                Internet
                    │
              Home/Office Router
                    │
            ┌───────────────┐
            │ Managed Switch│
            └──────┬────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
    XCP-ng Host          Proxmox Host
        │                     │
   ┌────┴────┐          ┌─────┴─────┐
   │          │          │           │
 VM1        VM2       VM3         LXC1
```

---

## Lab Requirements

Each participant should have:

- One physical PC or Server
- Virtualization enabled in BIOS
- USB flash drive (optional)
- Stable Internet connection
- SSH Client
- Web Browser
- ISO Images

---

## Expected Lab Outcome

By the end of Session 1, participants will:

- Understand virtualization fundamentals
- Understand different hypervisors
- Know the differences between ESXi, Xen, and KVM
- Understand why XCP-ng and Proxmox are selected
- Prepare hardware for virtualization
- Be ready to install the virtualization platform in the next session

---

# Summary

In this session, we learned:

- What virtualization is
- Why virtualization is important
- Types of virtualization
- Hypervisor architectures
- Comparison of VMware ESXi, Xen, and KVM
- Introduction to XCP-ng and Proxmox
- Virtual lab preparation

The next session will focus on installing XCP-ng and Proxmox VE.
