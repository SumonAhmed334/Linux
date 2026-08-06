# Chapter 4
# Storage Administration for Virtualization

## Course
**Virtualization / Containerization Using Xen, KVM & LXC (XCP-ng & Proxmox)**

---

# Chapter Objectives

After completing this chapter, participants will be able to:

- Review virtualization, containerization, and microservices concepts
- Understand enterprise storage technologies
- Integrate NAS, SAN, and Software-Defined Storage (SDS) with XCP-ng
- Integrate NAS, SAN, and Software-Defined Storage (SDS) with Proxmox VE
- Monitor storage performance and health
- Understand storage maintenance best practices
- Deploy a monitoring stack using Prometheus, Telegraf, InfluxDB, and Grafana
- Monitor virtualization infrastructure in real time
- Apply enterprise storage and monitoring best practices

---

# Session 4.1
# Review Discussion on XCP-ng, Proxmox, Containers & Microservices (Docker)

---

## Learning Objectives

By the end of this session, participants will:

- Refresh virtualization concepts
- Differentiate Virtual Machines and Containers
- Understand Docker and Microservices
- Review enterprise virtualization architecture

---

# Review: Virtualization

Virtualization allows multiple operating systems to run on a single physical server by abstracting hardware resources through a hypervisor.

### Benefits

- Better Hardware Utilization
- Reduced Infrastructure Cost
- High Availability
- Disaster Recovery
- Scalability
- Easy Management

---

# Hypervisor Comparison

| Feature | XCP-ng | Proxmox VE |
|----------|---------|------------|
| Hypervisor | Xen | KVM |
| Containers | No Native | Native LXC |
| Live Migration | Yes | Yes |
| Clustering | Yes | Yes |
| Open Source | Yes | Yes |

---

# Virtual Machine vs Container

| Feature | Virtual Machine | Container |
|----------|-----------------|-----------|
| Operating System | Separate OS | Shared Host Kernel |
| Startup Time | Minutes | Seconds |
| Resource Usage | Higher | Lower |
| Isolation | Strong | Lightweight |
| Windows Support | Yes | No (LXC) |

---

# Docker and Microservices

## What is Docker?

Docker is a container platform that packages applications and their dependencies into lightweight containers.

### Advantages

- Fast Deployment
- Lightweight
- Portable
- Scalable
- Easy CI/CD Integration

---

# Monolithic vs Microservices

### Traditional Monolithic Application

```
Application
│
├── Web
├── Database
├── Authentication
└── API
```

---

### Microservices Architecture

```
Internet
     │
API Gateway
     │
──────────────────────────────
│        │        │        │
User    Auth    Order   Payment
Service Service Service Service
│
Docker Containers
│
Kubernetes / Docker Engine
```

---

# Virtualization Stack

```
Physical Server

↓

Hypervisor

↓

Virtual Machines

↓

Docker

↓

Microservices

↓

Applications
```

---

# Session 4.2
# Adding External Storage (NAS/SAN/SDS) to XCP-ng

---

## Learning Objectives

Participants will learn:

- External Storage Concepts
- Storage Repository (SR)
- NAS Integration
- SAN Integration
- SDS Integration

---

# Storage Types

| Storage Type | Description |
|--------------|-------------|
| DAS | Direct Attached Storage |
| NAS | Network Attached Storage |
| SAN | Storage Area Network |
| SDS | Software Defined Storage |

---

# Storage Architecture

```
                Virtual Machines
                        │
                 Storage Repository
                        │
     ┌──────────┬───────────┬──────────┐
     │          │           │
    NAS        SAN         SDS
```

---

# Adding NAS Storage

Protocols

- NFS
- SMB/CIFS

Example

```
NAS Server

192.168.10.50

Export

/export/vmstorage
```

---

# Adding SAN Storage

Protocols

- iSCSI
- Fibre Channel

Benefits

- High Performance
- Enterprise Ready
- Shared Storage
- Live Migration Support

---

# Software Defined Storage (SDS)

Examples

- Ceph
- TrueNAS SCALE
- GlusterFS
- LizardFS

Advantages

- Scalability
- High Availability
- Self-Healing
- Cost Effective

---

# XCP-ng Storage Repository Types

- Local Storage
- NFS
- iSCSI
- Fibre Channel
- SMB (via Gateway)

---

# Enterprise Storage Example

```
TrueNAS

↓

NFS Export

↓

XCP-ng Storage Repository

↓

Virtual Machines
```

---

# Session 4.3
# Adding External Storage (NAS/SAN/SDS) to Proxmox VE

---

## Supported Storage Types

- Directory
- LVM
- LVM-Thin
- ZFS
- NFS
- SMB/CIFS
- iSCSI
- Ceph
- GlusterFS

---

# Storage Integration

```
Storage

↓

Datacenter

↓

Storage

↓

Add Storage

↓

Select Type

↓

Finish
```

---

# Add NFS Storage

Example

```
Server

192.168.10.50

Export

/export/proxmox

Content

Images
ISO
Backup
Container
```

---

# Add iSCSI Storage

Required

- Target IP
- IQN
- LUN

---

# Ceph Integration

Proxmox provides built-in support for:

- Ceph MON
- Ceph OSD
- Ceph MGR
- CephFS
- RBD Storage

---

# Storage Layout Example

```
Internet

↓

Core Switch

↓

TrueNAS

↓

NFS

↓

Proxmox Cluster

↓

Virtual Machines
```

---

# Session 4.4
# Storage Maintenance & Monitoring

---

## Objectives

Maintain a healthy virtualization storage environment.

---

# Daily Maintenance

- Verify Storage Status
- Check Free Space
- Monitor IOPS
- Monitor Latency
- Verify Backup Jobs
- Review System Logs

---

# Weekly Maintenance

- Test Backups
- Check SMART Status
- Verify RAID Health
- Review Storage Performance

---

# Monthly Maintenance

- Capacity Planning
- Firmware Updates
- Performance Optimization
- Disaster Recovery Testing

---

# Storage Health Indicators

Monitor:

- Disk Usage
- Disk Temperature
- IOPS
- Throughput
- Read Latency
- Write Latency
- RAID Status
- ZFS Pool Health

---

# Storage Best Practices

- Keep Free Space Above 20%
- Enable SMART Monitoring
- Use RAID for Redundancy
- Separate Backup Storage
- Monitor Performance Regularly
- Test Backup Restores
- Document Storage Changes

---

# Session 4.5
# Resource Monitoring with Prometheus, Telegraf, InfluxDB & Grafana

---

## Learning Objectives

Participants will understand:

- Infrastructure Monitoring
- Metrics Collection
- Time-Series Databases
- Visualization Dashboards

---

# Monitoring Architecture

```
Virtualization Hosts

↓

Node Exporter

↓

Prometheus

↓

Grafana Dashboard
```

---

# Monitoring Stack

## Prometheus

Purpose

- Metrics Collection
- Alert Rules
- Time-Series Data

---

## Node Exporter

Collects

- CPU
- Memory
- Disk
- Network
- Filesystem

---

## Telegraf

Collects metrics from:

- Linux
- Windows
- Docker
- Proxmox
- XCP-ng
- Network Devices

Supports multiple output plugins.

---

## InfluxDB

Purpose

- Time-Series Database
- High-Speed Data Storage
- Long-Term Metrics Retention

---

## Grafana

Purpose

- Dashboard Visualization
- Alerting
- Reporting
- Performance Analytics

---

# Monitoring Flow

```
Servers

↓

Telegraf

↓

InfluxDB

↓

Grafana
```

---

# Enterprise Monitoring Example

```
Physical Server

↓

Proxmox

↓

Virtual Machines

↓

Node Exporter

↓

Prometheus

↓

Grafana Dashboard
```

---

# Important Metrics

Monitor:

- CPU Utilization
- Memory Usage
- Disk Utilization
- Storage Latency
- IOPS
- Network Bandwidth
- VM Availability
- Container Status
- Backup Status
- Temperature
- Power Consumption (if available)

---

# Recommended Dashboards

- Infrastructure Overview
- Storage Performance
- Virtual Machines
- Containers
- Network Traffic
- Backup Jobs
- Host Performance
- Capacity Planning

---

# Alert Examples

Generate alerts for:

- CPU Usage > 90%
- Memory Usage > 90%
- Storage Usage > 85%
- Disk Failure
- RAID Degradation
- Backup Failure
- VM Down
- Host Down

---

# Session 4.6
# Bonus Class

---

## Advanced Enterprise Topics

### High Availability (HA)

- HA Concepts
- Failover
- Cluster Quorum
- Fencing

---

### Software Defined Networking (SDN)

Overview of:

- Linux Bridge
- Open vSwitch (OVS)
- VLAN
- VXLAN

---

### PCI Passthrough

Topics

- GPU Passthrough
- NVMe Passthrough
- SR-IOV

---

### Enterprise Backup Solutions

Examples

- Proxmox Backup Server (PBS)
- Veeam Backup
- Bacula
- BorgBackup
- Restic

---

### Future Learning

Students are encouraged to explore:

- Kubernetes
- Docker Swarm
- OpenStack
- Apache CloudStack
- Incus
- Ceph Cluster
- Terraform
- Ansible

---

# Hands-on Lab

### Lab 1

Review the XCP-ng and Proxmox architecture and identify key components.

---

### Lab 2

Connect an NFS storage repository to XCP-ng.

---

### Lab 3

Attach NFS and iSCSI storage to Proxmox VE.

---

### Lab 4

Monitor storage utilization and verify disk health.

---

### Lab 5

Deploy Prometheus and Node Exporter to collect host metrics.

---

### Lab 6

Configure Telegraf to send system metrics to InfluxDB.

---

### Lab 7

Create Grafana dashboards for:

- CPU
- Memory
- Storage
- Network
- Virtual Machines

---

### Lab 8

Configure alerts for high CPU usage, storage capacity, and backup failures.

---

# Chapter Summary

In this chapter, you learned how to:

- Review virtualization and containerization concepts
- Differentiate Virtual Machines, Containers, and Docker-based microservices
- Integrate NAS, SAN, and Software-Defined Storage (SDS) with XCP-ng and Proxmox
- Monitor and maintain enterprise storage environments
- Deploy a monitoring stack using Prometheus, Telegraf, InfluxDB, and Grafana
- Build dashboards and configure alerting for virtualization infrastructure
- Apply storage and monitoring best practices for production environments

---

# Key Takeaways

- Enterprise virtualization depends on reliable shared storage.
- NAS, SAN, and SDS each serve different performance and scalability requirements.
- Continuous monitoring is essential for performance optimization and proactive issue detection.
- Prometheus, Telegraf, InfluxDB, and Grafana together provide a powerful monitoring solution.
- Proper storage administration, regular maintenance, and automated alerting improve the reliability and availability of virtualized infrastructure.

---

## Next Chapter

**Chapter 5 – Enterprise Virtualization Project, Production Deployment & Best Practices**
