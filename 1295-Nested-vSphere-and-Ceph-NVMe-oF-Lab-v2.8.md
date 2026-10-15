# vSphere 8 + Ceph NVMe-oF Platform — Master Build, Lab, Operations and Maintenance Guide

**Revision 15 — 2026-10-05.** The whole platform is built, clustered, expanded and running, and **live migration is proven in both directions**: three nested ESXi hosts, a three-node Ceph cluster, three NVMe-oF gateways and six VMFS-6 datastores of 40 GiB reached over two fabrics with ANA multipathing. Every command in Parts 1–7 has now been run on the real build.

This revision is sequenced for vMotion. Each nested host is built, **rebooted** and verified on its own before any host joins vCenter, because a VMkernel port added to a running host is configured correctly and not fully live — see 4.1, Condition 4. Each of the three nodes now has its own complete, standalone section, so no command block says *"run this on all hosts"* and no host can quietly be skipped.

**Supersedes:** `r450-esxi8-zfs-storage-vm-build-guide.md`, `ceph-nvmeof-vmware-build-guide-rev2.md`, `r450-nested-lab-guide-rev4.md`, `vsphere8-postinstall-ops-guide.md` and `ceph-nvmeof-lab-guide-rev2.md`. Everything in those is either here or deliberately dropped as no longer applicable.

---

## How this guide is organised

Each Part is one job on one set of machines, in build order, with its own gate at the end. **Every command block is labelled with the host to run it on**, in a comment line like `# ===== RUN ON: ceph01 =====`. Check the shell prompt against that label before pasting.

| Part | What it builds | Where it runs |
|---|---|---|
| 0 | Plan, inventory, addressing, build status | — |
| **1** | **Dell R450 ESXi 8 host preparation** | `esxi8-dell-r450` |
| **2** | **vCenter preparation** — hosts guard, `DC-DEV` / `VCLOUD`, Quickstart, vCLS | `vcenter803` |
| **3** | **Storage gateway VM** | `stor-gw01` (+ R450) |
| **4** | **Nested lab ESXi node preparation** — one complete standalone section per node, then the cluster and vMotion | `lab-esxi01/02/03` |
| **5** | **Ceph cluster configuration** — one self-contained section per node | `ceph01/02/03` |
| **6** | **NVMe-oF gateway configuration** (the second half of the Ceph build) | `ceph01` |
| **7** | **VMware integration** | each nested host, then vCenter |
| 8 | Test plan — T1 to T14 | across the platform |
| 9 | Performance tuning | — |
| **10** | **Platform operations** — routine checks, capacity expansion, symptom index | all |
| **11** | **Ceph operations** — health, OSDs, pools, gateways, diagnostics | `ceph01/02/03` |
| **12** | **Maintenance and failure procedures** — patching, shutdown, and losing a node of either kind | all |
| **13** | **Scaling out** — adding `lab-esxi04` and `ceph04` to the running platform | new node + existing |
| 14 | Path to production | — |
| A–E | Appendices, including every correction made during the live build | — |

There are no `$N`-style variables anywhere. Every host-specific address and hostname is written out literally, with the full address table in 4.2. The only `$` signs that remain are the `mac()` helper in Part 4, which reads a vNIC's real MAC, and `$NQN` in Parts 6 and 7, which you paste from command output.

## What changed in Revision 15

**The build now creates 40 GiB datastores directly.** Revision 14's build path still said 25 GiB in 5.1, 6.4 and 7.5 — the size the first build used before it was grown — so anyone rebuilding from the guide would have built small and then had to grow. 5.1 now sizes against `MAX AVAIL` with the ratios written out, 6.4 creates `--size 40G`, and 7.5 carries the matching sector arithmetic (**83,886,046**, not 52,428,766). **10.5 remains the expansion runbook** and is unchanged: it is what you use the next time you genuinely need to grow, not something to run routinely after every build.

**New 12.10 — losing a Ceph node.** The complete sequence: the four layers that keep storage up and which of them is actually active/active, the ANA ownership map that makes the blast radius knowable in advance, a timeline for an unplanned node loss, what to do and what *not* to do while it is down, and the recovery — including the thing nobody expects, that **failback is a second pause**. It closes on the guest-side check that is most often skipped: a VM whose filesystem remounted read-only is still running, and no amount of Ceph recovery fixes it.

**New 12.11 — losing an ESXi host.** The same treatment for the compute side, which behaves in the opposite way: HA restarts a dead VM rather than moving a live one, so guest memory is lost and every VM on the host is affected. It covers what HA needs to tell "dead" from "isolated" — and why the two heartbeat datastores were deliberately chosen from different gateways — the admission-control arithmetic, the zero-downtime planned path through Maintenance Mode, re-gating a host that rebooted, and the correlated failures no HA configuration can cover.

**New 12.12 — which failure is worse.** The honest answer is that it depends on the dimension: **an ESXi host failure hurts more now, a Ceph failure hurts more if it goes wrong**, because one tier is stateless and the other is not. It also records the coupling between them — HA's APD response is set to restart VMs, so a slow enough ANA handover turns a storage pause into a compute outage — and names the three correlated failures that outrank either single-node case, one of which is free to fix.

**Part 12 is retitled "Maintenance and failure procedures"** to match what it now contains.

## What changed in Revision 14

**Each nested host has its own complete section — 4.3 for `lab-esxi01`, 4.4 for `lab-esxi02`, 4.5 for `lab-esxi03`.** Revision 13 shared command blocks between hosts with a *"run this on all three"* note, which is how `lab-esxi03` reached the cluster with `vmk1` entirely missing. Each section is now nine subsections from install to post-reboot gate, with every address written out literally and every block labelled with that one host. Nothing is shared, nothing is inherited, and you do not start the next node until the one you are on passes its own gate.

**The build order is now sequenced around vMotion**, which is the thing most easily broken by doing the right steps in the wrong order:

| Order | Step | Why here |
|---|---|---|
| 1 | Build each host completely, **including its reboot** | 4.3.8 — the vMotion server binds its TCP/IP stack at vmkernel initialisation |
| 2 | Cross-host network gate | 4.6 — `vmkping -S vmotion` between all three, before vCenter is involved |
| 3 | Add hosts to vCenter | 4.7 — nothing but adding hosts |
| 4 | Prove vMotion both directions **manually** | 4.8 — before DRS is allowed to move anything on its own |
| 5 | Then HA and DRS | 4.8 — DRS vMotions on its own schedule; it must not be the thing that discovers a broken stack |

**New 4.1 Condition 4 — every host is rebooted before it joins the cluster.** This cost an afternoon on the live build. `lab-esxi02` had a correct `vmk1` on the `vmotion` netstack with the `VMotion` tag, `vmkping -S vmotion` worked in both directions, and migration still failed with `Failed to start migration: Networking stack mismatch`. Every `esxcli` command reported a correct configuration because the configuration *was* correct. The cause appears only in `vmkernel.log`: the vMotion server had bound `defaultTcpipStack` at boot, because no vMotion vmknic existed then, and it keeps that binding until the host restarts. A reboot fixed it on both hosts. **Configured is not the same as effective** — the same shape as Condition 2's Standby uplink, and the same shape as E44 and E45 in Appendix E.

**New Part 13 — scaling out.** Complete procedures for adding a fourth nested host and a fourth Ceph node to the running platform, which is the part of this design that was never written down. 13.2 builds `lab-esxi04` and integrates it with the existing cluster — the gateway-side host-NQN grant, the six controllers, and why the six datastores appear without creating anything. 13.3 adds `ceph04`: why it stays at **3 monitors** rather than 4, how `size=3` behaves across four hosts, what the rebalance costs and how to pace it, and whether to run a fourth gateway. 13.4 covers what changes afterwards — capacity arithmetic, failure domains, and the checks that now expect four of something.

**New Appendix E rows E48 and E49**, both from proving vMotion, and both about the difference between configuration and runtime state.

## What changed in Revision 13

**New 10.5 — capacity expansion.** A complete runbook for growing a datastore across all four layers: RBD image, NVMe-oF namespace, ESXi rescan, VMFS. It carries the sector arithmetic as a lookup table, explains the `partedUtil` GPT-backup message that looks like a failure and is not, sets the ceiling against `MAX AVAIL` rather than raw capacity, and says when adding namespaces beats growing them. Run end to end on the live platform on 2026-10-05, taking all six datastores from 25 GiB to 40 GiB with VMs running.

**New Part 11 — Ceph operations.** Day-2 for the cluster and the gateways: reading health, routine checks, OSD and pool work, gateway operations, logs and a failure runbook. It records three things the live build surfaced that no document warned about — the `cephadm shell` container prompt and what is *not* inside it, `cephadm logs` being host-local, and two findings with real consequences: **overlapping CRUSH roots have disabled the PG autoscaler since the pools were created**, and **`cephadm` autotune silently reduced `osd_memory_target` from the 1 GiB that 5.7 sets to 411 MB**, below Ceph's own minimum, which would have invalidated every performance measurement.

**Part 10 is now platform operations.** 10.1 is rebuilt around what to check on each of the five machine types and what "clean" looks like on each, with a short section on the three checks that would have caught this build's real faults — all three being cases where attribute checks passed and nothing verified existence or effective value.

**New 10.7 — symptom index.** One table per area, naming the first command and the section that holds the procedure. It is the fastest route into the guide when something is wrong.

**The old Parts 11 and 12 are renumbered to 12 and 13** to make room, and three cross-references that were wrong since Revision 9 are corrected.

## Earlier revision notes

*Section numbers in the entries below are as they stood in the revision being described. Revision 14 renumbered Part 4 and inserted Part 13, so use the contents table above, or Appendix E's "Fixed in" column, for where any of this lives now.*

## What changed in Revision 12

**Part 2 is now a complete vCenter build, not a baseline.** It gained the two things that actually happen when you create a cluster and that nothing told you about: **2.4** on Cluster Quickstart, which offers to build a Distributed Switch and migrate your VMkernel ports onto it — an action that would dismantle the entire nested networking design — and **2.5** on the vCLS agent VMs that appear by themselves, what they are, why there may be two rather than three, and why pinning their datastore matters before Part 8 testing. Object names throughout are now the live ones, **`DC-DEV`** and **`VCLOUD`**.

**The application VLAN for guest VMs** (now 4.1, Condition 3). A fifth vNIC on `vlan.2002` gives VMs inside the nested hosts real network connectivity. This works on a different principle from everything above it: the MAC-matching trick in 4.1 cannot be applied to guests, because each guest has its own MAC, so the outer port group must permit **forged transmits** on the way out and **promiscuous mode** on the way back. `vlan.2002` already permits both, inherited from `vswitch2` — verified read-only, so the hard constraint still holds and nothing on the R450 changes.

**`nested-shared` is retired.** It existed only because *"Ceph is not built yet"*, and Ceph is now built before the cluster is finished. Ceph-only is also the more faithful test: production will have Ceph and nothing else.

**Part 4 was renumbered** to fit the new material — superseded again by Revision 14's per-node sections. The test VMs gained network adapters and `fio`, which the old no-adapter design made impossible.

**A new check in the node gate** — count the VMkernel ports. `lab-esxi03` joined the cluster with `vmk1` entirely absent while every port-group-level check passed.

## What changed in Revision 11

**Adding hosts to vCenter and building the cluster now has real sections.** Revision 10 carried four bullet lines, buried at the end of the node-prep part, which was not enough to work from and not where anyone would look. The datacenter and cluster objects are now created empty in **2.3**, as part of vCenter preparation; **4.7** is a full procedure for adding each host — the no-DNS prerequisites, why the IP rather than the name, verifying the certificate thumbprint, what to set immediately after a host joins, a symptom-to-cause table for failed or flapping adds, and only then shared storage and turning HA and DRS on.

## What changed in Revision 10

**Structure.** Seven clearly separated build parts in dependency order, each on one machine or one set of machines. The old combined "R450 and vCenter" part is split in two. The nested lab now has a complete standalone section per node (4.3.1, 4.3.2, 4.3.3) — a second person can build hosts 02 and 03 from 4.3.2 and 4.3.3 alone. Ceph is the cluster (Part 5) and the NVMe-oF gateways (Part 6); the ESXi side is Part 7.

**The big correction — uplink failover policy.** `esxcli network vswitch standard uplink add` does **not** guarantee the uplink becomes active. On all three nested hosts it left the uplink in Standby with no Active adapter. Ordinary IP traffic is unaffected, so `vmkping` is clean and everything looks healthy — but NVMe/TCP resolves its source VMkernel port through the portset's *active* teaming member, so `fabrics connect` fails with `Failed to get source vmknic`. Every `uplink add` is now followed by `policy failover set --active-uplinks=`, and 4.4 verifies it. Full account, including the five hypotheses that were wrong, in 4.1.

**A retraction — single-subnet NVMe/TCP.** Revision 9 concluded that two VMkernel ports could not share a subnet and that production would need two storage subnets. **That is withdrawn.** `vmk2` at `.141` and `vmk3` at `.151` both work in `100.66.69.0/24` while `vmk0` owns the route, because NVMe/TCP never consults the routing table. 4.4 has the detail.

**A retraction — device class.** Revisions 8 and 9 said QEMU virtual disks misreport flash as rotational and told you to override the OSD class to `ssd`. The Ceph VMs here are on **10k SAS spinning disks**, so `hdd` was correct all along. The rule is `hdd-rule`, the override is gone, and 5.7 says when an override is and is not legitimate.

**New prerequisite — CPU and RAM on the Ceph nodes.** `ceph-nvmeof` 1.7 runs on Rocky Linux 10, which needs **x86-64-v3**. Proxmox's default `kvm64` model does not provide it, and the gateways fail with `Fatal glibc error` after the cluster is already built. 5.1 sets the requirement; 6.1 has the recovery if you hit it late.

**New section — persistence across reboot.** SSH, the ESXi Shell and manual `/etc/hosts` entries are all lost on reboot, each for a different reason. 1.5 fixes it on the R450 and 4.6 on the nested hosts, with `/etc/rc.local.d/local.sh` and `auto-backup.sh`.

**New section — datastore sizing.** 7.7 answers how many namespaces and how large, driven by ANA being per-namespace: one big datastore would put every byte on one gateway.

**Measured values replace guesses throughout.** `--pool`/`--group` named flags on `orch apply nvmeof`; underscore flag spelling (`--host_name`, `--rbd_pool`, `--rbd_image_name`, `--block_size`, `--host_nqn`); explicit `--block_size 512`; confirmation that 1.7.23 auto-balances load-balancing groups; the ANA ownership table; SPDK's whole-core consumption and 8 GiB hugepage reservation; the `Active: False` listener column being bookkeeping; the `NVMeoFInterfaceDuplex` alert being a virtio artefact; and the VMFS sector arithmetic for a 25600 MB namespace.

### Earlier revisions

**Revision 9** — the Ceph nodes' networking is *verified* rather than rewritten: the Ubuntu installer's `50-cloud-init.yaml` is kept as-is, with no `match` and no `set-name`, and 5.2 explains why MAC pinning is the wrong trade on a Proxmox VM.

**Revision 8** — Ceph rebuilt and split into three parts, each with its own gate. Each Ceph node got its own section with literal commands and the measured KVM disk layout.

**Revision 7** — `lab-esxi01` built; the nested-lab part rewritten from what actually happened rather than from the plan.

**Revision 6** — no more `$N`, and no more `<angle-bracket>` placeholders inside command blocks: in a shell `<name>` is a redirect, so pasting one was a syntax error rather than a harmless substitution.

**Revision 5** — the nested lab moved ahead of Ceph, since the lab depends on Ceph for nothing except its final datastores.

**Revision 4** — Parts 1 and 3 verified on real hardware; written-in-advance text replaced with what actually happened.

**Scope:** from the R450 as it stands today, through the ZFS storage gateway, a 3-node Ceph cluster with NVMe-oF gateways, a nested vSphere cluster for testing, and on into day-2 operations and the path to production hardware.

---

# PART 0 — PLAN

## 0.1 Where you are now

| Item | Measured state |
|---|---|
| `esxi8-dell-r450` | ESXi 8.0.3 build 25595708 (8.0 U3k), standalone |
| `vcenter803` | vCenter 8.0 U3k, a VM on this host, PNID = `100.66.69.110` |
| CPU | 2 packages &middot; 16 cores &middot; 32 threads &middot; 2 NUMA nodes |
| **Memory** | **68,144,345,088 B = 63.5 GiB usable** — the number that shapes this build |
| Storage controller | `vmhba0` HBA355i Front, driver `lsi_msgpt35` (no RAID capability) |
| Disks | 3 &times; 3.7 TB SSD (data) + 2 &times; 447 GB SSD (boot, local VMFS), all `Is SSD: true` |
| Networking | Existing vSwitches and port groups — **not to be changed** |
| Everything else | Not yet built |

### Disk identifiers

| Device | Size | Role |
|---|---|---|
| `naa.5002538f43408f24` | 3815447 MB | ZFS pool member 1 |
| `naa.5002538f43408a4a` | 3815447 MB | ZFS pool member 2 |
| `naa.5002538f43408f46` | 3815447 MB | ZFS pool member 3 |
| `naa.5ace42e0255b6515` | 457862 MB | boot / local VMFS |
| `naa.5ace42e0255b6516` | 457862 MB | boot / local VMFS |

### Local datastores (measured)

| Datastore | Size | Free | Sits on | Holds |
|---|---|---|---|---|
| `sys-ssd` | 319 GiB | 309 GiB | boot SSD, the space left after OSDATA and the bootbanks | **storage gateway OS disk, RDM mapping files, ISOs** |
| `vca-ssd` | 447 GiB | 383 GiB | the whole second 447 GB SSD | `vcenter803` |
| OSDATA | 119.75 GiB | — | boot SSD | ESXi system partition, not a datastore you use |

Re-confirm the device behind each one before you write to it:

```
esxcli storage filesystem list
vmkfstools -P /vmfs/volumes/sys-ssd
vmkfstools -P /vmfs/volumes/vca-ssd
```

**Placement rule for this build:**

- `vca-ssd` → `vcenter803` only. It already carries the appliance's 64 GB of thin VMDKs, which grow.
- `sys-ssd` → the storage gateway's OS disk (80 GB as built), the three RDM mapping files (a few KB each — the data lives on the 3.7 TB SSDs), and any ISOs.

The nested ESXi hosts and their test VMs do **not** go here. They go on `r450-zfs-lab`, the NFS datastore the gateway serves back (3.7), which is the whole reason the gateway is built before the lab.

Neither SSD is mirrored. `sys-ssd` shares its physical device with the ESXi boot partitions, so losing that SSD costs you the hypervisor install **and** the storage gateway's OS disk and RDM mappings in one go. The ZFS data survives — it is on the other three disks — but you rebuild the mappings. Section 10.6 covers that recovery.

`vca-ssd` has 383 GiB free and vCenter is thin-provisioned. Do not park anything else there "because there is room": an appliance that cannot grow its logs wedges in ways that are tedious to unpick.

### vSwitch and uplink map

| vSwitch | Uplink | Speed | Carries |
|---|---|---|---|
| vSwitch0 | vmnic7 | 1 Gb | Management Network — vmk0 `192.168.221.198`, office + iDRAC |
| **vSwitch1** | **vmnic3** | **10 Gb** | VLAN 2001 — `vlan.2001` (vmk2) and `vlan.2001-infa` (VMs) |
| vswitch2 | vmnic2 | 10 Gb | VLAN 2002 — `vlan.2002`; `vlan.210` and `vlan.42` idle |
| vSwitchBMC | vusb0 | — | host &harr; iDRAC |

VLAN 2001 rides a 10 Gb X710 port, so Ceph on separate hardware has bandwidth to work with. Both X710 ports are committed, one per vSwitch; the only spare link is vmnic6 (1 Gb), which could serve as a standby uplink if you ever want redundancy on VLAN 2001. vmnic0/1 and vmnic4/5 are link-down.

## 0.2 Hard constraints

These shape every decision that follows:

1. **No changes to the R450's switching.** No new vSwitch, no new port group, no security-policy edit. The lab attaches to `vlan.2001-infa` and `vlan.2002` as they are.
2. **No DNS.** Name resolution is `/etc/hosts` on every node, both directions.
3. **No internet on the management plane.** Only VMs with a VLAN 2002 leg reach the outside.
4. **VLAN 2001 has no gateway.** Everything on it is on-link.
5. **The HBA355i cannot do RAID.** Redundancy for the three 3.7 TB SSDs comes from ZFS inside a VM.
6. **The R450 has 63.5 GiB of RAM.** Running Ceph as VMs here would need roughly 128 GB, so **the three Ceph nodes go on separate hardware.** That was the fallback; the memory figure makes it the plan.

## 0.3 Design decisions

| # | Decision | Reason |
|---|---|---|
| D1 | R450 stays a **standalone host**, never in an HA cluster | vSphere HA disables VM autostart, and the storage gateway must autostart before its datastore |
| D2 | `vcenter803` lives alone on **`vca-ssd`**; everything else on **`sys-ssd`** | The management plane stays up when Ceph is down, and a thin-provisioned appliance never competes for space |
| D3 | Name resolution by hosts file, enforced by a guard on vCenter | Two vCenter patches already failed on missing entries |
| D4 | vCenter keeps its **IP identity**; its canonical name is the IP | Changing the PNID later means certificate regeneration |
| D5 | Nested VMkernel ports take **their own vNIC's MAC** | Makes a zero-change lab possible — no promiscuous mode needed |
| D6 | Nested guest VMs get a **fifth vNIC on `vlan.2002`** | That port group already permits promiscuous mode and forged transmits, so guest networking needs no change to the R450 (4.1) |
| D7 | Ceph = 3 nodes on **separate hardware**, colocated NVMe-oF gateways, 3 load-balancing groups | The R450's 63.5 GiB cannot host them, and separate machines give a real failure domain |
| D8 | Future R630s are **end-of-line on vSphere 8** | Broadwell-EP CPUs are deprecated in 8.0 and discontinued in the next major release |

## 0.4 Inventory and addressing

| Node | VLAN 2001 — `100.66.69.0/24` | VLAN 2002 — `100.66.66.0/24` | Role |
|---|---|---|---|
| `esxi8-dell-r450` | vmk2 `.101` | — | Standalone ESXi host |
| `vcenter803` | `.110` | — | vCenter appliance |
| `stor-gw01` | `.105` | `.105` | ZFS storage gateway, NFS server, NTP source |
| `lab-esxi01` | `.121` mgmt · `.131` vMotion · `.141` NVMe A · `.151` NVMe B | — | Nested ESXi |
| `lab-esxi02` | `.122` · `.132` · `.142` · `.152` | — | Nested ESXi |
| `lab-esxi03` | `.123` · `.133` · `.143` · `.153` | — | Nested ESXi |
| `ceph01` | `.201` | `.201` | Ceph MON/MGR/OSD + NVMe-oF gateway |
| `ceph02` | `.202` | `.202` | Ceph MON/MGR/OSD + NVMe-oF gateway |
| `ceph03` | `.203` | `.203` | Ceph MON/OSD + NVMe-oF gateway |
| `lab-vm01–03` | — | — | Test VMs, no network |
| Management desktop | `.198` | `.198` | Your workstation, on-link in both VLANs |
| *(future)* `esxi8x2-dell-r630` | `.102` | — | Production cluster host |
| *(future)* `esxi8x3-dell-r630` | `.103` | — | Production cluster host |

Reading the nested addresses: the tens digit is the function, the last digit is the host. `.142` is always NVMe path A on `lab-esxi02`.

Confirm free before starting: `.105`, `.121–.123`, `.131–.133`, `.141–.143`, `.151–.153`, `.201–.203` on VLAN 2001; `.105`, `.201–.203` on VLAN 2002. Reserve a block on VLAN 2001 for the R630s' future vMotion and NVMe ports.

### Existing port groups, used as-is

| Purpose | Port group | vSwitch | VLAN |
|---|---|---|---|
| Every VM NIC on `100.66.69.0/24` | `vlan.2001-infa` | vSwitch1 | 2001 |
| Every VM NIC on `100.66.66.0/24` | `vlan.2002` | vswitch2 | 2002 |
| R450's own NFS client | `vlan.2001` → vmk2 | vSwitch1 | 2001 |

### Placeholders

| Placeholder | Meaning |
|---|---|
| `SVC_GW` | Gateway on `100.66.66.0/24` — the internet path |
| `SVC_DNS` | Internet-capable DNS server reachable from VLAN 2002 |

## 0.5 Memory budget on the R450

63.5 GiB usable, and everything has to fit inside it.

| Item | RAM | Reserved |
|---|---|---|
| ESXi hypervisor overhead | ~5 GiB | — |
| `vcenter803` | 16 GB | no |
| `stor-gw01` | 12 GB (ZFS ARC capped at 6 GB) | **yes** |
| `lab-esxi01`&ndash;`03` | 8 GB each = 24 GB | **yes** |
| **Total** | **~57 GiB** | ~6 GiB headroom |

**Audit the host before sizing.** `vim-cmd vmsvc/getallvms` on the R450 lists everything registered, including VMs that predate this plan. Anything not in the table above spends the ~6 GiB of headroom, so either delete it or confirm it stays powered off while the lab runs.

8 GB is the floor for ESXi 8 and leaves each nested host room for one 2 GB test VM. If that feels too tight, build **two** nested hosts at 12 GB instead of three: HA still works with two, and every Ceph-side test is unaffected.

CPU is comfortable. 16 cores across 2 NUMA nodes, and with the gateways on separate hardware the R450 no longer loses cores to SPDK polling. Keep every VM at 4 vCPU or fewer so it stays inside one NUMA node.

## 0.6 Sequence

| Part | Work | Gate before continuing |
|---|---|---|
| 1 | R450 and vCenter baseline, name resolution | `vc-health.sh` clean |
| 2 | Storage gateway VM, NFS datastores, NTP | Both datastores mounted, `smartctl` shows real serials |
| 3 | Nested ESXi hosts, application VLAN, vCenter cluster, test VMs | vmk0–vmk3 reachable on every host, `vmnic4` active, `VCLOUD` formed, HA and DRS on, test VMs running |
| 4 | Ceph cluster — three nodes, OSDs, pools | `HEALTH_OK`, 6 OSDs up/in, class `ssd` |
| 5 | NVMe-oF gateways, subsystem, namespaces | 3 gateways, 6 namespaces, 2 per load-balancing group |
| 6 | ESXi integration — connect, datastores, migrate | 6 controllers per host, block size 512, test VMs on Ceph |
| 5 | Test plan | All tests run and recorded |
| 6–8 | Performance, operations, maintenance | Adopted as routine |
| 9 | Production hardware | — |

**Why the lab comes before Ceph.** Nothing in Parts 4.1–4.9 needs Ceph: the nested hosts boot from `r450-zfs-lab`, and HA and DRS need only *some* shared datastore, which 3.6 provides from the storage gateway. Ceph needs three machines that may not be racked yet, and blocking the whole build on them buys nothing. Build the lab, prove the VMkernel-MAC design works, then bring Ceph in underneath it. The reverse order also works if the hardware is already sitting there — Parts 5 and 6 have no dependency on Part 4 either. Only Part 7 needs both sides to exist.

## 0.7 Build status

Verified on the hardware, 2026-10-05. **The platform is built end to end, and live migration is proven.**

| Part | State | Evidence |
|---|---|---|
| 1 — R450 host preparation | **Done** | ESXi 8.0.3 build 25595708 standalone; SSH, shell and hosts entries persist across reboot |
| 2 — vCenter preparation | **Done** | `vcenter803` on `vca-ssd`, PNID `100.66.69.110`, hosts guard enabled |
| 3 — Storage gateway | **Done** | `vzfspool` ONLINE, raidz1, ashift 12, 7.14 TiB available; both NFS datastores mounted; cold-boot test passed |
| 4 — Nested lab nodes | **Done** | All three built, rebooted, verified and in `VCLOUD`. Application VLAN on `vmnic4` active on all three. vMotion proven `02 → 03` and back |
| 5 — Ceph cluster | **Done** | `HEALTH_OK`, 3 mons in quorum, 6 OSDs class `hdd`, 1.2 TiB raw, pools `nvmeof-cfg` and `vmfs-flash` on `hdd-rule` |
| 6 — NVMe-oF gateways | **Done** | Three gateways running 1.7.23; six listeners; six namespaces at 512 B, two per load-balancing group |
| 7 — VMware integration | **Done** | Six controllers and six VMFS-6 datastores on **all three** hosts, ANA spread two per gateway, both fabrics carrying I/O |
| 8–12 | Ready to start | Every test in Part 8 can run |
| 13 — Scaling out | Written, not yet exercised | Procedures for `lab-esxi04` and `ceph04`; no fourth node built yet |

**Live cluster identity**

```
fsid           95a0da75-bd77-11f1-95e8-bc24116c2f18
mons           ceph01, ceph02, ceph03
mgr            ceph01.szccct active, ceph02.ulsaze standby
OSDs           6, class hdd, 1.2 TiB raw, MAX AVAIL 390 GiB
pools          .mgr (1 pg) | nvmeof-cfg (32 pg) | vmfs-flash (128 pg, size 3 / min_size 2)
CRUSH rule     hdd-rule
subsystem NQN  nqn.2016-06.io.spdk:lab01.gw-lab
namespaces     ds01–ds06, 40 GiB each, 512 B, two per load-balancing group
listeners      100.66.69.201-203:4420
host NQNs      nqn.2014-08.local.vsphere:nvme:lab-esxi01
               nqn.2014-08.local.vsphere:nvme:lab-esxi02
               nqn.2014-08.local.vsphere:nvme:lab-esxi03
vCenter        DC-DEV / VCLOUD, three hosts connected
```

**Measured on the three nested hosts, 2026-10-04**

| | `lab-esxi01` | `lab-esxi02` | `lab-esxi03` |
|---|---|---|---|
| vmk0 management | `100.66.69.121` | `100.66.69.122` | `100.66.69.123` |
| vmk1 vMotion | `100.66.69.131` | `100.66.69.132` | `100.66.69.133` |
| vmk2 NVMe path A | `100.66.69.141` | `100.66.69.142` | `100.66.69.143` |
| vmk3 NVMe path B | `100.66.69.151` | `100.66.69.152` | `100.66.69.153` |
| NVMe adapters | vmhba65 / vmhba66 | vmhba65 / vmhba66 | vmhba65 / vmhba66 |
| Controllers | 6 | 6 | 6 |
| Application VLAN | `vmnic4` active | `vmnic4` active | `vmnic4` active |

`vmkping -S vmotion` succeeds between all three on the `vmotion` stack. All six `lab-nvme-ds0*` datastores are mounted on all three hosts at **39.75 GB** each. The live platform reached that size by growing from 25 GiB on 2026-10-05 (10.5); from Revision 15 the build path creates them at 40 GiB directly.

**Live migration is proven.** A running VM moved `lab-esxi02 → lab-esxi03` and back with no interruption, after both hosts were rebooted. Before the reboot the same migration failed with `Networking stack mismatch` while every configuration check passed — 4.1 Condition 4, and E48.

**The Part 3 gate passed in full.** The R450 was power-cycled with nothing pinned by hand: ZFS imported on its own, both datastores returned accessible, and `vcenter803` powered itself on within the 90-second delay. That is the condition under which the rest of the build is safe to continue — if a later change breaks it, fix it before adding anything on top.

**The Part 4 design is proven, with one correction.** On `lab-esxi01` every VMkernel port took its own vNIC's MAC, and all three reachable addresses answered from `stor-gw01`:

| VMkernel | MAC | vNIC | Netstack |
|---|---|---|---|
| vmk0 `100.66.69.121` | `00:0c:29:88:d8:b1` | vmnic0 | defaultTcpipStack |
| vmk1 `100.66.69.131` | `00:0c:29:88:d8:bb` | vmnic1 | **vmotion** |
| vmk2 `100.66.69.141` | `00:0c:29:88:d8:c5` | vmnic2 | defaultTcpipStack |
| vmk3 `100.66.69.151` | `00:0c:29:88:d8:cf` | vmnic3 | defaultTcpipStack |

Nested ESXi is running with four VMkernel ports on a production port group, with no promiscuous mode, no forged transmits, and nothing added to the R450's switching. **What Revision 9 missed** is that the three vSwitches were created with their uplinks in Standby and no Active adapter — invisible to every check in that revision, and fatal to NVMe/TCP. See 4.1.

**The Part 7 result.** After fixing the failover policy, `lab-esxi01` connected six controllers across two fabrics, with ANA ownership spread two namespaces per gateway and `Blocks Written` 0.3% apart across the two paths. All of it survived a reboot with no intervention.

Measured at handover:

```
vzfspool  10.9T raw / 7.14T available   ashift=12   raidz1   autotrim=on
  ata-Samsung_SSD_870_EVO_4TB_S751NX0W401187E
  ata-Samsung_SSD_870_EVO_4TB_S751NX0W402074E
  ata-Samsung_SSD_870_EVO_4TB_S751NX0W402083T

r450-zfs-ds01  →  100.66.69.105:/vzfspool/pro
r450-zfs-lab   →  100.66.69.105:/vzfspool/lab
```

---

# PART 1 — DELL R450 ESXi 8 HOST PREPARATION

> **Runs on:** `esxi8-dell-r450` (100.66.69.101) only.
> Every command block in this part is labelled with the host it belongs to. Check the shell prompt before pasting.

This part prepares the physical host that carries everything else: vCenter, the storage gateway VM and the three nested lab hosts. Nothing here creates or modifies a vSwitch, a port group or a security policy — the R450's existing switching is treated as read-only throughout.

## 1.1 Re-confirm the host after any change

The baseline in 0.1 came from these commands. Re-run them after firmware updates or patches and compare:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
vmware -vl
esxcli hardware cpu global get
esxcli hardware memory get
esxcli storage core adapter list
esxcli storage core device list | grep -E "Display Name|Size|Is SSD"
esxcli network nic list
esxcli storage filesystem list
```

All five disks and the NIC map must match 0.1. A missing disk or a NIC that dropped to a lower speed is the first thing to explain.

## 1.2 Existing networking — confirm only, never change

Nothing to create. The map is in 0.1; confirm it and the VLAN 2001 path:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli network vswitch standard list | grep -E "Name:|Uplinks:"
esxcli network vswitch standard portgroup list
vmkping -I vmk2 100.66.69.110
vmkping -I vmk2 100.66.69.198
```

`vmk2` is the only R450 VMkernel port in `100.66.69.0/24`, so all NFS traffic uses it automatically. It sits on vSwitch1 behind a 10 Gb uplink, which is also the path every byte of NVMe/TCP traffic will take once Ceph is on separate hardware.

**One thing to record while you are here**, because Part 4 depends on it. Print the uplink failover policy of the port group the nested hosts' vNICs will sit on:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli network vswitch standard portgroup policy failover get -p vlan.2001-infa
```

You are reading, not changing. What matters is that `Active Adapters` is populated. A port group whose uplink sits in `Standby` with nothing active still passes ordinary IP traffic, which is exactly why this condition is so easy to miss — see the failure in 4.3 for what it costs.

## 1.3 R450 baseline

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli system settings advanced set -o /Power/CpuPolicy -s "High Performance"

esxcli system coredump file list
esxcli system coredump partition get
```

At least one core dump target must be active, or a purple-screen crash leaves nothing to diagnose.

Set the BIOS as in Part 9.1 at the next reboot window; the power policy above only takes effect if the BIOS hands control to the OS.

SSH, the ESXi Shell and their timeouts are handled in 1.5, which also makes them survive a reboot.

## 1.4 Name resolution

There is no DNS anywhere in this design. Every name that resolves does so from a hosts file, and every hosts file has to be maintained by hand. This section is the single source of truth for what those files contain.

### The master list

```
100.66.69.110  vcenter803.vsphere.local vcenter803
100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450
100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.121  lab-esxi01.vsphere.local lab-esxi01
100.66.69.122  lab-esxi02.vsphere.local lab-esxi02
100.66.69.123  lab-esxi03.vsphere.local lab-esxi03
100.66.69.201  ceph01.vsphere.local ceph01
100.66.69.202  ceph02.vsphere.local ceph02
100.66.69.203  ceph03.vsphere.local ceph03
```

On **vCenter itself**, its own line must read `100.66.69.110  100.66.69.110 vcenter803.vsphere.local vcenter803` — canonical name first as the IP, because a reverse lookup of the PNID becomes the directory's Kerberos identity.

Only management addresses get names; `.13x–.15x` are used by IP only.

### Where each copy lives

| Host | Mechanism | Section |
|---|---|---|
| `esxi8-dell-r450` | `/etc/rc.local.d/local.sh` at boot | 1.5 |
| `vcenter803` | `hosts-guard` systemd service + path unit | 2.1 |
| `lab-esxi01/02/03` | `/etc/rc.local.d/local.sh` at boot | 4.3.7 |
| `ceph01/02/03` | `/etc/hosts`, written once; nothing regenerates it | 5.2–5.4 |
| Management desktop | `C:\Windows\System32\drivers\etc\hosts` or `/etc/hosts`, by hand | — |

Only the Ceph nodes can be edited directly and left alone. On ESXi and on vCenter the file is regenerated, and an edit made with `vi` is lost at the next boot.

## 1.5 SSH, ESXi Shell and `/etc/hosts` persistence

**Found during the live build, on every ESXi host including this one.** After a reboot three things were gone: SSH had stopped, the ESXi Shell had stopped, and every hosts entry added by hand had disappeared.

### Why

| Thing lost | Cause |
|---|---|
| SSH | The service policy defaults to *Start and stop manually*, so it does not start at boot |
| ESXi Shell | A separate service from SSH, with the same default. SSH is the network login; ESXi Shell is the local console (DCUI, Alt+F1) |
| Both, after a while | `ESXiShellTimeOut` and `ESXiShellInteractiveTimeOut` are non-zero by default and switch them off again |
| `/etc/hosts` entries | On ESXi 8 the file carries the header *"Do not modify this file directly, please use esxcli"* and is **regenerated from ConfigStore at every boot**. `vi` only changes the running copy |

`/sbin/auto-backup.sh` does **not** rescue the hosts entries. It saves ConfigStore to the boot bank, and manual hosts lines were never in ConfigStore to begin with.

### Step A — make SSH and the ESXi Shell persistent

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i 0
esxcli system settings advanced set -o /UserVars/ESXiShellInteractiveTimeOut -i 0
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1

/sbin/auto-backup.sh
```

| Command | What it does |
|---|---|
| `enable_ssh` | Sets the SSH service policy to *Start and stop with host*, so it starts at boot |
| `start_ssh` | Starts SSH now |
| `enable_esx_shell` | Same policy change for the local console shell |
| `start_esx_shell` | Starts the ESXi Shell now |
| `ESXiShellTimeOut 0` | Removes the timer that switches SSH and the shell back off |
| `ESXiShellInteractiveTimeOut 0` | Stops idle sessions being closed |
| `SuppressShellWarning 1` | Hides the "SSH is enabled" banner |
| `auto-backup.sh` | Writes the configuration to the boot bank |

In the Host Client under **Actions → Services**, the menu shows the action available, so **"Disable Secure Shell (SSH)"** means SSH is currently running. That reads backwards the first time.

### Step B — re-apply the hosts entries at every boot

`/etc/rc.local.d/local.sh` runs at the end of boot, *after* `/etc/hosts` has been regenerated. Re-adding the entries there is the only thing that survives.

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
vi /etc/rc.local.d/local.sh
```

Insert this **above** the file's final `exit 0` — anything after `exit 0` never runs:

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

How it works, and why the same block is correct on all four ESXi hosts:

- `add()` takes the IP as `$1` and the short name as `$2`.
- `grep -qw "$2" /etc/hosts` asks whether that name is already present.
- If it is absent, the line is appended. If it is present, nothing happens.
- That guard is what makes the block **identical on every host**: each host's own name is already in the regenerated file, so its own `add` line is a no-op rather than a duplicate.

These are the only two `$` signs in this part, and they are the shell function's own positional arguments — not placeholders to substitute.

### Step C — permissions, dry run, save

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
chmod +x /etc/rc.local.d/local.sh
sh /etc/rc.local.d/local.sh
cat /etc/hosts
/sbin/auto-backup.sh
```

Running the script by hand proves it works without waiting for a reboot. `auto-backup.sh` is what carries `local.sh` itself into the boot bank — skip it and the script is gone at the next boot, which looks identical to the original problem.

### Step D — reboot and verify

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
reboot
```

After it comes back:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'
```

### If it does not work

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
head -5 /etc/rc.local.d/local.sh
grep -i local.sh /var/log/syslog.log
esxcli system settings kernel list -o execInstalledOnly
cat /etc/rc.local.d/local.sh
```

| Check | What you are looking for |
|---|---|
| `head -5` | First line must be `#!/bin/sh` |
| `grep local.sh syslog.log` | Evidence the script ran at boot |
| `execInstalledOnly` | If enabled, it can block the script from executing |
| `cat` | The `add` lines must be **above** `exit 0` |

### What did not work, and why it is worth recording

| Attempt | Why it failed |
|---|---|
| Editing `/etc/hosts` with `vi` | The file is regenerated at boot from ConfigStore |
| `auto-backup.sh` straight after that edit | Manual hosts lines are not held in ConfigStore, so there is nothing to back up |
| `grep -q lab-esxi01 /etc/hosts` on its own | A test that writes nothing. It returns a status and changes no file |

### Ongoing

- Run `/sbin/auto-backup.sh` before any deliberate power-off or reset, on every ESXi host.
- When a node is added or an address changes, edit the `add` lines and run `auto-backup.sh` again.
- If vCenter ever applies a Host Profile, it can override the SSH policy. Confirm **Host → Configure → Services → SSH** still reads *Start and stop with host*.

**Gate for Part 1:** the host matches 0.1, `vmkping` from `vmk2` reaches vCenter and the gateway, a core dump target is active, and after a reboot SSH is up and `/etc/hosts` holds all nine entries.

---

# PART 2 — vCENTER PREPARATION

> **Runs on:** `vcenter803` (100.66.69.110).
> The appliance shell is reached by SSH to 100.66.69.110, then typing `shell` at the `Command>` prompt.

`vcenter803` lives on the R450's local `vca-ssd` datastore and depends on nothing else in this build. It is prepared before the nested hosts exist so that each one can be added to a cluster as soon as it is built.

The single hardest thing about a vCenter with no DNS is that the appliance keeps rewriting the file that makes names work. 2.1 deals with that permanently.

## 2.1 The hosts guard — keeping `/etc/hosts` alive without DNS

The appliance regenerates `/etc/hosts` on network or hostname changes, and a patch may too. This guard restores missing entries at boot before any vCenter service starts, and within a second of any rewrite.

SSH to vCenter, type `shell`, then:

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
cp /etc/hosts /etc/hosts.bak-$(date +%F)
mkdir -p /usr/local/sbin

cat > /usr/local/sbin/hosts-guard.sh <<'EOF'
#!/bin/bash
# hosts-guard: keep required /etc/hosts entries on a DNS-less vCenter.
# Idempotent — only writes when an entry is missing.
HOSTS=/etc/hosts
REQUIRED=(
  "127.0.0.1      localhost.localdomain"
  "127.0.0.1      localhost"
  "100.66.69.110  100.66.69.110 vcenter803.vsphere.local vcenter803"
  "100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450"
  "100.66.69.105  stor-gw01.vsphere.local stor-gw01"
  "100.66.69.121  lab-esxi01.vsphere.local lab-esxi01"
  "100.66.69.122  lab-esxi02.vsphere.local lab-esxi02"
  "100.66.69.123  lab-esxi03.vsphere.local lab-esxi03"
  "100.66.69.201  ceph01.vsphere.local ceph01"
  "100.66.69.202  ceph02.vsphere.local ceph02"
  "100.66.69.203  ceph03.vsphere.local ceph03"
)
for entry in "${REQUIRED[@]}"; do
  read -r ip name _ <<<"$entry"
  if ! awk -v ip="$ip" -v n="$name" '$1==ip { for (i=2;i<=NF;i++) if ($i==n) f=1 } END { exit !f }' "$HOSTS"; then
    echo "$entry" >> "$HOSTS"
    logger -t hosts-guard "restored: $entry" 2>/dev/null || true
  fi
done
exit 0
EOF
chmod 755 /usr/local/sbin/hosts-guard.sh

cat > /etc/systemd/system/hosts-guard.service <<'EOF'
[Unit]
Description=Ensure required /etc/hosts entries (DNS-less vCenter)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hosts-guard.sh

[Install]
WantedBy=sysinit.target
EOF

cat > /etc/systemd/system/hosts-guard.path <<'EOF'
[Unit]
Description=Re-apply required /etc/hosts entries when the file changes

[Path]
PathChanged=/etc/hosts
Unit=hosts-guard.service

[Install]
WantedBy=paths.target
EOF

systemctl daemon-reload
systemctl enable --now hosts-guard.service hosts-guard.path
cat /etc/hosts
getent hosts localhost
getent hosts 100.66.69.110
```

**Add every future node to `REQUIRED`**, not just to `/etc/hosts`. The guard is a custom addition: a major upgrade or a file-based restore won't carry it over, so reinstall it afterwards.

### While you are at it — the management desktop

Nothing resolves from your own workstation either. Append the master list from 1.4 to `C:\Windows\System32\drivers\etc\hosts` (as Administrator) or to `/etc/hosts`. This is a manual, one-off edit; nothing regenerates it.

## 2.2 vCenter baseline

**Sizing.** Power off, set **4 vCPU / 16 GB**, no reservation, no limit. Ample for ~200 VMs; vCenter only reapportions memory at boot.

**Password expiry.** Both of these expire by default and lock you out at the worst time:

- vCenter root: 90 days — **VAMI → Administration → Password expiration settings**
- `administrator@vsphere.local`: SSO policy, 90 days — **vSphere Client → Administration → Single Sign On → Configuration → Local Accounts**

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
chage -l root
```

**File-based backup.** VAMI → Backup → Configure, daily, retain 7, to an SFTP target reachable from `100.66.69.110`. Run **Backup Now** once and confirm success. A restore rebuilds the appliance without the hosts guard — reinstall it afterwards.

**Timezone:** VAMI → Time → Asia/Dhaka. NTP comes in Part 2.

**Certificates:** record every expiry from **Administration → Certificates → Certificate Management** in the calendar in 12.6.

**Health script:**

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
cat > /usr/local/sbin/vc-health.sh <<'EOF'
#!/bin/bash
# vc-health: quick vCenter health check for a DNS-less appliance
NAMES="localhost 100.66.69.110 esxi8-dell-r450 stor-gw01 lab-esxi01 lab-esxi02 lab-esxi03 ceph01 ceph02 ceph03"

echo "== Name resolution =="
for n in $NAMES; do
  getent hosts "$n" >/dev/null && echo "OK    $n" || echo "FAIL  $n"
done

echo "== Resolver miss speed (must be < 1 s) =="
( time getent hosts no-such-name.test ) 2>&1 | awk '/real/ {print "      " $2}'

echo "== Stopped services (normal: vmcam imagebuilder netdumper rbd-watchdog vcha) =="
service-control --status --all 2>/dev/null | sed -n '/^Stopped:/,/^[A-Z]/p' | grep -v '^Running' | tail -n +2

echo "== Partitions at 80% or more =="
df -h --output=pcent,target | awk 'NR>1 { p=$1; sub("%","",p); if (p+0 >= 80) print "WARN  " $1 "  " $2 }'

echo "== Root password =="
chage -l root | grep "Password expires"

echo "== hosts-guard =="
systemctl is-enabled hosts-guard.service hosts-guard.path 2>/dev/null
journalctl -t hosts-guard --since "-7 days" --no-pager 2>/dev/null | tail -5
EOF
chmod 755 /usr/local/sbin/vc-health.sh
/usr/local/sbin/vc-health.sh
```

Run it daily and always before a patch. Any `FAIL` or `WARN` is a stop sign.

A slow resolver miss means a DNS server is configured but unreachable; remove it in **VAMI → Networking**. Every miss then waits for a timeout, which shows up as slow logins and a sluggish UI.

## 2.3 Datacenter and cluster objects

Create these **now, empty**, before any nested host exists. They are vCenter objects and need no hosts; having them ready means each host can be added the moment it is built, rather than batching it at the end.

> **Object names in this build.** The live platform uses datacenter **`DC-DEV`** and cluster **`VCLOUD`**. Earlier revisions of this guide said `DC-LAB` and `CL-LAB`; those names were never applied and have been replaced throughout with what actually exists.

### Datacenter

**vSphere Client → Hosts and Clusters → right-click `vcenter803` → New Datacenter**

| Setting | Value |
|---|---|
| Name | `DC-DEV` |

A separate datacenter for lab objects means teardown is one delete, and nothing lab-related ever appears alongside production inventory.

### Cluster

**Right-click `DC-DEV` → New Cluster**

| Setting | Value at creation | Why |
|---|---|---|
| Name | `VCLOUD` | |
| vSphere DRS | **Off** | Turned on in 4.8, after vMotion is proven |
| vSphere HA | **Off** | Same — HA with no shared datastore produces noise, not protection |
| vSAN | **Off** | Not used; Ceph over NVMe-oF is the storage |
| Manage all hosts in the cluster with a single image | **Untick** | vLCM images do not apply to nested hosts and will block you from moving them in |

Leaving HA and DRS off at creation is deliberate. Enabling them before the hosts have storage means every host you add immediately raises configuration alarms about missing heartbeat datastores and insufficient failover resources, and you learn to ignore alarms — which is the opposite of what a lab is for.

That last row is the one that bites. **"Manage all hosts in the cluster with a single image" is ticked by default in vSphere 8**, and an image-managed cluster will refuse hosts whose build it cannot reconcile.

### EVC

**`VCLOUD` → Configure → VMware EVC → Edit**

Set **Intel "Broadwell" Generation** to mirror the future R630 cluster, so a VM built in the lab has the same CPU feature mask it will have in production.

Nested hosts expose a CPU model that the EVC wizard may refuse. If it does, leave EVC disabled and record it in the findings log (8.4) as a lab artefact. The consequence is narrow — vMotion between nested hosts still works because they all present the same masked CPU from the same physical R450 — but it does mean the lab is not exercising EVC itself.

### Licensing

Everything here runs on evaluation licences:

| Object | Licence | Expires |
|---|---|---|
| `vcenter803` | Evaluation or your existing vCenter key | Record the date |
| `lab-esxi01/02/03` | 60-day evaluation, counted from **each host's own install date** | Record each date |
| `esxi8-dell-r450` | Your production key | — |

The three nested hosts will expire on three different days. Put all three in the expiry calendar (12.6) — an expired evaluation licence disconnects the host from vCenter, and the symptom looks like a connectivity fault, not a licensing one.

## 2.4 Skip Cluster Quickstart — and why

As soon as the cluster exists, vCenter offers **Configure → Quickstart**, a three-card workflow ending in a **Configure cluster** button. **Do not run it.** Click **SKIP QUICKSTART** at the top right of that panel.

### What it would do

Quickstart's "Configure cluster" step builds a **vSphere Distributed Switch** and migrates the hosts' VMkernel adapters onto it, consuming `vmnic0`–`vmnic4` as DSwitch uplinks. On this platform that would:

- dismantle `vSw-vMotion`, `vSw-NVMeA`, `vSw-NVMeB` and `vSwitch2`, and take `vmk0`–`vmk3` with them;
- discard the **MAC-matching** that lets nested VMkernel ports live on an untouched production port group (4.1);
- discard the `NVMeTCP` tags and the **active-uplink failover policy** — the exact condition whose absence cost an afternoon of the live build;
- very likely drop management connectivity to each nested host partway through, since `vmk0` migrates while the uplink it rides on is being reassigned.

A vDS is a good design on physical hosts. On nested ESXi, where the whole point is that each VMkernel port carries its own vNIC's MAC on a port group you are not allowed to modify, it is the wrong tool.

Quickstart also would not set the three `das.*` advanced options that HA needs here (4.8), so even its non-networking output would be incomplete.

### What the panel says, and what it means

| Card | Shows | Meaning |
|---|---|---|
| 1. Cluster basics | "No selected services" | HA and DRS are off. Correct at this stage |
| 2. Add hosts | "Not configured hosts: 3" | Quickstart has not run its workflow against them. Harmless |
| 3. Configure cluster | CONFIGURE button | The trap. Skip it |

Clicking **SKIP QUICKSTART** dismisses the panel permanently for that cluster and replaces it with the ordinary Configure view. Everything after this point is configured by hand, in 4.9.

## 2.5 vSphere Cluster Services (vCLS)

Within a few minutes of creating the cluster, two or three VMs named `vCLS-<uuid>` appear in it, powered on, that nobody created.

**These are expected. Leave them alone.** Do not delete, rename, power off, or reconfigure them. vCenter manages their whole lifecycle — delete one and it returns; power one off and vCenter powers it back on and raises an alarm.

| Property | Value |
|---|---|
| What they are | The cluster control plane for DRS, running independently of vCenter |
| Size | 1 vCPU, ~128 MB RAM, a small thin disk each |
| Count | Up to three per cluster |
| Why you might see only two | A vCLS VM cannot be placed on a host in **maintenance mode** — the third appears once all hosts are out |

### Pin their datastore before you start testing

vCenter picks a datastore for them without asking, which is how `lab-nvme-ds06` acquired roughly 750 MB on this build before any test VM existed.

**`VCLOUD` → Configure → vSphere Cluster Services → Datastores → Edit**, and allow only **`lab-nvme-ds01`**.

This matters for Part 8 rather than for now. T3 kills a gateway daemon and T4 takes a storage path offline. If a vCLS VM happens to be sitting on the datastore you are disrupting, DRS starts behaving oddly mid-test and you cannot tell a real result from vCLS thrashing. Pinning them somewhere known removes that variable in advance.

Confirm where they actually are:

```
# ===== RUN ON: any nested host =====
ls -la /vmfs/volumes/lab-nvme-ds01/ | grep -i vCLS
ls -la /vmfs/volumes/lab-nvme-ds06/ | grep -i vCLS
```

**Gate for Part 2:** `vc-health.sh` clean apart from the not-yet-built nodes, backup configured and run once, both password expiries dealt with, `hosts-guard` enabled, `DC-DEV` and `VCLOUD` created and empty, Quickstart skipped, and vCLS pinned to `lab-nvme-ds01`.

---

# PART 3 — STORAGE GATEWAY VM (`stor-gw01`)

The HBA355i presents raw disks. ZFS inside this VM provides the redundancy, and NFS hands it back to the R450.

## 3.1 VM specification

| Setting | Value |
|---|---|
| Name | `stor-gw01` |
| Datastore | **`sys-ssd`** — not `vca-ssd`, which is reserved for `vcenter803` (0.1) |
| CPU / RAM | 4 vCPU / **12 GB**, **reserve all guest memory** |
| Disk 1 | **80 GB thin, LSI Logic SAS** (as built; 64 GB is enough, 80 GB leaves room for logs and a local `zfs send` staging file) |
| Disks 2–4 | Physical RDMs of the three 3.7 TB SSDs, one PVSCSI controller each, **Independent — Persistent** |
| NIC 1 (VMXNET3) | `vlan.2002` → `100.66.66.105`, default gateway, internet |
| NIC 2 (VMXNET3) | `vlan.2001-infa` → `100.66.69.105`, NFS and NTP |

The full memory reservation is not optional: if ESXi balloons memory away from ZFS, the ARC and the balloon driver fight and the result looks exactly like failing storage.

## 3.2 Create the physical RDMs

On the R450, **before installing the guest**:

Everything below goes on **`sys-ssd`** (309 GiB free). `vca-ssd` stays reserved for `vcenter803` — see 0.1. Confirm the name is still what you expect:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli storage filesystem list
```

Your three data disks are already identified (0.1). Confirm they are still the 3815447 MB devices and that none of them carries a datastore:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli storage core device list | grep -B8 "Size: 3815447"
esxcli storage filesystem list
```

Then create the mappings:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
mkdir -p /vmfs/volumes/sys-ssd/rdm

vmkfstools -z /vmfs/devices/disks/naa.5002538f43408f24 \
  /vmfs/volumes/sys-ssd/rdm/data1.vmdk
vmkfstools -z /vmfs/devices/disks/naa.5002538f43408a4a \
  /vmfs/volumes/sys-ssd/rdm/data2.vmdk
vmkfstools -z /vmfs/devices/disks/naa.5002538f43408f46 \
  /vmfs/volumes/sys-ssd/rdm/data3.vmdk
```

`-z` is **physical** compatibility mode: SCSI commands pass through, so the guest sees real models, serials, SMART and TRIM. Never `-r` here.

Confirm each mapping points where you think it does before attaching anything:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
ls -lh /vmfs/volumes/sys-ssd/rdm/
vmkfstools -q /vmfs/volumes/sys-ssd/rdm/data1.vmdk
vmkfstools -q /vmfs/volumes/sys-ssd/rdm/data2.vmdk
vmkfstools -q /vmfs/volumes/sys-ssd/rdm/data3.vmdk
```

`-q` prints the physical device behind the mapping. Each must name the matching `naa.` identifier from 0.1.

### Attaching them to the VM

**Power `stor-gw01` off first.** Each RDM wants its own PVSCSI controller, and a SCSI controller cannot be added to a running VM — this is the step that is easy to skip and then spend twenty minutes wondering why the guest sees only its OS disk.

1. Power off `stor-gw01`.
2. **Edit Settings → Add hard disk → Existing hard disk** → browse `sys-ssd` → `rdm/data1.vmdk`.
3. Expand that disk: **Virtual Device Node → New SCSI controller**, then set the new controller's type to **VMware Paravirtual**. Disk mode → **Independent — Persistent**.
4. Repeat for `data2.vmdk` and `data3.vmdk`, each on its own new PVSCSI controller.
5. Leave SCSI controller 0 as LSI Logic SAS — that is the OS disk, and PVSCSI on a boot disk buys nothing here.
6. Power on.

**If `vmkfstools -z` refuses**, stop. The fallback is plain VMDKs on per-disk VMFS datastores, and in that case use `mdadm` rather than ZFS — ZFS's error handling assumes it can see the real device.

## 3.3 Install Debian 13

Base system plus SSH server only. Then:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
apt update && apt -y full-upgrade
apt -y install open-vm-tools sudo curl gnupg vim smartmontools
systemctl enable --now open-vm-tools
timedatectl set-timezone Asia/Dhaka
```

`/etc/network/interfaces` (match names from `ip -br link`):

```
auto lo
iface lo inet loopback

auto ens160
iface ens160 inet static
    address 100.66.66.105/24
    gateway SVC_GW
    dns-nameservers SVC_DNS

auto ens192
iface ens192 inet static
    address 100.66.69.105/24
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
systemctl restart networking
ping -c1 100.66.69.101 && ping -c1 100.66.69.198
```

Your desktop is on-link in both VLANs, so no extra routing is needed.

## 3.4 OpenZFS

ZFS lives in `contrib`, which is not enabled by default. Debian 13 ships **either** the deb822 layout **or** the legacy `sources.list`, depending on how the installer wrote it — a netinst install typically leaves the legacy file, so handle both:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
  sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources
else
  cp /etc/apt/sources.list /etc/apt/sources.list.bak-$(date +%F)
  sed -i -E '/^deb/ s/ main non-free-firmware/ main contrib non-free-firmware/' /etc/apt/sources.list
fi

grep -hE '^(deb |Components:)' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null
```

The `^deb` anchor keeps the edit off the commented-out `cdrom:` line, which already carries `contrib` in a different word order and would otherwise gain it twice.

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
apt update
apt -y install linux-headers-amd64 gdisk parted
DEBIAN_FRONTEND=noninteractive apt -y install zfsutils-linux zfs-dkms zfs-zed

apt-cache policy zfs-dkms        # Candidate: must be a version, not (none)
modprobe zfs
zfs version
dkms status
```

`gdisk` and `parted` are not on a minimal Debian install and you will want them in 3.6.

**Set the ARC cap before regenerating the initramfs**, not after — the module options are baked into the boot image:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
echo "options zfs zfs_arc_max=6442450944" > /etc/modprobe.d/zfs.conf   # 6 GB of the VM's 12 GB
update-initramfs -u -k all
echo 6442450944 > /sys/module/zfs/parameters/zfs_arc_max                # applies immediately
cat /sys/module/zfs/parameters/zfs_arc_max
reboot
```

The live default happens to be the same number — ZFS takes half of RAM, and half of 12 GB is 6 GB — so a missing cap looks correct today and stops being correct the moment the VM is resized.

**Record this for Part 12:** `dkms status` lists the kernels ZFS has been built against. After any kernel upgrade, confirm it rebuilt **before** rebooting. If it did not, the pool will not import at boot and the R450 loses both NFS datastores at once.

## 3.5 Verify physical passthrough

**This checkpoint proves the RDMs worked.**

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
lsblk -o NAME,SIZE,ROTA,MODEL,SERIAL,TRAN
smartctl -a /dev/sdb | head -30
lsblk -D
```

You must see **real drive models and serial numbers**. Anything showing `VMware Virtual disk` is a virtual-mode RDM — recreate it with `-z`. Non-zero `DISC-GRAN`/`DISC-MAX` confirms TRIM reaches the SSDs.

If `ROTA` shows 1 on any SSD:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
cat > /etc/udev/rules.d/60-ssd-nonrot.rules <<'EOF'
ACTION=="add|change", KERNEL=="sd[b-d]", ATTR{queue/rotational}="0"
EOF
udevadm control --reload && udevadm trigger
```

## 3.6 Pool and datasets

Always use `/dev/disk/by-id/`; device letters change across reboots.

### First: are the disks actually blank?

These drives came out of a Proxmox ZFS pool, and ZFS's own partition signature survives everything short of a deliberate wipe. A `sdX1` partition of nearly the full size next to an 8 MB `sdX9` is that signature — if you see it, the old labels are still there.

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA
zpool import                      # lists importable pools WITHOUT importing them
```

**Read the `zpool import` output before going further.** If it names a pool whose contents you still need, stop — the next commands destroy it.

If the old pool is genuinely disposable:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for d in sdb sdc sdd; do
  zpool labelclear -f /dev/${d}1 2>/dev/null
  sgdisk --zap-all /dev/$d
  wipefs -a /dev/$d
done

wipefs /dev/sdb /dev/sdc /dev/sdd   # no -a: lists only, expect no output
zpool import                        # expect: no pools available to import
lsblk -o NAME,SIZE,MODEL            # expect three bare disks, no partitions
```

`wipefs -a` on its own clears the primary GPT, the backup GPT at the end of the disk and the protective MBR, which is enough to leave the disks bare. `sgdisk` is belt and braces.

### Then create the pool

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
ls -l /dev/disk/by-id/ | grep -v part

zpool create -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O acltype=posixacl -O recordsize=64K \
  vzfspool raidz1 \
  /dev/disk/by-id/ata-MODEL_SERIAL1 \
  /dev/disk/by-id/ata-MODEL_SERIAL2 \
  /dev/disk/by-id/ata-MODEL_SERIAL3

zfs create vzfspool/pro
zfs create vzfspool/lab
zfs set sync=standard vzfspool/pro vzfspool/lab
zpool set autotrim=on vzfspool
systemctl enable --now zfs-scrub-monthly@vzfspool.timer
zpool status
```

Verify it came out right before building anything on it:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
zpool status                                       # must show the by-id names, not sdb/sdc/sdd
zpool list -o name,size,alloc,free,ashift
zfs list -o name,used,avail,mountpoint,recordsize,sync,compression
zpool history vzfspool
```

If `zpool status` shows `sdb`/`sdc`/`sdd`, the pool was created from the wrong paths — destroy and redo, because those names reorder across reboots and controller changes. `zpool history` is the authoritative record of every `create`, `destroy` and property change on the pool; it is the first thing to read whenever you are unsure what state the pool is in.

Measured on this build: **10.9 TiB raw, 7.14 TiB available.** `zpool list` reports raw capacity including parity, so 7.14 TiB is the number to hold against the 80% ceiling in 10.4 — a working limit of roughly 5.7 TiB.

`recordsize=64K` rather than the 128K default: VM images over NFS see smaller, more random I/O than a file server does.

**A property set on the pool root does not reach a child that has its own explicit value.** `zfs set sync=... vzfspool` changes only the root dataset if `pro` and `lab` were set individually — which they were, two commands earlier. Always confirm with `zfs get -r sync vzfspool` rather than assuming inheritance.

**Never set `sync=disabled` on a dataset holding VMs you care about.** It looks like a performance fix right up until an unclean shutdown. The one defensible exception is `vzfspool/lab`, where the contents are disposable by design — and even then it is a decision to record in the findings log, not a default.

### A note on these particular drives

The Samsung 870 EVO is a consumer SATA SSD with no power-loss protection. ESXi's NFS client issues sync writes, and with `sync=standard` ZFS honours them by writing the ZIL to the same unprotected drives. That is correct behaviour and it is slow. Expect it in the T-series latency results rather than reading it as a fault, and size production on drives with PLP.

## 3.7 NFS exports and datastores

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
apt -y install nfs-kernel-server
cat > /etc/exports <<'EOF'
/vzfspool/pro  100.66.69.101(rw,sync,no_root_squash,no_subtree_check)
/vzfspool/lab   100.66.69.101(rw,sync,no_root_squash,no_subtree_check)
EOF

mkdir -p /etc/nfs.conf.d
printf '[nfsd]\nhost=100.66.69.105\n' > /etc/nfs.conf.d/lab.conf

exportfs -ra && systemctl restart nfs-server
exportfs -v
ss -tlnp | grep ':2049'
```

`no_root_squash` is required — ESXi mounts as root. Without it the datastore mounts cleanly and then fails on VM file creation, which surfaces much later than it should.

Binding `nfsd` to `100.66.69.105` keeps the NFS server off the VLAN 2002 leg that faces the internet. It binds `nfsd` only — `mountd` and `rpcbind` still answer on every address, and NFS v3 needs both. To go further:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
printf '[mountd]\nhost=100.66.69.105\n' >> /etc/nfs.conf.d/lab.conf
systemctl restart nfs-server
ss -tlnp | grep -E ':(111|2049|20048)'
```

`rpcbind` on 111 cannot be bound this way and will still listen broadly. With no firewall in this design that is the residual exposure; it is yours to accept or not.

On the R450:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli storage nfs add -H 100.66.69.105 -s /vzfspool/pro -v r450-zfs-ds01
esxcli storage nfs add -H 100.66.69.105 -s /vzfspool/lab  -v r450-zfs-lab
esxcli storage nfs list
esxcli network ip connection list | grep ':2049'
```

The connection list should show local address `100.66.69.101` — proof the mounts use vmk2. `Vmknic: None` in `esxcli storage nfs list` is normal for NFS v3: there is no port binding, so the traffic follows the routing table, and vmk2 is the only VMkernel port in that subnet.

**Prove the write path.** A successful mount does not prove `no_root_squash` took:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
touch /vmfs/volumes/r450-zfs-lab/.wtest  && rm /vmfs/volumes/r450-zfs-lab/.wtest  && echo LAB-OK
touch /vmfs/volumes/r450-zfs-ds01/.wtest && rm /vmfs/volumes/r450-zfs-ds01/.wtest && echo PROD-OK
```

Both must print. A permission error here means the squash setting did not apply, and it is far better to find that now than halfway through a nested ESXi install.

## 3.8 NTP source for everything

`stor-gw01` boots first and has internet on its VLAN 2002 leg:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
apt -y install chrony
cat > /etc/chrony/conf.d/serve-lab.conf <<'EOF'
allow 100.66.69.0/24
allow 100.66.66.0/24
local stratum 10
EOF
systemctl restart chrony
chronyc sources -v
```

Point the rest at it:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli system ntp set --server=100.66.69.105 --enabled=true      # on the R450
esxcli system ntp get
```

vCenter: **VAMI → Time → NTP**, server `100.66.69.105`.

Time matters more than it looks: Ceph warns at 50 ms of monitor drift, and SSO tokens fail on skewed hosts. For production, move this role to a dedicated source rather than a storage VM.

## 3.9 Alerting

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
apt -y install mailutils prometheus-node-exporter
```

`/etc/zfs/zed.d/zed.rc`:

```
ZED_EMAIL_ADDR="you@example.com"
ZED_EMAIL_PROG="mail"
ZED_NOTIFY_VERBOSE=1
ZED_NOTIFY_INTERVAL_SECS=3600
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
systemctl restart zfs-zed
zpool scrub vzfspool          # verify an alert actually arrives
```

`/etc/smartd.conf` — SMART works here precisely because these are physical RDMs:

```text
/dev/sdb -a -o on -S on -s (S/../.././02|L/../../6/03) -m you@example.com
/dev/sdc -a -o on -S on -s (S/../.././02|L/../../6/03) -m you@example.com
/dev/sdd -a -o on -S on -s (S/../.././02|L/../../6/03) -m you@example.com
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
systemctl enable --now smartd
```

## 3.10 Autostart

The GUI works, but the shell is exact and scriptable. Get the VMIDs first — they are assigned per host and yours will differ:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
vim-cmd hostsvc/autostartmanager/enable_autostart true
vim-cmd vmsvc/getallvms
```

Then, substituting your own IDs:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
# replace the two IDs with the ones getallvms printed
vim-cmd hostsvc/autostartmanager/update_autostartentry STORGW_VMID "powerOn" "0"  "1" "guestShutdown" "120" "systemDefault"
vim-cmd hostsvc/autostartmanager/update_autostartentry VCENTER_VMID "powerOn" "90" "2" "guestShutdown" "300" "systemDefault"
vim-cmd hostsvc/autostartmanager/get_autostartseq
```

The argument order is: start action, start delay, start order, stop action, stop delay, wait-for-heartbeat.

| Order | VM | Start delay | Stop delay | Why |
|---|---|---|---|---|
| 1 | `stor-gw01` | 0 s | 120 s | Nothing else can start until its datastores exist |
| 2 | `vcenter803` | 90 s | 300 s | ZFS must import and NFS must export before vCenter looks for storage; vCenter shuts down slowly and killing it mid-flight is how databases corrupt |

Both VMs run VMware Tools, so `guestShutdown` works rather than falling back to a hard power-off.

Autostart works because the R450 is standalone (D1). In a vSphere HA cluster it is disabled outright, and then nothing brings `stor-gw01` up first.

### Test it with a real power cycle, now

This is the cheapest this test will ever be. Today a failure costs a manual `zpool import` and a remount. Once three nested hosts and their VMs live on `r450-zfs-lab`, the same failure means a datastore full of inaccessible VMs.

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
reboot
```

After it comes back:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
zpool status                        # on stor-gw01 — ONLINE, no errors
```

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli storage nfs list             # both datastores Accessible = true
vim-cmd vmsvc/power.getstate VCENTER_VMID       # expect: Powered on
```

What is actually being tested is whether ZFS imports and NFS exports *before* vCenter starts looking for storage. The 90 seconds is an estimate; this is what tells you it is enough. **Verified on this build — all three came back without intervention.**

**Gate:** both datastores mounted, `smartctl` shows real serials, `chronyc sources` healthy on the R450 and vCenter.

---

# PART 4 — NESTED LAB ESXi NODE PREPARATION

> **Runs on:** `lab-esxi01` (100.66.69.121), `lab-esxi02` (100.66.69.122), `lab-esxi03` (100.66.69.123), with a few steps on `esxi8-dell-r450` and `stor-gw01`.
> Each node has its **own complete section** — 4.3, 4.4 and 4.5. Nothing in them is shared and nothing needs substituting. Work through one node from top to bottom, finish with its reboot and its gate, and only then start the next.

This part builds three nested ESXi 8 hosts on the R450 and forms them into a cluster. It needs Parts 1–3 complete and needs Ceph for nothing: the hosts boot from `r450-zfs-lab`. Shared storage arrives in Part 7, as the six Ceph datastores, and that is what HA and DRS use — there is no temporary NFS scaffold any more (see 4.8).

### The order matters, and it matters because of vMotion

Everything in this part can be done in a different order and appear to work, right up to the point where a live migration fails and nothing you can query explains why. The order below exists to stop that:

| # | Section | Step | Why it must be here |
|---|---|---|---|
| 1 | 4.3 / 4.4 / 4.5 | Build each host **completely, including its reboot** | The vMotion server binds its TCP/IP stack at vmkernel initialisation. A vMotion vmknic added to a running host is configured and not live — 4.1, Condition 4 |
| 2 | 4.6 | Cross-host network gate | `vmkping -S vmotion` between all three, while the only moving part is networking and vCenter is not yet involved |
| 3 | 4.7 | Add the hosts to vCenter | Nothing else. No cluster services, no Quickstart |
| 4 | Part 7 | Connect NVMe/TCP and create the datastores | A migration needs shared storage both ends see |
| 5 | 4.8, first half | Prove vMotion **manually**, both directions | You choose when it runs and you watch it |
| 6 | 4.8, second half | Enable HA, then DRS | DRS migrates on its own schedule. It must not be the thing that discovers a broken stack, at 2 a.m., on a VM someone cares about |

**Steps 4 and 5 are deliberately out of numeric order.** 4.8 sits next to 4.7 because they belong to the same job — finishing the cluster — but it cannot run until Part 7 has given the hosts a shared datastore. Build to 4.7, do Parts 5, 6 and 7, then come back to 4.8. The gate at the end of 4.7 says the same thing.

## 4.1 Four conditions that make this work

Nested ESXi on an untouched production port group depends on four things. The first is well known. The other three each cost a day of the live build, and none of them appears in any VMware document we could find.

### Condition 1 — VMkernel MACs match their vNICs

Nested ESXi normally needs promiscuous mode, forged transmits and MAC changes on its port group, because its VMkernel ports use MACs the outer switch has never seen. Enabling those on `vlan.2001-infa` would mean editing a production port group — the one carrying vCenter — and every frame on VLAN 2001 would be copied to each nested vNIC, including all the NFS traffic carrying the lab's disk I/O.

Instead, each nested VMkernel port is created with **the MAC address of the vNIC it rides on**, using `esxcli ... interface add -M "$(mac vmnicX)"`. The outer switch already knows that address, so frames are delivered normally and nothing is forged. `vmk0` does this by default at install; 4.3 extends it to `vmk1`–`vmk3`.

### Condition 2 — every storage vSwitch has an **active** uplink

Creating a vSwitch and adding an uplink to it does **not** guarantee the uplink becomes active. On all three nested hosts in the live build, `esxcli network vswitch standard uplink add` left the uplink in **Standby with no Active adapter at all**:

```
Active Adapters:
Standby Adapters: vmnic2
```

Ordinary IP traffic does not care. With a single uplink ESXi forwards over it regardless, so `vmkping` is clean, the route table looks right, and everything appears healthy. **NVMe/TCP does care.** ESXi resolves the software adapter's source VMkernel port by walking the uplink's portset for a VMkernel port that is both tagged `NVMeTCP` and an *active* teaming member. With no active member there is nothing to find, and `esxcli nvme fabrics connect` fails:

```
Adapter or transport target not found
```

with this in `/var/log/vmkernel.log`:

```
NVMFNET:149 Uplink: vmnic2, portset: vSw-NVMeA.
nt_ConnectCM:5167 [ctlr 265, queue 0] Failed to get source vmknic for NVMe/TCP traffic on vmnic2: Not found
```

So every `uplink add` in 4.3, 4.4 and 4.5 is immediately followed by `policy failover set --active-uplinks=`, and each node's own gate verifies it before anything tries to connect.

**What this failure is not.** Five plausible causes were eliminated before the real one was found, and all five are worth naming so nobody re-walks them:

| Ruled out | Evidence |
|---|---|
| A `vmxnet3` uplink cannot carry NVMe/TCP | False. It works once the uplink is active. The physical R450 was used as a control and connected first time — that proved the *target* was fine, not that nesting was the problem |
| The MAC override breaks tag registration | False. `vmk3` keeps its matched MAC and works. The confusing symptom — `tag remove` reporting *"Vmknic is not tagged with NVMeTCP"* while `tag get` showed the tag — was the standby uplink, not the MAC |
| A stale software adapter | `fabrics disable` / `enable` changed nothing |
| Route-table ownership of the subnet | Moving `vmk2` to its own subnet on VLAN 2002, where it owned the route outright, changed nothing |
| Two VMkernel ports in one subnet | Withdrawn as E25 — single-subnet multipathing was later proven end to end in 7.2 |

**Prove this on the first host before building the other two.** If `vmk1`–`vmk3` cannot ping at the end of 4.3, stop: the remaining fix means changing a port group, which is a decision rather than a command.

| Fallback option | Cost |
|---|---|
| Promiscuous + forged + MAC changes on `vlan.2001-infa` | Edits a production port group; floods VLAN 2001 to every nested vNIC |
| A new port group on vSwitch1, VLAN 2001, with those settings | One additive object; existing port groups untouched |

### Condition 3 — guest VMs need the outer port group's permission, and already have it

Condition 1 keeps the *VMkernel* ports legal by matching MACs. That trick cannot be applied to guest VMs: each guest has its own MAC, and there may be twenty behind one vNIC. So guest traffic behaves like traffic from a switch nested behind a port:

| Direction | What happens | What the outer port group must allow |
|---|---|---|
| Guest → network | Frame leaves `vmnic4` with the **guest's** source MAC, which the R450's vSwitch never issued | **Forged Transmits = Accept** |
| Network → guest | Reply arrives for a MAC the R450's vSwitch has no port for, so it is dropped rather than flooded | **Promiscuous Mode = Accept** |

`vlan.2002` already permits both, inherited from `vswitch2`. Verified read-only, so the hard constraint in 0.2 still holds and **nothing on the R450 changes**:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli network vswitch standard portgroup policy security get -p vlan.2002
```

```
Allow Promiscuous: true
Allow MAC Address Change: true
Allow Forged Transmits: true
Override Vswitch Allow Promiscuous: false
```

`Override … : false` means these come from `vswitch2` itself and predate this platform. **If either reads `false` on your build, stop** — changing it is a security-policy edit on a production port group, which is a decision rather than a command.

This is why each node's `vSwitch2` carries guest traffic only and has no VMkernel port on it.

**A naming risk.** The port group inside each nested host is named `vlan.2002`, identical to the R450's. Every other nested object was given a distinct name — `vSw-NVMeA`, `NVME-A` — so a command pasted into the wrong shell fails harmlessly. This one does not have that protection: `portgroup policy security set -p vlan.2002` succeeds on either layer and means something very different on each.

### Condition 4 — every host is rebooted before it joins the cluster

**A VMkernel port added to a running host is configured correctly but not fully live.** The vmkernel's vMotion server binds its TCP/IP stack when it initialises. If no vMotion vmknic existed at boot — which is always true the first time you build a host — it binds `defaultTcpipStack` and keeps that binding for the life of the boot.

Every `esxcli` command then reports a correct configuration, because the configuration *is* correct. Live migration fails anyway:

```
Failed to start migration: Networking stack mismatch.
```

and the cause appears only in the destination host's `vmkernel.log`:

```
WARNING: VMotion: failed to resolve net stack instance due to mismatch with vMotion server.
Migration instance: vmotion.  Server instance: defaultTcpipStack.
```

Restarting `hostd` is not enough — the binding is in the vmkernel. Only a reboot clears it.

So each node section ends with a mandatory reboot and a post-reboot gate, and 4.7 will not accept a host that has not had one. The cost is three minutes per host; the alternative is finding it later, when nothing you can query will tell you anything is wrong.

**The shape of Conditions 2 and 4 is the same, and worth internalising:** configured is not the same as effective. When every status command agrees and the thing still fails, the fault is in runtime state, and config commands cannot see runtime state.

## 4.2 VM specification and addressing (×3)

Install each fresh from the ISO. **Don't clone an installed ESXi** — clones share a system UUID and VMkernel MAC.

Stage the installer on `sys-ssd` first; ISOs live there per the placement rule in 0.1, while the nested hosts themselves go on `r450-zfs-lab`:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
mkdir -p /vmfs/volumes/sys-ssd/iso
# upload VMware-VMvisor-Installer-8.0U3k-25595708.x86_64.iso via the host client
ls -lh /vmfs/volumes/sys-ssd/iso/
```

| Setting | Value |
|---|---|
| Names | `lab-esxi01`, `lab-esxi02`, `lab-esxi03` |
| Datastore | `r450-zfs-lab` |
| Guest OS | Other → **VMware ESXi 8.0 or later** |
| CPU | 4 vCPU, 1 socket; **Hardware virtualization: expose to guest OS** |
| RAM | **8 GB**, **reserve all guest memory** (an ESXi guest has no balloon driver) |
| Disk | 40 GB thin, PVSCSI, **disk mode Dependent** |
| Boot | EFI, Secure Boot off |

**Disk mode is `Dependent`, not Independent.** The RDMs in Part 3 were Independent-Persistent to keep raw disks out of snapshots; this is the opposite case. An Independent disk is silently excluded from snapshots, so a snapshot taken before the VMkernel work — the cheapest rollback point this part has — would roll nothing back. The whole nested layer is also covered by a single ZFS snapshot of `vzfspool/lab` on `stor-gw01`, which is the faster option; 8.2 has it.

### Before you power it on

**Four settings do not appear on the wizard's "Ready to complete" page.** Check each one in Edit Settings before first boot; three of them are far more annoying to fix afterwards.

| Setting | Where | What goes wrong without it |
|---|---|---|
| **Expose hardware-assisted virtualization** | Edit settings → CPU → tick *Hardware virtualization* | The host installs and boots normally, then refuses to power on any 64-bit VM. The symptom appears hours after the cause |
| **Reserve all guest memory** | Edit settings → Memory → *Reserve all guest memory (All locked)* | An ESXi guest has no balloon driver. When the R450 tries to reclaim, the nested host cannot give memory back |
| **Firmware EFI, Secure Boot off** | VM Options → Boot Options | ESXi 8 often defaults Secure Boot on |
| **CD/DVD → the installer ISO, *Connect at power on*** | Edit settings → CD/DVD Drive 1 → Datastore ISO file | Boots to no media |

The wizard's IDE and SATA controllers are defaults. Harmless — leave them.

### Addresses — every value used in 4.3, 4.4 and 4.5

All four vNICs sit on the existing `vlan.2001-infa` port group. Nothing new is created on the R450.

| vNIC | Port group | Nested vmnic | vSwitch | Port group (inside) | VMkernel | `lab-esxi01` | `lab-esxi02` | `lab-esxi03` |
|---|---|---|---|---|---|---|---|---|
| 1 | `vlan.2001-infa` | vmnic0 | `vSwitch0` | `Management Network` | **vmk0** — management | `100.66.69.121` | `100.66.69.122` | `100.66.69.123` |
| 2 | `vlan.2001-infa` | vmnic1 | `vSw-vMotion` | `vMotion` | **vmk1** — vMotion | `100.66.69.131` | `100.66.69.132` | `100.66.69.133` |
| 3 | `vlan.2001-infa` | vmnic2 | `vSw-NVMeA` | `NVME-A` | **vmk2** — NVMe path A | `100.66.69.141` | `100.66.69.142` | `100.66.69.143` |
| 4 | `vlan.2001-infa` | vmnic3 | `vSw-NVMeB` | `NVME-B` | **vmk3** — NVMe path B | `100.66.69.151` | `100.66.69.152` | `100.66.69.153` |
| 5 | `vlan.2002` | vmnic4 | `vSwitch2` | `vlan.2002` | *(none — guest traffic only)* | — | — | — |

Netmask is `255.255.255.0` everywhere. There is no default gateway on VLAN 2001.

The tens digit is the function, the last digit is the host: `.142` is always NVMe path A on `lab-esxi02`. Every address in 4.3, 4.4 and 4.5 is already written out from this table — you should never need to substitute anything.

The fifth vNIC carries guest application traffic and has **no VMkernel port** — the nested host itself has no address on VLAN 2002 and needs none. Its `vSwitch2` is built in each node's `.4` subsection alongside the others; the permissions it depends on are Condition 3 in 4.1.

### Where these names actually come from

Nothing in the outer VM wizard sets `vmnic0`–`vmnic3` or `vmk0`–`vmk3`. The "Nested vmnic" column above is a mapping to **verify**, not to configure.

| Name | Created by | When |
|---|---|---|
| `vmnic0`–`vmnic3` | The nested ESXi kernel, from PCI slot order | At install. Network adapter 1 → `vmnic0`, 2 → `vmnic1`, and so on |
| `vmk0`, label *Management Network* | The ESXi installer / DCUI | When you pick the management uplink and type the address |
| `vmk1`–`vmk3` | The commands in 4.3 | The `-i vmk1` argument **is** the name |
| Port groups `vMotion`, `NVME-A`, `NVME-B` | The commands in 4.3 | `portgroup add -p NVME-A` creates the label |
| vSwitches `vSw-vMotion`, `vSw-NVMeA`, `vSw-NVMeB` | The commands in 4.3 | Inside the nested host — not objects on the R450 |

**Do not use the host client's *Add VMkernel NIC* for vmk1–vmk3.** It generates a fresh random MAC, which is exactly what this design avoids. Only `esxcli` accepts `-M`.

8 GB is the floor for ESXi 8 and fits the R450's memory budget (0.5). If you would rather have more room per host, build **two** nested hosts at 12 GB — HA works with two, and nothing on the Ceph side changes.

## 4.3 `lab-esxi01` — complete node build

> **Every command in this section runs on `lab-esxi01` (100.66.69.121).**
> Nothing here is shared with another host. Work top to bottom, finish with the reboot, and do not move to the next node until this one's verification passes.

### 4.3.1 Install and first boot

Install from the ISO staged in 4.2. At the DCUI: management on **vmnic0**, **no default gateway**, no DNS, IPv6 off. Everything is on-link; if the DCUI insists on a gateway, enter `100.66.69.105`. Enable SSH.

| Setting | Value |
|---|---|
| Management address | `100.66.69.121/24` |
| Netmask | `255.255.255.0` |
| Gateway | none — or `100.66.69.105` if the DCUI refuses to proceed |

### 4.3.2 Confirm the vmnic order

This decides whether every `-u vmnicN` argument below is correct. VMXNET3 adapters normally enumerate in order, but if they did not, vMotion would land on an NVMe path while everything still appeared to work.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli network nic list
```

Compare the five MAC addresses against this VM's Network adapters 1–5 in the R450 host client. Adapter 1's MAC must be `vmnic0`'s. They are all `00:0c:29:xx` or `00:50:56:xx`, so compare the last three octets. **Stop and remap the uplink arguments if they do not match.**

### 4.3.3 Identity and time

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli system hostname set --host=lab-esxi01 --domain=vsphere.local
esxcli system ntp set --server=100.66.69.105 --enabled=true
/sbin/generate-certificates
esxcli system hostname get
```

### 4.3.4 vSwitches, uplinks and failover policy

**The `policy failover set` line after each `uplink add` is not optional.** `uplink add` can leave the NIC in Standby with no Active adapter, which passes ordinary IP traffic and breaks NVMe/TCP — see 4.1.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli network ip netstack list
esxcli network ip netstack add -N vmotion
esxcli network ip netstack list

esxcli network vswitch standard add -v vSw-vMotion
esxcli network vswitch standard uplink add -v vSw-vMotion -u vmnic1
esxcli network vswitch standard policy failover set -v vSw-vMotion --active-uplinks=vmnic1
esxcli network vswitch standard portgroup add -v vSw-vMotion -p vMotion

esxcli network vswitch standard add -v vSw-NVMeA
esxcli network vswitch standard uplink add -v vSw-NVMeA -u vmnic2
esxcli network vswitch standard policy failover set -v vSw-NVMeA --active-uplinks=vmnic2
esxcli network vswitch standard portgroup add -v vSw-NVMeA -p NVME-A

esxcli network vswitch standard add -v vSw-NVMeB
esxcli network vswitch standard uplink add -v vSw-NVMeB -u vmnic3
esxcli network vswitch standard policy failover set -v vSw-NVMeB --active-uplinks=vmnic3
esxcli network vswitch standard portgroup add -v vSw-NVMeB -p NVME-B

esxcli network vswitch standard add -v vSwitch2
esxcli network vswitch standard uplink add -v vSwitch2 -u vmnic4
esxcli network vswitch standard policy failover set -v vSwitch2 --active-uplinks=vmnic4
esxcli network vswitch standard portgroup add -v vSwitch2 -p vlan.2002
```

**Stop here and check all four.** Each must show an Active Adapter and an empty Standby list:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done
```

### 4.3.5 VMkernel ports

The only `$` signs here are the helper function's own argument and the substitution that reads each vNIC's real MAC. **That substitution is why this lab needs no promiscuous mode** (4.1) — do not replace it with a typed-in address.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
mac() { esxcli network nic list | grep -w "$1" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}'; }

# vMotion — its own TCP/IP stack
esxcli network ip interface add -i vmk1 -p vMotion -N vmotion -M "$(mac vmnic1)"
esxcli network ip interface ipv4 set -i vmk1 -t static -I 100.66.69.131 -N 255.255.255.0

# NVMe/TCP path A — port-bound to vmnic2
esxcli network ip interface add -i vmk2 -p NVME-A -M "$(mac vmnic2)"
esxcli network ip interface ipv4 set -i vmk2 -t static -I 100.66.69.141 -N 255.255.255.0
esxcli network ip interface tag add -i vmk2 -t NVMeTCP

# NVMe/TCP path B — port-bound to vmnic3
esxcli network ip interface add -i vmk3 -p NVME-B -M "$(mac vmnic3)"
esxcli network ip interface ipv4 set -i vmk3 -t static -I 100.66.69.151 -N 255.255.255.0
esxcli network ip interface tag add -i vmk3 -t NVMeTCP
```

**No VMkernel port goes on `vSwitch2`.** It carries guest traffic only; this host has no address on VLAN 2002 and does not need one.

**Count the ports — do not just read their attributes.** `lab-esxi03` once reached the cluster with `vmk1` entirely absent while every port-group check passed:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"
```

**Four rows**, at `100.66.69.121`, `100.66.69.131`, `100.66.69.141` and `100.66.69.151`. Each vmk's MAC must equal its vmnic's, and `vmk1` must show netstack `vmotion`.

### 4.3.6 NVMe/TCP adapters and the host NQN

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli nvme fabrics enable --protocol TCP --device vmnic2
esxcli nvme fabrics enable --protocol TCP --device vmnic3
esxcli nvme adapter list
esxcli nvme info get
```

Two software adapters, one bound to `vmnic2` (path A) and one to `vmnic3` (path B). **Write down which is which and the Host NQN** — they are consumed in 7.1, and the `vmhba` numbers are not guaranteed to match other hosts.

The names are derived from the vmnic MAC, so they survive reboots. They do change if you `fabrics disable` and re-enable, so re-read `adapter list` after any such cycle.

### 4.3.7 SSH, ESXi Shell and `/etc/hosts` persistence

Without this, a reboot loses SSH, the ESXi Shell and every manual hosts entry. The reasoning is in 1.5.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i 0
esxcli system settings advanced set -o /UserVars/ESXiShellInteractiveTimeOut -i 0
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1

/sbin/auto-backup.sh
```

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
vi /etc/rc.local.d/local.sh
```

Insert this **above** the final `exit 0` — anything after `exit 0` never runs. The `grep -qw` guard makes this host's own line a no-op rather than a duplicate, which is why the block is identical on every host:

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

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
chmod +x /etc/rc.local.d/local.sh
sh /etc/rc.local.d/local.sh
cat /etc/hosts
/sbin/auto-backup.sh
```

### 4.3.8 Reboot — mandatory, before this host goes anywhere near vCenter

**This is not optional and it is not only a persistence test.**

A VMkernel port added to a running host is configured correctly but **not fully live**. The vmkernel's vMotion server binds its TCP/IP stack when it initialises, and if no vMotion vmknic existed at boot it binds `defaultTcpipStack` and keeps that binding. Every `esxcli` command then reports a correct configuration while live migration fails with:

```
Failed to start migration: Networking stack mismatch.
```

The cause only appears in `vmkernel.log`:

```
WARNING: VMotion: failed to resolve net stack instance due to mismatch with vMotion server.
Migration instance: vmotion.  Server instance: defaultTcpipStack.
```

Rebooting now costs three minutes. Finding this later costs an afternoon, because nothing you can query will tell you the configuration is wrong — it is not.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
/sbin/auto-backup.sh
reboot
```

### 4.3.9 Post-reboot verification — the gate for this node

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'

esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"

for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done

esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
esxcli nvme adapter list
esxcli nvme info get
```

Everything must still be true after the reboot:

- [ ] nine entries in `/etc/hosts`, no duplicates
- [ ] `SSH` and `ESXShell` both `on`
- [ ] four VMkernel ports: `100.66.69.121`, `100.66.69.131`, `100.66.69.141`, `100.66.69.151`
- [ ] `vmk1` on netstack `vmotion`; each vmk's MAC equal to its vmnic's
- [ ] all four port groups with an Active Adapter and empty Standby
- [ ] `NVMeTCP` on `vmk2` and `vmk3`
- [ ] two NVMe adapters, Host NQN recorded

Reachability, using `stor-gw01` as the peer since it is up regardless of which other hosts exist yet:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
vmkping -I vmk0 -d -s 1472 100.66.69.110
vmkping -I vmk2 -d -s 1472 100.66.69.105
vmkping -I vmk3 -d -s 1472 100.66.69.105
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.121 100.66.69.141 100.66.69.151; do
  ping -c2 -W2 $ip >/dev/null && echo "$ip OK" || echo "$ip FAIL"
done
```

`vmk1` has no peer until a second nested host exists; 4.6 tests it across hosts.

**This node is done.** Start the next one.


## 4.4 `lab-esxi02` — complete node build

> **Every command in this section runs on `lab-esxi02` (100.66.69.122).**
> Nothing here is shared with another host. Work top to bottom, finish with the reboot, and do not move to the next node until this one's verification passes.

### 4.4.1 Install and first boot

Install from the ISO staged in 4.2. At the DCUI: management on **vmnic0**, **no default gateway**, no DNS, IPv6 off. Everything is on-link; if the DCUI insists on a gateway, enter `100.66.69.105`. Enable SSH.

| Setting | Value |
|---|---|
| Management address | `100.66.69.122/24` |
| Netmask | `255.255.255.0` |
| Gateway | none — or `100.66.69.105` if the DCUI refuses to proceed |

### 4.4.2 Confirm the vmnic order

This decides whether every `-u vmnicN` argument below is correct. VMXNET3 adapters normally enumerate in order, but if they did not, vMotion would land on an NVMe path while everything still appeared to work.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli network nic list
```

Compare the five MAC addresses against this VM's Network adapters 1–5 in the R450 host client. Adapter 1's MAC must be `vmnic0`'s. They are all `00:0c:29:xx` or `00:50:56:xx`, so compare the last three octets. **Stop and remap the uplink arguments if they do not match.**

### 4.4.3 Identity and time

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli system hostname set --host=lab-esxi02 --domain=vsphere.local
esxcli system ntp set --server=100.66.69.105 --enabled=true
/sbin/generate-certificates
esxcli system hostname get
```

### 4.4.4 vSwitches, uplinks and failover policy

**The `policy failover set` line after each `uplink add` is not optional.** `uplink add` can leave the NIC in Standby with no Active adapter, which passes ordinary IP traffic and breaks NVMe/TCP — see 4.1.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli network ip netstack list
esxcli network ip netstack add -N vmotion
esxcli network ip netstack list

esxcli network vswitch standard add -v vSw-vMotion
esxcli network vswitch standard uplink add -v vSw-vMotion -u vmnic1
esxcli network vswitch standard policy failover set -v vSw-vMotion --active-uplinks=vmnic1
esxcli network vswitch standard portgroup add -v vSw-vMotion -p vMotion

esxcli network vswitch standard add -v vSw-NVMeA
esxcli network vswitch standard uplink add -v vSw-NVMeA -u vmnic2
esxcli network vswitch standard policy failover set -v vSw-NVMeA --active-uplinks=vmnic2
esxcli network vswitch standard portgroup add -v vSw-NVMeA -p NVME-A

esxcli network vswitch standard add -v vSw-NVMeB
esxcli network vswitch standard uplink add -v vSw-NVMeB -u vmnic3
esxcli network vswitch standard policy failover set -v vSw-NVMeB --active-uplinks=vmnic3
esxcli network vswitch standard portgroup add -v vSw-NVMeB -p NVME-B

esxcli network vswitch standard add -v vSwitch2
esxcli network vswitch standard uplink add -v vSwitch2 -u vmnic4
esxcli network vswitch standard policy failover set -v vSwitch2 --active-uplinks=vmnic4
esxcli network vswitch standard portgroup add -v vSwitch2 -p vlan.2002
```

**Stop here and check all four.** Each must show an Active Adapter and an empty Standby list:

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done
```

### 4.4.5 VMkernel ports

The only `$` signs here are the helper function's own argument and the substitution that reads each vNIC's real MAC. **That substitution is why this lab needs no promiscuous mode** (4.1) — do not replace it with a typed-in address.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
mac() { esxcli network nic list | grep -w "$1" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}'; }

# vMotion — its own TCP/IP stack
esxcli network ip interface add -i vmk1 -p vMotion -N vmotion -M "$(mac vmnic1)"
esxcli network ip interface ipv4 set -i vmk1 -t static -I 100.66.69.132 -N 255.255.255.0

# NVMe/TCP path A — port-bound to vmnic2
esxcli network ip interface add -i vmk2 -p NVME-A -M "$(mac vmnic2)"
esxcli network ip interface ipv4 set -i vmk2 -t static -I 100.66.69.142 -N 255.255.255.0
esxcli network ip interface tag add -i vmk2 -t NVMeTCP

# NVMe/TCP path B — port-bound to vmnic3
esxcli network ip interface add -i vmk3 -p NVME-B -M "$(mac vmnic3)"
esxcli network ip interface ipv4 set -i vmk3 -t static -I 100.66.69.152 -N 255.255.255.0
esxcli network ip interface tag add -i vmk3 -t NVMeTCP
```

**No VMkernel port goes on `vSwitch2`.** It carries guest traffic only; this host has no address on VLAN 2002 and does not need one.

**Count the ports — do not just read their attributes.** `lab-esxi03` once reached the cluster with `vmk1` entirely absent while every port-group check passed:

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"
```

**Four rows**, at `100.66.69.122`, `100.66.69.132`, `100.66.69.142` and `100.66.69.152`. Each vmk's MAC must equal its vmnic's, and `vmk1` must show netstack `vmotion`.

### 4.4.6 NVMe/TCP adapters and the host NQN

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli nvme fabrics enable --protocol TCP --device vmnic2
esxcli nvme fabrics enable --protocol TCP --device vmnic3
esxcli nvme adapter list
esxcli nvme info get
```

Two software adapters, one bound to `vmnic2` (path A) and one to `vmnic3` (path B). **Write down which is which and the Host NQN** — they are consumed in 7.1, and the `vmhba` numbers are not guaranteed to match other hosts.

The names are derived from the vmnic MAC, so they survive reboots. They do change if you `fabrics disable` and re-enable, so re-read `adapter list` after any such cycle.

### 4.4.7 SSH, ESXi Shell and `/etc/hosts` persistence

Without this, a reboot loses SSH, the ESXi Shell and every manual hosts entry. The reasoning is in 1.5.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i 0
esxcli system settings advanced set -o /UserVars/ESXiShellInteractiveTimeOut -i 0
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1

/sbin/auto-backup.sh
```

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
vi /etc/rc.local.d/local.sh
```

Insert this **above** the final `exit 0` — anything after `exit 0` never runs. The `grep -qw` guard makes this host's own line a no-op rather than a duplicate, which is why the block is identical on every host:

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

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
chmod +x /etc/rc.local.d/local.sh
sh /etc/rc.local.d/local.sh
cat /etc/hosts
/sbin/auto-backup.sh
```

### 4.4.8 Reboot — mandatory, before this host goes anywhere near vCenter

**This is not optional and it is not only a persistence test.**

A VMkernel port added to a running host is configured correctly but **not fully live**. The vmkernel's vMotion server binds its TCP/IP stack when it initialises, and if no vMotion vmknic existed at boot it binds `defaultTcpipStack` and keeps that binding. Every `esxcli` command then reports a correct configuration while live migration fails with:

```
Failed to start migration: Networking stack mismatch.
```

The cause only appears in `vmkernel.log`:

```
WARNING: VMotion: failed to resolve net stack instance due to mismatch with vMotion server.
Migration instance: vmotion.  Server instance: defaultTcpipStack.
```

Rebooting now costs three minutes. Finding this later costs an afternoon, because nothing you can query will tell you the configuration is wrong — it is not.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
/sbin/auto-backup.sh
reboot
```

### 4.4.9 Post-reboot verification — the gate for this node

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'

esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"

for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done

esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
esxcli nvme adapter list
esxcli nvme info get
```

Everything must still be true after the reboot:

- [ ] nine entries in `/etc/hosts`, no duplicates
- [ ] `SSH` and `ESXShell` both `on`
- [ ] four VMkernel ports: `100.66.69.122`, `100.66.69.132`, `100.66.69.142`, `100.66.69.152`
- [ ] `vmk1` on netstack `vmotion`; each vmk's MAC equal to its vmnic's
- [ ] all four port groups with an Active Adapter and empty Standby
- [ ] `NVMeTCP` on `vmk2` and `vmk3`
- [ ] two NVMe adapters, Host NQN recorded

Reachability, using `stor-gw01` as the peer since it is up regardless of which other hosts exist yet:

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
vmkping -I vmk0 -d -s 1472 100.66.69.110
vmkping -I vmk2 -d -s 1472 100.66.69.105
vmkping -I vmk3 -d -s 1472 100.66.69.105
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.122 100.66.69.142 100.66.69.152; do
  ping -c2 -W2 $ip >/dev/null && echo "$ip OK" || echo "$ip FAIL"
done
```

`vmk1` has no peer until a second nested host exists; 4.6 tests it across hosts.

**This node is done.** Start the next one.


## 4.5 `lab-esxi03` — complete node build

> **Every command in this section runs on `lab-esxi03` (100.66.69.123).**
> Nothing here is shared with another host. Work top to bottom, finish with the reboot, and do not move to the next node until this one's verification passes.

### 4.5.1 Install and first boot

Install from the ISO staged in 4.2. At the DCUI: management on **vmnic0**, **no default gateway**, no DNS, IPv6 off. Everything is on-link; if the DCUI insists on a gateway, enter `100.66.69.105`. Enable SSH.

| Setting | Value |
|---|---|
| Management address | `100.66.69.123/24` |
| Netmask | `255.255.255.0` |
| Gateway | none — or `100.66.69.105` if the DCUI refuses to proceed |

### 4.5.2 Confirm the vmnic order

This decides whether every `-u vmnicN` argument below is correct. VMXNET3 adapters normally enumerate in order, but if they did not, vMotion would land on an NVMe path while everything still appeared to work.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli network nic list
```

Compare the five MAC addresses against this VM's Network adapters 1–5 in the R450 host client. Adapter 1's MAC must be `vmnic0`'s. They are all `00:0c:29:xx` or `00:50:56:xx`, so compare the last three octets. **Stop and remap the uplink arguments if they do not match.**

### 4.5.3 Identity and time

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli system hostname set --host=lab-esxi03 --domain=vsphere.local
esxcli system ntp set --server=100.66.69.105 --enabled=true
/sbin/generate-certificates
esxcli system hostname get
```

### 4.5.4 vSwitches, uplinks and failover policy

**The `policy failover set` line after each `uplink add` is not optional.** `uplink add` can leave the NIC in Standby with no Active adapter, which passes ordinary IP traffic and breaks NVMe/TCP — see 4.1.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli network ip netstack list
esxcli network ip netstack add -N vmotion
esxcli network ip netstack list

esxcli network vswitch standard add -v vSw-vMotion
esxcli network vswitch standard uplink add -v vSw-vMotion -u vmnic1
esxcli network vswitch standard policy failover set -v vSw-vMotion --active-uplinks=vmnic1
esxcli network vswitch standard portgroup add -v vSw-vMotion -p vMotion

esxcli network vswitch standard add -v vSw-NVMeA
esxcli network vswitch standard uplink add -v vSw-NVMeA -u vmnic2
esxcli network vswitch standard policy failover set -v vSw-NVMeA --active-uplinks=vmnic2
esxcli network vswitch standard portgroup add -v vSw-NVMeA -p NVME-A

esxcli network vswitch standard add -v vSw-NVMeB
esxcli network vswitch standard uplink add -v vSw-NVMeB -u vmnic3
esxcli network vswitch standard policy failover set -v vSw-NVMeB --active-uplinks=vmnic3
esxcli network vswitch standard portgroup add -v vSw-NVMeB -p NVME-B

esxcli network vswitch standard add -v vSwitch2
esxcli network vswitch standard uplink add -v vSwitch2 -u vmnic4
esxcli network vswitch standard policy failover set -v vSwitch2 --active-uplinks=vmnic4
esxcli network vswitch standard portgroup add -v vSwitch2 -p vlan.2002
```

**Stop here and check all four.** Each must show an Active Adapter and an empty Standby list:

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done
```

### 4.5.5 VMkernel ports

The only `$` signs here are the helper function's own argument and the substitution that reads each vNIC's real MAC. **That substitution is why this lab needs no promiscuous mode** (4.1) — do not replace it with a typed-in address.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
mac() { esxcli network nic list | grep -w "$1" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}'; }

# vMotion — its own TCP/IP stack
esxcli network ip interface add -i vmk1 -p vMotion -N vmotion -M "$(mac vmnic1)"
esxcli network ip interface ipv4 set -i vmk1 -t static -I 100.66.69.133 -N 255.255.255.0

# NVMe/TCP path A — port-bound to vmnic2
esxcli network ip interface add -i vmk2 -p NVME-A -M "$(mac vmnic2)"
esxcli network ip interface ipv4 set -i vmk2 -t static -I 100.66.69.143 -N 255.255.255.0
esxcli network ip interface tag add -i vmk2 -t NVMeTCP

# NVMe/TCP path B — port-bound to vmnic3
esxcli network ip interface add -i vmk3 -p NVME-B -M "$(mac vmnic3)"
esxcli network ip interface ipv4 set -i vmk3 -t static -I 100.66.69.153 -N 255.255.255.0
esxcli network ip interface tag add -i vmk3 -t NVMeTCP
```

**No VMkernel port goes on `vSwitch2`.** It carries guest traffic only; this host has no address on VLAN 2002 and does not need one.

**Count the ports — do not just read their attributes.** `lab-esxi03` once reached the cluster with `vmk1` entirely absent while every port-group check passed:

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"
```

**Four rows**, at `100.66.69.123`, `100.66.69.133`, `100.66.69.143` and `100.66.69.153`. Each vmk's MAC must equal its vmnic's, and `vmk1` must show netstack `vmotion`.

### 4.5.6 NVMe/TCP adapters and the host NQN

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli nvme fabrics enable --protocol TCP --device vmnic2
esxcli nvme fabrics enable --protocol TCP --device vmnic3
esxcli nvme adapter list
esxcli nvme info get
```

Two software adapters, one bound to `vmnic2` (path A) and one to `vmnic3` (path B). **Write down which is which and the Host NQN** — they are consumed in 7.1, and the `vmhba` numbers are not guaranteed to match other hosts.

The names are derived from the vmnic MAC, so they survive reboots. They do change if you `fabrics disable` and re-enable, so re-read `adapter list` after any such cycle.

### 4.5.7 SSH, ESXi Shell and `/etc/hosts` persistence

Without this, a reboot loses SSH, the ESXi Shell and every manual hosts entry. The reasoning is in 1.5.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

esxcli system settings advanced set -o /UserVars/ESXiShellTimeOut -i 0
esxcli system settings advanced set -o /UserVars/ESXiShellInteractiveTimeOut -i 0
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1

/sbin/auto-backup.sh
```

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
vi /etc/rc.local.d/local.sh
```

Insert this **above** the final `exit 0` — anything after `exit 0` never runs. The `grep -qw` guard makes this host's own line a no-op rather than a duplicate, which is why the block is identical on every host:

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

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
chmod +x /etc/rc.local.d/local.sh
sh /etc/rc.local.d/local.sh
cat /etc/hosts
/sbin/auto-backup.sh
```

### 4.5.8 Reboot — mandatory, before this host goes anywhere near vCenter

**This is not optional and it is not only a persistence test.**

A VMkernel port added to a running host is configured correctly but **not fully live**. The vmkernel's vMotion server binds its TCP/IP stack when it initialises, and if no vMotion vmknic existed at boot it binds `defaultTcpipStack` and keeps that binding. Every `esxcli` command then reports a correct configuration while live migration fails with:

```
Failed to start migration: Networking stack mismatch.
```

The cause only appears in `vmkernel.log`:

```
WARNING: VMotion: failed to resolve net stack instance due to mismatch with vMotion server.
Migration instance: vmotion.  Server instance: defaultTcpipStack.
```

Rebooting now costs three minutes. Finding this later costs an afternoon, because nothing you can query will tell you the configuration is wrong — it is not.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
/sbin/auto-backup.sh
reboot
```

### 4.5.9 Post-reboot verification — the gate for this node

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'

esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"

for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done

esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
esxcli nvme adapter list
esxcli nvme info get
```

Everything must still be true after the reboot:

- [ ] nine entries in `/etc/hosts`, no duplicates
- [ ] `SSH` and `ESXShell` both `on`
- [ ] four VMkernel ports: `100.66.69.123`, `100.66.69.133`, `100.66.69.143`, `100.66.69.153`
- [ ] `vmk1` on netstack `vmotion`; each vmk's MAC equal to its vmnic's
- [ ] all four port groups with an Active Adapter and empty Standby
- [ ] `NVMeTCP` on `vmk2` and `vmk3`
- [ ] two NVMe adapters, Host NQN recorded

Reachability, using `stor-gw01` as the peer since it is up regardless of which other hosts exist yet:

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
vmkping -I vmk0 -d -s 1472 100.66.69.110
vmkping -I vmk2 -d -s 1472 100.66.69.105
vmkping -I vmk3 -d -s 1472 100.66.69.105
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.123 100.66.69.143 100.66.69.153; do
  ping -c2 -W2 $ip >/dev/null && echo "$ip OK" || echo "$ip FAIL"
done
```

`vmk1` has no peer until a second nested host exists; 4.6 tests it across hosts.

**This node is done.** Start the next one.
## 4.6 Cross-host verification — the gate for Part 4

Each node passed its own gate in 4.3.9, 4.4.9 and 4.5.9. This section tests the things that need more than one host.

### vMotion across the dedicated stack

`vmk1` lives on the `vmotion` netstack, so `-S vmotion` is required. Without it the ping leaves the default stack and fails for the wrong reason.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.132
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.133
```

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.131
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.133
```

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.131
vmkping -S vmotion -I vmk1 -d -s 1472 100.66.69.132
```

All six must answer at 1472 bytes. **This proves the network, not the service** — a host whose vMotion server bound the wrong stack still pings perfectly. That only shows up in 4.8, which is why each node was rebooted in its own section.

### The vMotion stack's routing table must match on all three

Netstack routes are **separate from interface configuration**, and `esxcli network ip interface ipv4 set` does not touch them. A gateway that appears in `ipv4 get` but was never intended usually came from the DCUI and lives in the stack's route table:

```
# ===== RUN ON: each nested host in turn =====
esxcli network ip route ipv4 list -N vmotion
```

Each host should show exactly one route — `100.66.69.0/24 → vmk1` — and nothing else. If one has an extra `default` entry, remove it there:

```
# ===== RUN ON: the host with the extra route =====
esxcli network ip route ipv4 remove -N vmotion -n default -g 100.66.69.198
esxcli network ip route ipv4 list -N vmotion
```

### Gate for Part 4

- [ ] All three nodes passed their own 4.x.9 gate, **including the reboot**
- [ ] Six `vmkping -S vmotion` succeed at 1472 bytes
- [ ] All three vMotion route tables identical
- [ ] Twelve VMkernel ports total, four per host
- [ ] Twelve port groups with active uplinks, four per host
- [ ] Three Host NQNs recorded

Hosts join vCenter in 4.7. Do not add a host that has not been rebooted.

## 4.7 Add the hosts to vCenter

`DC-DEV` and `VCLOUD` were created empty in 2.3. This puts the three hosts into that cluster.

Add each host **as soon as it passes 4.6**. A host that joins cleanly on its own is one less variable when the next one does not.

### Before you click Add Host

| Check | Command | Why |
|---|---|---|
| Host answers | `ping 100.66.69.121` from vCenter | — |
| vCenter resolves name **and** IP | `getent hosts lab-esxi01` and `getent hosts 100.66.69.121` | No DNS. Entries come from `hosts-guard` (2.1); a missing one shows up later as "Not responding" |
| Clocks agree | `date` on both ends | More than a few minutes of skew fails the SSL handshake |
| Lockdown mode off | `esxcli system settings advanced list -o /Security/LockdownMode` | vCenter does not need it off, but every later section uses SSH |
| **Host has been rebooted** | — | 4.3.8. A host added before its reboot carries a vMotion server bound to the wrong stack |

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
for h in lab-esxi01 lab-esxi02 lab-esxi03 100.66.69.121 100.66.69.122 100.66.69.123; do
  getent hosts "$h" >/dev/null && echo "OK    $h" || echo "FAIL  $h"
done
date
```

Any `FAIL` means an entry is missing from `hosts-guard`'s `REQUIRED` array — fix that in 2.1, not in the Add Host wizard.

### Add Host

**Right-click `VCLOUD` → Add Hosts.**

| Wizard field | Value |
|---|---|
| Host name or IP address | `100.66.69.121`, then `.122`, `.123` — **the IP, not the name** |
| User name | `root` |
| Password | the host's root password |
| Lifecycle / image | leave as inherited; do not attach an image |

**Use the IP.** With no DNS, vCenter's managed-object name becomes whatever string you type. An IP is unambiguous and cannot drift; a short name depends on a hosts file staying correct forever.

**Verify the certificate thumbprint** rather than clicking through. These are self-signed certificates regenerated by `/sbin/generate-certificates`:

```
# ===== RUN ON: the host being added =====
openssl x509 -in /etc/vmware/ssl/rui.crt -noout -fingerprint -sha256
```

Compare with what the wizard shows, character for character.

### Immediately after each host joins

```
# ===== RUN ON: the host that just joined =====
vim-cmd hostsvc/hostsummary | grep -iE 'managementServerIp|inMaintenanceMode'
esxcli system ntp get
```

`managementServerIp` must read `100.66.69.110`. Blank means the host believes it is unmanaged and the add did not complete.

Then in the client, per host:

| Where | Value |
|---|---|
| Configure → Time Configuration | `100.66.69.105`, policy **Start and stop with host** |
| Configure → Services → SSH | **Start and stop with host** — confirm the join did not override 4.x.7 |
| Configure → Licensing | Evaluation; **record the expiry** — three hosts, three different dates |

### When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| "Cannot contact the specified host" | Name or IP not resolvable from vCenter | The `getent` loop above |
| Joins, then **Not responding** minutes later | vCenter cannot resolve the host for heartbeats, or 902 is blocked | Add the missing `hosts-guard` entry, then Connection → Reconnect |
| SSL / thumbprint error | Certificate regenerated, or clock skew | Re-read the fingerprint; check `date` on both ends |
| Disconnects at ~60 days | Evaluation licence expired | 12.6 expiry calendar |

## 4.8 Prove vMotion, then enable HA and DRS

**Order matters here and it is the point of this section.** DRS performs vMotion automatically, and HA depends on a cluster that can move workload. Enabling either before live migration is proven means the first failure is also your first test.

### Step 1 — one manual vMotion, in both directions

With all three hosts in the cluster and the Ceph datastores visible (Part 7), put a test VM on `lab-esxi01` and migrate it by hand.

**Right-click the VM → Migrate → Change compute resource only → `lab-esxi02`.**

Then migrate it back, and once more to `lab-esxi03`. Every host must work as both source **and** destination — a host whose vMotion server bound the wrong stack fails only as the destination, so a single one-way test proves nothing.

| Migration | Must succeed |
|---|---|
| `lab-esxi01` → `lab-esxi02` | ✓ |
| `lab-esxi02` → `lab-esxi01` | ✓ |
| `lab-esxi01` → `lab-esxi03` | ✓ |
| `lab-esxi03` → `lab-esxi01` | ✓ |

### If a migration fails

The Task Console says *"A general system error occurred"* and gives you a summary. The real reason is on the **destination** host:

```
# ===== RUN ON: the destination host of the failed migration =====
tail -50 /var/log/vmkernel.log | grep -iE 'net stack instance|Migration instance|VMotion'
tail -300 /var/log/hostd.log | grep -iE 'vmotion|migrat|stack'
```

| Log line | Cause | Fix |
|---|---|---|
| `Migration instance: vmotion. Server instance: defaultTcpipStack.` | That host's vMotion server bound the wrong stack because `vmk1` was created after boot | **Reboot that host** (4.3.8). `hostd` restart is not enough |
| `Failed to resolve net stack instance` with matching instances | Netstack route mismatch | 4.6 |
| Thumbprint or SSL errors | Clock skew | `date` on both hosts |

Do not proceed to Step 2 until all four migrations in the table succeed.

### Step 2 — HA and DRS

**`VCLOUD` → Configure → vSphere Availability → Edit**

| Setting | Value |
|---|---|
| vSphere HA | **Enabled** |
| Host Failure Response | **Restart VMs** |
| Admission control | Host failures cluster tolerates: **1** |
| Host Isolation Response | Power off and restart VMs |
| Datastore with PDL | Power off and restart VMs |
| Datastore with APD | Power off and restart VMs (conservative) |
| Heartbeat datastores | **Use datastores only from the specified list** → `lab-nvme-ds01` and `lab-nvme-ds02` |

Those two because `ds01` is ANA-owned by `ceph01` and `ds02` by `ceph02` (7.2), so the heartbeat is not concentrated on one gateway.

**Advanced Options**, in the same dialog:

| Key | Value | Why |
|---|---|---|
| `das.isolationaddress0` | `100.66.69.110` | vCenter, outside the cluster |
| `das.isolationaddress1` | `100.66.69.105` | `stor-gw01`, always up |
| `das.usedefaultisolationaddress` | `false` | HA's default test pings the management gateway, and `vmk0`'s gateway here is a workstation that does not route |
| `das.ignoreRedundantNetWarning` | `true` | Each nested host has one management port on one uplink. The warning is correct; this acknowledges it. **Not appropriate on the production R630s** |

**→ vSphere DRS → Edit:** Fully automated, migration threshold 3.

### What HA does and does not do

**12.11 is the full treatment** — detection, admission control, recovery and the correlated failures. The short version that matters while you are configuring it:

Worth being precise, because the two mechanisms are often conflated:

| Scenario | Mechanism | Behaviour | Downtime |
|---|---|---|---|
| **Planned** — you want to shut a host down | **DRS** + Maintenance Mode | VMs vMotion off live before the host enters maintenance | **None** |
| **Unplanned** — host crashes or loses power | **HA** | VMs die with the host, then power on again elsewhere from shared storage | Guest boot time, plus ~15–30 s detection |

**HA never moves a running VM.** For a planned shutdown always use Maintenance Mode — right-click host → Maintenance Mode → Enter, wait for it to reach "Maintenance Mode", *then* power off.

### Verify

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
/usr/local/sbin/vc-health.sh
```

```
# ===== RUN ON: each nested host =====
/etc/init.d/vmware-fdm status
```

In the client:

- **Hosts** — three **Connected**, none in maintenance mode
- **Monitor → vSphere HA → Summary** — one **master**, two **slaves**, test VMs listed as protected
- **Datastores** — six `lab-nvme-ds0*`, each showing 3 hosts
- **Summary** — no configuration alarms
- **VMs** — three `vCLS-*`, on `lab-nvme-ds01` after the pinning in 2.5

**Capacity note.** Three hosts at 8 GB with admission control tolerating one failure reserves a third of cluster memory. HA will refuse power-on operations before the hosts look full; that is admission control working, not a fault.

## 4.9 Test VMs

| Setting | Value |
|---|---|
| Names | `lab-vm01`, `lab-vm02`, `lab-vm03` |
| Datastores | `lab-nvme-ds02`…`lab-nvme-ds06` — at least one VM per load-balancing group, using the table in 7.2. Keep `lab-nvme-ds01` for vCLS |
| Size | 1 vCPU, 2 GB RAM, 16 GB thin, PVSCSI |
| Network | VMXNET3 on the nested `vlan.2002` port group, address on `100.66.66.0/24` |
| OS | Debian 13, base system only |

Upload the Debian ISO to one of the Ceph datastores — **not** to `sys-ssd`, which the nested hosts cannot reach.

Since these VMs have real networking (4.2), install `fio` and use it. Earlier revisions generated in-guest load with `dd` only, because the test VMs had no network adapter and nothing could be fetched into them:

```bash
# ===== RUN ON: each test VM =====
apt -y install fio
```

```bash
# ===== RUN ON: each test VM (lab-vm01 / lab-vm02 / lab-vm03) =====
cat > /usr/local/bin/stall-watch <<'EOF'
#!/bin/bash
# Prints a line whenever a 4k O_DIRECT|O_DSYNC write takes longer than 500 ms.
while :; do
  s=$(date +%s%N)
  dd if=/dev/zero of=/var/tmp/hb bs=4k count=1 oflag=direct,dsync 2>/dev/null
  d=$(( ($(date +%s%N) - s) / 1000000 ))
  [ "$d" -gt 500 ] && echo "$(date +%T)  stall ${d} ms"
  sleep 0.2
done
EOF
chmod 755 /usr/local/bin/stall-watch

cat > /usr/local/bin/load-loop <<'EOF'
#!/bin/bash
while :; do
  dd if=/dev/zero of=/var/tmp/load bs=1M count=2048 oflag=direct conv=notrunc 2>/dev/null
done
EOF
chmod 755 /usr/local/bin/load-loop
```

`stall-watch` is the single most useful tool in the lab: it turns "it seemed to pause" into a number.

**Every test in Part 8 can run once Part 7 is complete.**

---

# PART 5 — CEPH CLUSTER CONFIGURATION

Three nodes on separate hardware from the R450. This part builds the cluster and stops at `HEALTH_OK`. The NVMe-oF gateways are Part 6; connecting ESXi is Part 6. Nothing in Parts 5 and 6 touches the nested lab, so they can be done while someone else works on Part 3.

## 5.1 What each node is

**These nodes are KVM/QEMU virtual machines.** The measured layout, identical on all three:

| Device | Size | Role | Stable path |
|---|---|---|---|
| `sda` | 40 GB | OS — `sda1` 1 MB BIOS boot, `sda2` mounted at `/` | `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` |
| **`sdb`** | **208 GB** | **OSD 1 — leave untouched, `cephadm` claims it** | `scsi-0QEMU_QEMU_HARDDISK_drive-scsi1` |
| **`sdc`** | **208 GB** | **OSD 2 — leave untouched** | `scsi-0QEMU_QEMU_HARDDISK_drive-scsi2` |
| `sr0` | 1 GB | Virtual DVD | `ata-QEMU_DVD-ROM_QM00003` |

Confirm before touching anything:

```bash
# ===== RUN ON: each Ceph node (ceph01, ceph02, ceph03) =====
lsblk
ls -l /dev/disk/by-id/
```

`sdb` and `sdc` must have **no partitions**. If they do, they are not blank and you need to find out why before `cephadm` is allowed near them.

Note that `sdb` and `sdc` have only the `drive-scsiN` alias — no serial-based `scsi-SQEMU_…` name, because the hypervisor did not set a serial on them. That alias is tied to the VM's disk slot, so it is stable for this VM as long as nobody reorders the slots. It matters less than it would on bare metal: once an OSD exists, Ceph finds it through LVM tags, not device names.

### Capacity, and what it allows

| | |
|---|---|
| OSDs | 6 (2 per node × 3 nodes) |
| Raw | 6 × 208 GB = **1,248 GB** |
| Usable at `size=3` | **≈ 416 GB** |
| Target working ceiling (60%, per 10.4) | **≈ 250 GB** |

That sets the size of the test datastores in 6.4. **Build them at 40 GiB.**

The number to size against is Ceph's **`MAX AVAIL`**, not raw capacity — on this cluster 390 GiB against 1.2 TiB raw, because `size=3` and the full-ratio reserve both come off the top:

| Size each | Six total | % of 390 GiB MAX AVAIL | Verdict |
|---|---|---|---|
| 25 GiB | 150 GiB | 38% | what the first build used — unnecessarily small |
| **40 GiB** | **240 GiB** | **62%** | **build at this** |
| 50 GiB | 300 GiB | 77% | too far; `nearfull` starts shaping your results |

RBD images are **thin**, so these are promised figures, not consumed ones — after the live build at 40 GiB the pool still showed `STORED 1.4 GiB`. Over-provisioning is legitimate here as long as you watch `ceph df` rather than vSphere's free-space display, which will cheerfully report room while Ceph fills underneath it.

**The original build used 25 GiB and was grown to 40 GiB in place on 2026-10-05.** That worked and is fully documented in **10.5** — but there is no reason to repeat it. Build at the size you want. Keep 10.5 for the next time you genuinely need to grow, which will be when you add a seventh namespace or move past 40 GiB.

### Where these VMs run

They are **Proxmox VMs** — the `bc:24:11` MAC prefix is Proxmox's.

**Place one on each of three different Proxmox nodes.** If all three run on the same physical host, the failure domain is not what the CRUSH map believes: `size=3` across three Ceph hosts protects against one Ceph node failing, but one hypervisor failing takes all three at once and stops I/O entirely. CRUSH cannot see that, so it will not warn you.

If the placement cannot be spread, record it in the findings log (8.4) as a lab artefact, and never read a cluster-wide outage in that configuration as a Ceph result — it is a statement about the hypervisor, not about Ceph.

### CPU model and RAM — both are hard prerequisites

**The Proxmox default CPU model does not work.** `kvm64` presents a feature set that stops at `pni` (SSE3). Rocky Linux 10, which the `ceph-nvmeof` container is built on, requires **x86-64-v3** — AVX, AVX2, BMI1, BMI2 and FMA. With `kvm64` the Ceph cluster itself builds and runs perfectly, and then every NVMe-oF gateway in Part 6 lands in `error` state with nothing in `ceph -s` to explain it. The reason is only visible in the daemon log:

```
Fatal glibc error: CPU does not support x86-64-v3
```

Set each VM's CPU type to **`x86-64-v3`** (or `host`) in Proxmox *before* building the cluster. Doing it afterwards means draining and rebooting each node in turn, which is slow and entirely avoidable.

| Setting | Value | Why |
|---|---|---|
| CPU type | **`x86-64-v3`** or `host` | `ceph-nvmeof` 1.7 on Rocky 10 will not start without it |
| vCPU | 4 | SPDK's polled-mode target burns whole cores — see 6.1 |
| RAM | **16 GB** | 2 OSDs × `osd_memory_target`, plus mon/mgr, plus **8 GiB of hugepages** reserved by the gateway |

Verify on each node once the OS is installed:

```bash
# ===== RUN ON: each Ceph node (ceph01, ceph02, ceph03) =====
lscpu | grep -oE 'avx2|bmi1|bmi2|fma' | sort -u
free -h
```

All four CPU flags must be present. If `lscpu` stops at `pni`, the VM is still on `kvm64`.

### OS

Ubuntu 24.04 LTS Server, minimal, on `sda` only. Leave `sdb` and `sdc` unpartitioned during installation.

## 5.2 Build `ceph01`

Run this **only** on `ceph01`. Check the prompt first.

### Networking is configured during the Ubuntu install, not afterwards

Set both addresses in the installer. The installer writes `/etc/netplan/50-cloud-init.yaml`, and **that file is the one to keep** — there is no reason to replace it with a hand-written one.

Measured on `ceph01`, this is the shape it should have:

```yaml
network:
  version: 2
  ethernets:
    enp6s18:                          # net0 — VLAN 2002
      addresses:
      - "100.66.66.201/24"
      nameservers:
        addresses:
        - 100.66.66.1                 # SVC_DNS
        search: []
      routes:
      - to: "default"
        via: "100.66.66.1"            # SVC_GW
    enp6s19:                          # net1 — VLAN 2001
      addresses:
      - "100.66.69.201/24"
```

Two things to get right, and nothing else:

1. **Only the VLAN 2002 interface has a gateway and nameservers.** VLAN 2001 needs its connected route and nothing more — every peer there, including your desktop, is on-link. Two default routes would make the node's own outbound path a coin toss.
2. **Confirm which interface is on which VLAN on each node individually.** `enp6s18` was net0 on `ceph01`, but the name comes from the PCI slot, and if someone attached the NICs in a different order on another node, the mapping flips. `ip -br link` plus the Proxmox VM's network tab tells you; do not assume `ceph02` matches `ceph01`.

### Will anything overwrite this file?

Check once per node:

```bash
# ===== RUN ON: each Ceph node (ceph01, ceph02, ceph03) =====
cloud-init status --long
grep -rs 'network' /etc/cloud/cloud.cfg.d/
```

An Ubuntu ISO install disables cloud-init networking, and on these nodes cloud-init is off entirely (`Cloud-init disabled by /etc/cloud/cloud-init.disabled`), so nothing will rewrite the file. A VM cloned from a **Proxmox cloud-image template with a cloud-init drive attached** is the opposite case: cloud-init runs every boot and re-renders that file from the drive. If `cloud-init status` is not `disabled`, add the marker before going further:

```bash
# ===== RUN ON: each Ceph node (ceph01, ceph02, ceph03) =====
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

### Why there is no `match` or `set-name` here

Earlier revisions of this guide pinned each interface to its MAC and renamed it to `mgmt` / `svc`. On a VM that is the wrong trade.

`set-name` is cosmetic — it only makes the names read nicely. `match` is the functional half, and it binds the configuration to a MAC rather than to an interface name. The two failure modes are not equal:

| | What breaks |
|---|---|
| **No `match`** (what we use) | If PCI enumeration shifts, the two legs could swap and the node comes up on the wrong VLANs — misbehaving, but reachable |
| **`match` by MAC** | If the MAC ever changes, the stanza matches nothing and the node comes up **with no network at all** |

On bare metal, MACs are permanent and pinning is free insurance. These are Proxmox VMs, where cloning normally regenerates MACs — so pinning converts a recoverable problem into an unreachable node. The name risk is small in return: `enp6s18` and `enp6s19` are net0 and net1 at PCI slots 18 and 19, and adding a third NIC takes slot 20 without disturbing them. Only removing or reordering an existing NIC shifts the names, and that is a deliberate act.

If you ever do remove or reorder a NIC on one of these nodes, check `ip -br addr` before trusting it.

```bash
# ===== RUN ON: ceph01 (100.66.69.201) =====
# ---------- ceph01 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph01
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph01 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph01 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.201 and 100.66.66.201
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph01 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost
100.66.69.110  vcenter803.vsphere.local vcenter803
100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450
100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.121  lab-esxi01.vsphere.local lab-esxi01
100.66.69.122  lab-esxi02.vsphere.local lab-esxi02
100.66.69.123  lab-esxi03.vsphere.local lab-esxi03
100.66.69.201  ceph01.vsphere.local ceph01
100.66.69.202  ceph02.vsphere.local ceph02
100.66.69.203  ceph03.vsphere.local ceph03
EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.201

# ---------- ceph01 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph01 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph01 : verify ----------
lsblk
for ip in 100.66.69.202 100.66.69.203 100.66.69.105 100.66.69.110; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

What the non-obvious parts are for:

- **`qemu-guest-agent`**, not `open-vm-tools` — these are KVM guests.
- **No `127.0.1.1 <hostname>` line** in `/etc/hosts`. Ubuntu's installer adds one, and it makes the node resolve its own name to loopback, which confuses monitors and `cephadm`.
- **`manage_etc_hosts: false`** stops cloud-init rewriting the file on the next boot.
- **SSH on 8022** — Ubuntu 24.04 uses socket activation, so changing `Port` alone does nothing; `ssh.socket` is what must be restarted. Keep your current session open and test a new one before logging out.
- The default route goes out `svc`, for container images. VLAN 2001 needs only its connected route — every peer there, including your desktop, is on-link.
- `ping -M do -s 1472` sends a full-size frame with DF set. A reply proves the path has no MTU surprise, which is worth knowing before Ceph replicates across it.

## 5.3 Build `ceph02`

Identical to 5.2 — read the networking notes there before starting. Only the addresses and the hostname differ. Run this **only** on `ceph02`.

**Check this node's own interface-to-VLAN mapping.** The names come from PCI slots, so `enp6s18` is only VLAN 2002 here if the NICs were attached in the same order as on `ceph01`. `ip -br link` and the Proxmox VM's network tab together tell you; do not assume.

```bash
# ===== RUN ON: ceph02 (100.66.69.202) =====
# ---------- ceph02 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph02
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph02 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph02 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.202 and 100.66.66.202
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph02 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost
100.66.69.110  vcenter803.vsphere.local vcenter803
100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450
100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.121  lab-esxi01.vsphere.local lab-esxi01
100.66.69.122  lab-esxi02.vsphere.local lab-esxi02
100.66.69.123  lab-esxi03.vsphere.local lab-esxi03
100.66.69.201  ceph01.vsphere.local ceph01
100.66.69.202  ceph02.vsphere.local ceph02
100.66.69.203  ceph03.vsphere.local ceph03
EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.202

# ---------- ceph02 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph02 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph02 : verify ----------
lsblk
for ip in 100.66.69.201 100.66.69.203 100.66.69.105 100.66.69.110; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

## 5.4 Build `ceph03`

Identical to 5.2 — read the networking notes there before starting. Run this **only** on `ceph03`.

**Check this node's own interface-to-VLAN mapping** before trusting the addresses, for the reason given in 5.3.

```bash
# ===== RUN ON: ceph03 (100.66.69.203) =====
# ---------- ceph03 : hostname, time, IPv6 off ----------
hostnamectl set-hostname ceph03
timedatectl set-timezone Asia/Dhaka

cat > /etc/sysctl.d/99-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# ---------- ceph03 : packages ----------
apt update && apt -y full-upgrade
apt -y install podman lvm2 chrony python3 curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ---------- ceph03 : network — set during installation, verified here ----------
ip -br link                                  # note which MAC is on which VLAN
cat /etc/netplan/50-cloud-init.yaml          # confirm it matches the shape in 4.2
chmod 600 /etc/netplan/50-cloud-init.yaml    # netplan warns if it is world-readable
netplan generate && netplan apply
ip -br addr                                  # 100.66.69.203 and 100.66.66.203
ip route                                     # exactly ONE default, on the VLAN 2002 leg

# ---------- ceph03 : name resolution ----------
cat > /etc/hosts <<'EOF'
127.0.0.1      localhost
100.66.69.110  vcenter803.vsphere.local vcenter803
100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450
100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.121  lab-esxi01.vsphere.local lab-esxi01
100.66.69.122  lab-esxi02.vsphere.local lab-esxi02
100.66.69.123  lab-esxi03.vsphere.local lab-esxi03
100.66.69.201  ceph01.vsphere.local ceph01
100.66.69.202  ceph02.vsphere.local ceph02
100.66.69.203  ceph03.vsphere.local ceph03
EOF
echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-hosts.cfg
hostname -i                     # must print 100.66.69.203

# ---------- ceph03 : NTP from stor-gw01 ----------
sed -i -E 's/^(pool|server)/#&/' /etc/chrony/chrony.conf
echo 'server 100.66.69.105 iburst prefer' > /etc/chrony/conf.d/lab.conf
systemctl restart chrony && chronyc tracking

# ---------- ceph03 : SSH on 8022 ----------
sed -i -E 's/^#?Port .*/Port 8022/' /etc/ssh/sshd_config
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep 8022

# ---------- ceph03 : verify ----------
lsblk
for ip in 100.66.69.201 100.66.69.202 100.66.69.105 100.66.69.110; do
  ping -M do -s 1472 -c1 -W1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done
curl -sI https://quay.io | head -1
```

### Before continuing

From your desktop, SSH to all six addresses on port 8022 — `100.66.69.201`, `.202`, `.203` and `100.66.66.201`, `.202`, `.203`. All three nodes must be reachable on both VLANs before bootstrap, because `cephadm` will drive the other two over SSH.

## 5.5 Bootstrap the cluster

Everything in this section runs on **`ceph01` only**.

```bash
# ===== RUN ON: ceph01 (100.66.69.201) =====
# ---------- ceph01 ----------
curl -sLo /usr/local/sbin/cephadm https://download.ceph.com/rpm-tentacle/el9/noarch/cephadm
chmod 755 /usr/local/sbin/cephadm

cat > /root/cephadm-ssh-config <<'EOF'
Host *
  User root
  Port 8022
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ConnectTimeout 30
EOF

cephadm bootstrap \
  --mon-ip 100.66.69.201 \
  --ssh-config /root/cephadm-ssh-config \
  --skip-monitoring-stack
```

`cephadm` manages hosts over SSH and assumes port 22, which is why the SSH config is not optional here. The monitor address puts Ceph's public network on `100.66.69.0/24`. `--skip-monitoring-stack` saves RAM in the lab; enable Prometheus and Grafana later if you want them.

**Save the dashboard password it prints.** The dashboard is at `https://100.66.69.201:8443`.

### Give ceph01 access to the other two

Print the cluster key on `ceph01`:

```bash
# ===== RUN ON: ceph01 (100.66.69.201) =====
# ---------- ceph01 ----------
cat /etc/ceph/ceph.pub
```

Paste it into root's `authorized_keys` on each of the other nodes:

```bash
# ===== RUN ON: ceph02 (100.66.69.202) =====
# ---------- ceph02 ----------
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'PASTE_CEPH_PUB_KEY_HERE' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

```bash
# ===== RUN ON: ceph03 (100.66.69.203) =====
# ---------- ceph03 ----------
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'PASTE_CEPH_PUB_KEY_HERE' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

### Add them to the cluster

Back on `ceph01`. **Every `ceph` command from here to the end of Part 6 runs inside `cephadm shell`.**

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
# ---------- ceph01 ----------
cephadm shell
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph cephadm check-host ceph02 100.66.69.202
ceph cephadm check-host ceph03 100.66.69.203

ceph orch host add ceph02 100.66.69.202
ceph orch host add ceph03 100.66.69.203
ceph orch host ls

ceph orch apply mon --placement="ceph01,ceph02,ceph03"
ceph orch apply mgr --placement="ceph01,ceph02"
ceph -s
```

Wait for three monitors in quorum before going on. `ceph -s` should show `mon: 3 daemons, quorum ceph01,ceph02,ceph03`.

## 5.6 Create the OSDs

Still inside `cephadm shell` on `ceph01`. Confirm the orchestrator sees exactly the six disks you expect, and nothing else:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch device ls
```

You want `sdb` and `sdc` on each of the three hosts, `Available: Yes`. If `sda` appears as available, stop — something is wrong with the install and you are one command away from wiping an OS disk.

Then add them one at a time, named explicitly:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch daemon add osd ceph01:/dev/sdb
ceph orch daemon add osd ceph01:/dev/sdc
ceph orch daemon add osd ceph02:/dev/sdb
ceph orch daemon add osd ceph02:/dev/sdc
ceph orch daemon add osd ceph03:/dev/sdb
ceph orch daemon add osd ceph03:/dev/sdc

ceph orch ps --daemon-type osd
ceph osd tree
```

Six OSDs, two per host. Naming each device beats `--all-available-devices`: it is explicit about what gets consumed, and it fails loudly rather than quietly claiming a disk you meant to keep.

## 5.7 Device class, tuning and pools

**Read the device class, then believe it.** Run:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph osd tree
```

On this build every OSD came up as **`hdd`**, and that is **correct**: the Ceph VMs live on 10k SAS spinning disks, not flash. Ceph read the underlying device accurately and there was nothing to fix.

> **Retraction.** Revisions 8 and 9 of this guide claimed that QEMU virtual disks misreport flash as rotational and instructed you to override the class to `ssd`. That instruction was wrong for this build and has been removed. Override the class **only** when you know the backing device is flash and Ceph has genuinely misread it. Setting a class that does not match the hardware gives you a CRUSH map that lies and performance figures that mean nothing.

The rule below is therefore named for what the hardware actually is:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph config set osd osd_memory_target 1073741824     # 1 GiB per OSD at 16 GB RAM per node
ceph config set osd osd_mclock_profile high_client_ops

ceph osd crush rule create-replicated hdd-rule default host hdd

ceph osd pool create nvmeof-cfg 32 32 replicated hdd-rule
rbd pool init nvmeof-cfg

ceph osd pool create vmfs-flash 64 64 replicated hdd-rule
ceph osd pool set vmfs-flash size 3
ceph osd pool set vmfs-flash min_size 2
rbd pool init vmfs-flash

ceph time-sync-status
ceph df
ceph -s
```

The pool keeps the name `vmfs-flash` because it is the name every later command and the RBD paths already use. It describes the pool's *purpose*, not its media.

If you created the rule as `flash-rule` on an earlier revision, rename rather than rebuild:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph osd crush rule rename flash-rule hdd-rule
ceph osd crush rule ls
```

**Memory.** With 16 GB per node, `osd_memory_target` at 1 GiB × 2 OSDs leaves room for the monitor, the manager and the 8 GiB of hugepages the NVMe-oF gateway reserves in Part 6. 2 GiB per OSD is the right figure once the nodes have more RAM; 4 GiB in production.

**mClock.** `ceph config dump | grep mclock` will show nothing set beyond the profile, and that is expected. The scheduler sizes itself from `osd_mclock_max_capacity_iops_hdd`, whose default is **315**. Ceph benchmarks each OSD at creation and keeps the result only if it falls below `osd_mclock_iops_capacity_threshold_hdd` (**500**) — anything higher is discarded as implausible for a spinning disk and the default stands. On this build no benchmark line appears in `ceph log last 200`, so every OSD is running on the 315 default. For a lab on 10k SAS that is roughly right and needs no intervention. On production NVMe the equivalent `*_ssd` settings matter a great deal — measure before trusting them.

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph config show osd.0 | grep mclock
ceph config help osd_mclock_max_capacity_iops_hdd
```

**`min_size 2`** is what keeps I/O alive when a node goes down. With three nodes at `size=3`, one node down is degraded but writable; **two nodes down stops I/O.** Never take a second node down until the first is fully back and the cluster reads `HEALTH_OK`.

**These numbers do not transfer.** Every latency and throughput figure this lab produces is a measurement of six 10k SAS spindles with `size=3` replication and no separate WAL/DB device. They say whether the *path* works. They say nothing about what production on NVMe OSDs will do. Record them in 8.4 as lab artefacts, never as a baseline.

## 5.8 Gate for Part 5

- [ ] `ceph -s` reads `HEALTH_OK`
- [ ] `mon: 3 daemons, quorum ceph01,ceph02,ceph03`
- [ ] `ceph osd tree` shows 6 OSDs `up`/`in`, two per host, class `hdd`
- [ ] `ceph df` shows roughly 1.2 TiB raw
- [ ] `lscpu` on each node shows `avx2`, `bmi1`, `bmi2` and `fma`
- [ ] `free -h` shows ~15 GiB on each node
- [ ] `ceph time-sync-status` clean — Ceph warns at 50 ms of monitor drift
- [ ] Cluster state recorded in the findings log (8.5)

These nodes cannot be rolled back with a ZFS snapshot the way the nested hosts can (8.2). `ceph orch host maintenance enter` is the equivalent safety net — use it before any disruptive change to a node.

---

# PART 6 — NVMe-oF GATEWAY CONFIGURATION

> **Runs on:** `ceph01` (100.66.69.201) only, unless a block says otherwise.
> **Every `ceph` command in this part runs inside `cephadm shell` on `ceph01`.** Enter it once and stay there.

Part 5 ends with a healthy cluster and no way for ESXi to reach it. This part builds that path and is the second half of the Ceph configuration. Nothing here touches an ESXi host — that is Part 7.

The version this guide was built and verified against: **Ceph Tentacle v20.2.4**, gateway container `quay.io/ceph/nvmeof:1.7`, daemon version **1.7.23**.

## 6.1 Deploy the gateways

Prerequisite: every Ceph node must be on CPU type `x86-64-v3` with 16 GB RAM (5.1). If it is not, the gateways will deploy and then sit in `error` state — the recovery is at the end of this section and it is slow.

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph mgr module ls | grep -i nvmeof
ceph mgr module enable nvmeof              # if the line above showed it disabled

ceph orch apply nvmeof --pool nvmeof-cfg --group gw-lab --placement="ceph01,ceph02,ceph03"
ceph orch ps --daemon-type nvmeof
```

**Use the named flags.** The positional form rejects:

```
ceph orch apply nvmeof nvmeof-cfg gw-lab     # → Invalid command: Unexpected argument
```

Wait for all three to read `running` and show version `1.7.23`. First deploy pulls the container on each node, so give it a few minutes.

### What three gateways actually buy you

Three gateways means **three load-balancing groups**. HA is active/standby *per namespace*: at any moment exactly one gateway is the ANA-optimized path for a given namespace and the other two are non-optimized standby for it.

This is the single most important consequence for datastore design, and it is why **one big datastore would be a mistake.** A single namespace sits in a single load-balancing group, so all of its I/O lands on one gateway while the other two carry nothing. Sizing guidance is in 7.7.

The gateway is built on the **SPDK userspace target**, not the Linux kernel `nvmet` target. That distinction is what makes it work with ESXi, and it is worth knowing when reading advice written about kernel NVMe-oF.

### Two resource behaviours to expect

**SPDK burns whole cores.** It is a polled-mode target: `nvmf_tgt --lcores (0-3)` sits at 100% CPU on each assigned core regardless of how much I/O is flowing. On a 4-vCPU node that is the entire VM. This is normal and not a fault. To reduce it, pass extra arguments in the service spec:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch ls --service-type nvmeof --export
```

and set `tgt_cmd_extra_args: "--lcores (0-1)"` to hand SPDK two cores instead of four.

**The gateway reserves 8 GiB of hugepages per node** — 4096 pages by default. Confirm:

```bash
# ===== RUN ON: each Ceph node =====
grep -i huge /proc/meminfo
free -h
```

That reservation is why 16 GB per node is the floor and why `osd_memory_target` was dropped to 1 GiB in 5.7.

### Check your build's flag spelling before trusting anything

This build uses **underscores** throughout — `--host_name`, `--rbd_pool`, `--rbd_image_name`, `--load_balancing_group`, `--host_nqn`, `--block_size`. Older documentation, including earlier revisions of this guide, shows hyphens. Confirm against your own build:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof subsystem add --help
ceph nvmeof listener add --help
ceph nvmeof namespace add --help
```

### If the gateways land in `error`

The symptom is `ceph orch ps --daemon-type nvmeof` showing `error` or `unknown`, with `ceph -s` raising `CephadmDaemonFailed` and nothing useful in it. Read the daemon log directly:

```bash
# ===== RUN ON: ceph01 =====
cephadm logs --name nvmeof.nvmeof-cfg.ceph01.DAEMON_SUFFIX     # the suffix 'ceph orch ps' printed
```

`Fatal glibc error: CPU does not support x86-64-v3` means the VM is still on `kvm64`. The fix is per node, and the order matters:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
# 1. Remove the gateway service first. Maintenance mode refuses while gateways are configured.
ceph orch rm nvmeof.nvmeof-cfg.gw-lab
ceph orch ls

# 2. Drain one node at a time
ceph orch host maintenance enter ceph03
```

```bash
# ===== RUN ON: Proxmox — change ceph03's CPU type to x86-64-v3 and RAM to 16 GB, then boot it =====
```

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch host maintenance exit ceph03
ceph -s            # wait for HEALTH_OK before the next node
```

Repeat for `ceph02`. **`ceph01` needs one extra step** — it holds the active manager, and maintenance mode will refuse:

```
Cannot stop active Mgr daemon, Please switch active Mgrs with 'ceph mgr fail ceph01.szccct'
```

So:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph mgr fail ceph01.MGR_SUFFIX         # use the exact name the error message printed
ceph -s                                 # confirm the standby mgr took over
ceph orch host maintenance enter ceph01
```

Then re-run the `ceph orch apply nvmeof` at the top of this section.

## 6.2 Create the subsystem — and read the NQN back

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof subsystem add --nqn nqn.2016-06.io.spdk:lab01
ceph nvmeof subsystem list
```

**The gateway appends the gateway-group name to the NQN you asked for.** What you created as `nqn.2016-06.io.spdk:lab01` is listed as:

```
nqn.2016-06.io.spdk:lab01.gw-lab
```

That suffixed form is the **effective NQN** and the only one that works. Every command from here on, and every `esxcli nvme fabrics connect` in Part 7, uses it in full. Giving ESXi the unsuffixed form fails with a message about no subsystem being found, which sends people looking at the network instead of at the name.

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
NQN=nqn.2016-06.io.spdk:lab01.gw-lab       # paste exactly what subsystem list showed
echo $NQN
```

## 6.3 Listeners — one per gateway

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof listener add --nqn $NQN --host_name ceph01 --traddr 100.66.69.201 --trsvcid 4420
ceph nvmeof listener add --nqn $NQN --host_name ceph02 --traddr 100.66.69.202 --trsvcid 4420
ceph nvmeof listener add --nqn $NQN --host_name ceph03 --traddr 100.66.69.203 --trsvcid 4420

ceph nvmeof listener list --nqn $NQN
```

A listener on **every** gateway is what makes HA work. Miss one and that gateway's load-balancing group has nowhere to fail over to. Path redundancy on the other side comes from the initiator: each ESXi host reaches every listener through two bound adapters (Part 7).

### Two things in the output that look wrong and are not

**`Active: False` on two of the three listeners.** On this build `listener list` showed `Active True` only for `ceph01` and `False` for the other two, while all three were demonstrably serving traffic. Verify from the transport layer instead of believing the column:

```bash
# ===== RUN ON: each Ceph node =====
ss -tlnp | grep -E '4420|8009'
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.201 100.66.69.202 100.66.69.203; do
  nc -z -w2 $ip 4420 && echo "$ip:4420 open" || echo "$ip:4420 CLOSED"
done
```

All three must be listening and reachable. If they are, the `Active` column is bookkeeping and can be ignored.

**A `NVMeoFInterfaceDuplex` health alert.** `ethtool` on the gateway interface reports `Speed: Unknown!` and `Duplex: Unknown!` on all three nodes. That is a property of the virtio NIC in a KVM guest — there is no physical link to report. The alert is a lab artefact; record it in 8.4 and do not chase it. On physical production hardware the same alert would be real and worth investigating.

## 6.4 RBD images and namespaces

Six images at 40 GiB — the arithmetic and the `MAX AVAIL` ceiling are in 5.1:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
rbd create vmfs-flash/ds01 --size 40G
rbd create vmfs-flash/ds02 --size 40G
rbd create vmfs-flash/ds03 --size 40G
rbd create vmfs-flash/ds04 --size 40G
rbd create vmfs-flash/ds05 --size 40G
rbd create vmfs-flash/ds06 --size 40G

rbd ls -l vmfs-flash
```

### Namespaces — block size is not optional

**ESXi requires 512-byte namespaces.** A 4 K namespace connects cleanly and then presents no usable device, which across every storage vendor is the most common cause of "ESXi can't see my storage". `ceph-nvmeof` defaults to 512, but this build sets it explicitly so the intent is in the command rather than in a default that could change:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds01 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds02 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds03 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds04 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds05 --block_size 512
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds06 --block_size 512

ceph nvmeof namespace list --nqn $NQN
```

### Load-balancing groups — measured, not assumed

**This build auto-balances.** With `--load_balancing_group` omitted, 1.7.23 assigns groups round-robin, so six namespaces land two per group with no intervention. The namespace list above should show groups `1,2,3,1,2,3`.

That was tested deliberately: the first three were added without the flag and landed in groups 1, 2 and 3 respectively. **Confirm it on your own build before relying on it.** If all three land in group 1, your build does not auto-balance, and every namespace must then carry the flag explicitly or the whole cluster's client traffic ends up on one gateway while the other two idle:

```bash
# ===== RUN ON: ceph01, inside cephadm shell — ONLY if your build did not auto-balance =====
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds04 --block_size 512 --load_balancing_group 1
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds05 --block_size 512 --load_balancing_group 2
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds06 --block_size 512 --load_balancing_group 3
```

Either way, end with **two namespaces per group** and record which build behaviour you observed in 8.5 — it is the detail that decides whether the production build can omit the flag.

## 6.5 Gate for Part 6

- [ ] `ceph orch ps --daemon-type nvmeof` — three gateways `running`, version 1.7.23
- [ ] `ceph nvmeof listener list` — three listeners, one per node
- [ ] `ss -tlnp` on each node shows `4420` and `8009` listening
- [ ] `ceph nvmeof namespace list` — six namespaces, block size 512, two per load-balancing group
- [ ] The effective NQN (`…:lab01.gw-lab`) written down
- [ ] `ceph -s` still `HEALTH_OK`
- [ ] `free -h` on each node still shows headroom with 8 GiB of hugepages reserved

### Before production

`cephadm` pulls container images on every deploy and upgrade. Physical Ceph on a management network with no internet needs a **local registry mirror**, with `cephadm registry-login` pointed at it. Plan that before the production build, not during the first upgrade.

---

# PART 7 — VMWARE INTEGRATION

> **Runs on:** `ceph01` for 7.1, then each nested host in turn for 7.2–7.4. 7.5 onwards is vCenter and one nested host.

The cluster is healthy, the gateways are up and the namespaces exist. This part connects the three nested hosts and moves the lab onto Ceph. It needs Part 4 and Part 6 both complete.

Before starting, re-read the condition in 4.1: **every `NVME-A` and `NVME-B` port group must show an active uplink.** Everything in this part fails in a confusing way if one of them is in standby, and 7.6 is the decision tree for when it does.

## 7.1 Authorise the host NQNs

The adapters were enabled and the three host NQNs recorded in 4.3.6, 4.4.6 and 4.5.6. They follow the form `nqn.2014-08.local.vsphere:nvme:lab-esxi01`.

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi01'
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi02'
ceph nvmeof host add --nqn $NQN --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi03'

ceph nvmeof host list --nqn $NQN
```

Paste each host's **own** NQN as `esxcli nvme info get` printed it — do not assume the hostname suffix, confirm it. If `$NQN` is no longer set in this shell, re-read it with `ceph nvmeof subsystem list`, and remember it carries the `.gw-lab` suffix (6.2).

## 7.2 Connect `lab-esxi01`

**Step 1 — prove the uplinks are active.** This is the deferred half of the 4.6 gate and the single most common cause of failure here:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli network vswitch standard portgroup policy failover get -p NVME-A
esxcli network vswitch standard portgroup policy failover get -p NVME-B
esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
```

Both port groups must show an Active Adapter with an empty Standby list, and both VMkernel ports must show `Tags: NVMeTCP`.

**Step 2 — prove the storage path**, now against the addresses NVMe/TCP will actually use:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
vmkping -I vmk2 -d -s 1472 100.66.69.201
vmkping -I vmk2 -d -s 1472 100.66.69.202
vmkping -I vmk2 -d -s 1472 100.66.69.203
vmkping -I vmk3 -d -s 1472 100.66.69.201
vmkping -I vmk3 -d -s 1472 100.66.69.202
vmkping -I vmk3 -d -s 1472 100.66.69.203
```

All six must answer. A failure here is a network problem, and connecting on top of it only hides the cause.

**Step 3 — identify the adapters.** On the live build `vmhba65` was bound to **vmnic2** (path A) and `vmhba66` to **vmnic3** (path B), and those names survived every reboot. Confirm rather than assume — the numbers are not guaranteed to match across hosts:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli nvme adapter list
```

**Step 4 — connect both adapters to all three gateways.** Six controllers is the target: two fabrics × three gateways.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli nvme fabrics discover -a vmhba65 -i 100.66.69.201 -p 8009

esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab

esxcli nvme controller list
esxcli nvme namespace list
esxcli storage core device list | grep -iE "Display Name|Block Size"
```

**Expect six controllers, six namespaces, and block size 512 on every device.** Five controllers means one adapter failed to reach one gateway — find out which before moving on. Block size 4096 must be fixed at the namespace in 6.4, before any VMFS is created on it.

**Step 5 — verify ANA distribution.** This is what proves the three gateways are actually sharing the load:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
for d in $(esxcli storage core device list | grep '^eui\.'); do
  echo "== $d"
  esxcli storage core path list -d $d | grep -E 'Runtime Name:|State:'
done

esxcli storage hpp device list | grep -E '^eui|Path Selection Scheme|Working Path'
```

Each device should show **six paths — two `active`, four `standby`**. The two active paths are the same gateway reached over both fabrics; the four standby are ANA non-optimized and that is the correct display for HPP, not a fault. The Path Selection Scheme should read `LB-RR` with both active paths in the Working Path Set.

Measured on the live build, with `T0/T1/T2` being `.201/.202/.203` on each adapter:

| Datastore | NSID | LUN | ANA-optimized gateway | Working paths |
|---|---|---|---|---|
| `lab-nvme-ds01` | 1 | L0 | ceph01 (100.66.69.201) | vmhba65:T0, vmhba66:T0 |
| `lab-nvme-ds02` | 2 | L1 | ceph02 (100.66.69.202) | vmhba65:T1, vmhba66:T1 |
| `lab-nvme-ds03` | 3 | L2 | ceph03 (100.66.69.203) | vmhba65:T2, vmhba66:T2 |
| `lab-nvme-ds04` | 4 | L3 | ceph01 (100.66.69.201) | vmhba65:T0, vmhba66:T0 |
| `lab-nvme-ds05` | 5 | L4 | ceph02 (100.66.69.202) | vmhba65:T1, vmhba66:T1 |
| `lab-nvme-ds06` | 6 | L5 | ceph03 (100.66.69.203) | vmhba65:T2, vmhba66:T2 |

Two namespaces per gateway, evenly spread. If yours are not, go back to the load-balancing groups in 6.4.

**Two settings worth getting right**, per Broadcom guidance: set the **controller loss timeout to around 1800 seconds** at connect time (check `esxcli nvme fabrics connect --help` for your build's option name), so that a routine gateway reboot does not become a datastore drop; and leave **data digest off**, which has documented path-loss and performance problems.

## 7.3 Connect `lab-esxi02`

Same procedure, run on `lab-esxi02`. The gateway addresses are identical — only the shell you are in changes.

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli network vswitch standard portgroup policy failover get -p NVME-A
esxcli network vswitch standard portgroup policy failover get -p NVME-B
esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3

vmkping -I vmk2 -d -s 1472 100.66.69.201
vmkping -I vmk2 -d -s 1472 100.66.69.202
vmkping -I vmk2 -d -s 1472 100.66.69.203
vmkping -I vmk3 -d -s 1472 100.66.69.201
vmkping -I vmk3 -d -s 1472 100.66.69.202
vmkping -I vmk3 -d -s 1472 100.66.69.203

esxcli nvme adapter list
```

Read the two `vmhba` names from `adapter list` and use them below in place of `vmhba65` and `vmhba66` if they differ:

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab

esxcli nvme controller list
esxcli nvme namespace list
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

If 7.5 has already run on `lab-esxi01`, all six datastores appear here with no further action — the VMFS is already on the namespaces.

## 7.4 Connect `lab-esxi03`

Same again, on `lab-esxi03`.

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli network vswitch standard portgroup policy failover get -p NVME-A
esxcli network vswitch standard portgroup policy failover get -p NVME-B
esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3

vmkping -I vmk2 -d -s 1472 100.66.69.201
vmkping -I vmk2 -d -s 1472 100.66.69.202
vmkping -I vmk2 -d -s 1472 100.66.69.203
vmkping -I vmk3 -d -s 1472 100.66.69.201
vmkping -I vmk3 -d -s 1472 100.66.69.202
vmkping -I vmk3 -d -s 1472 100.66.69.203

esxcli nvme adapter list
```

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.201 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.202 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.203 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab

esxcli nvme controller list
esxcli nvme namespace list
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

## 7.5 Create the datastores and move the lab onto Ceph

Create the VMFS once, from any one host. The others pick it up on rescan.

The **vCenter → New Datastore wizard** does this with no arithmetic and is the easier route. The CLI version is below because it is exact, scriptable and leaves a record of what was done.

Every namespace is 40960 MB, which is 83,886,080 sectors of 512 bytes. GPT reserves the last 34 for the secondary header, so the usable end is **83,886,046** on all six — the same number every time.

If you ever change the namespace size, the formula and a lookup table for the common sizes are in **10.5**:

```
sectors      = size_in_MB × 2048
last usable  = sectors − 34
```

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli storage core device list | grep '^eui\.'
```

Take the six `eui.*` names from that output. For the first one:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
partedUtil mklabel /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7 gpt
partedUtil getUsableSectors /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7
```

Confirm that prints `34 83886046`, then:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
partedUtil setptbl /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7 gpt \
  "1 2048 83886046 AA31E02A400F11DB9590000C2911D1B8 0"

vmkfstools -C vmfs6 -S lab-nvme-ds01 /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7:1
```

`AA31E02A400F11DB9590000C2911D1B8` is the VMFS partition type GUID. It is the same on every device.

The remaining five in one pass — substitute your own `eui.*` names, keeping each paired with the datastore name that matches its NSID (the mapping is in the table in 7.2):

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
for pair in \
  "eui.9162389c18e04af6982a389f0b07a768 lab-nvme-ds02" \
  "eui.552097d44ab54b0baad9101784e07eac lab-nvme-ds03" \
  "eui.fdb17d20f8d34576ae73df1e2ead0a76 lab-nvme-ds04" \
  "eui.c07b900445294fffa07d7618acc94f02 lab-nvme-ds05" \
  "eui.9c15af2f14234f1294f92e18ca6a4faa lab-nvme-ds06" ; do
  set -- $pair
  partedUtil mklabel /vmfs/devices/disks/$1 gpt
  partedUtil setptbl /vmfs/devices/disks/$1 gpt "1 2048 83886046 AA31E02A400F11DB9590000C2911D1B8 0"
  vmkfstools -C vmfs6 -S $2 /vmfs/devices/disks/$1:1
done

esxcli storage filesystem list | grep lab-nvme
```

Six VMFS-6 volumes, each about **39.75 GB** — VMFS-6 takes roughly 1.2 GB of a 40 GiB device for metadata, so that figure is correct, not a shortfall. Then on the other two hosts:

```
# ===== RUN ON: lab-esxi02 and lab-esxi03 =====
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

### Prove I/O actually crosses both fabrics

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
time dd if=/dev/zero of=/vmfs/volumes/lab-nvme-ds01/iotest.bin bs=1M count=4096

esxcli storage core path stats get -p vmhba65:C0:T0:L0 | grep -E 'Successful|Blocks Written'
esxcli storage core path stats get -p vmhba66:C0:T0:L0 | grep -E 'Successful|Blocks Written'

rm -f /vmfs/volumes/lab-nvme-ds01/iotest.bin
```

`Blocks Written` should be within a few percent across the two paths. On the live build it was 4,328,116 against 4,313,203 — 0.3% apart.

**The throughput figure is not a result.** 4 GiB took 98 seconds, about 42 MB/s. That is six 10k SAS spindles absorbing `size=3` replication with no separate WAL/DB device — roughly 125 MB/s of raw spindle work, which is about right. It says the path works. It says nothing about production on NVMe OSDs. Record it in 8.4 as a lab artefact.

### Move the test VMs

1. Place or Storage vMotion `lab-vm01`–`03` across `lab-nvme-ds02`…`lab-nvme-ds06`, **at least one VM per load-balancing group** — use the table in 7.2 to pick datastores owned by different gateways.
2. Watch `stall-watch` inside each guest during the migration. This is the first real write load the NVMe/TCP path carries, and a migration that finishes with no stall lines is a meaningful result — record it.
3. Confirm the **heartbeat datastores** are `lab-nvme-ds01` and `lab-nvme-ds02`, set in 4.8 — two datastores owned by different gateways.

### Clean up any temporary connection on the R450

If the physical R450 was connected to the subsystem as a control test (7.6), disconnect it now. A physical host mounting datastores that belong to the nested cluster is a confusing thing to leave behind.

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli nvme controller list
# note the Controller Number for nqn.2016-06.io.spdk:lab01.gw-lab, then:
esxcli nvme fabrics disconnect -a vmhba64 -n CONTROLLER_NUMBER

esxcli nvme fabrics disable --protocol TCP --device vmnic3
esxcli network ip interface tag remove -i vmk2 -t NVMeTCP
esxcli nvme adapter list
esxcli nvme controller list
```

The flag is `-n` / `--controller-number`. `-c` is not valid. Both lists should come back empty, and nothing on the R450's switching is touched — `vmk2` keeps its address and vSwitch1 is unchanged.

## 7.6 When `connect` fails — the decision tree

The symptom is always the same unhelpful line:

```
Adapter or transport target not found
```

The real reason is in `/var/log/vmkernel.log`:

```
# ===== RUN ON: the ESXi host that failed to connect =====
tail -50 /var/log/vmkernel.log | grep -iE 'NVMFNET|nt_ConnectCM|nvmetcp'
```

| Log line | Cause | Fix |
|---|---|---|
| `Failed to get source vmknic for NVMe/TCP traffic on vmnicX: Not found` | The port group's uplink is in **Standby** with no Active adapter | `esxcli network vswitch standard policy failover set -v vSw-NVMeA --active-uplinks=vmnic2` |
| Same line, uplink already active | The VMkernel port is not tagged, or is in a different portset than the adapter's uplink | `tag get` on the port; check `interface list` shows the expected `Portset` |
| No subsystem found | The NQN is missing its `.gw-lab` suffix | Re-read it with `ceph nvmeof subsystem list` (6.2) |
| Connects, but no devices | Namespace block size is 4096 | Recreate the namespace with `--block_size 512` (6.4) |
| Connects, host rejected | The host NQN is not authorised | `ceph nvmeof host list` (7.1) |

**Two traps worth naming.**

Removing and re-adding a VMkernel port **destroys its `NVMeTCP` tag.** The tag is an attribute of the port object, not of the port group. After any `interface remove` / `interface add`, re-tag before testing anything.

`fabrics disable` followed by `fabrics enable` can hand out a **new `vmhba` number.** Always re-read `esxcli nvme adapter list` after a cycle rather than reusing the number from your notes.

**If you need a control.** The fastest way to tell a host problem from a target problem is to connect the physical R450 to the same subsystem — it is a completely different initiator on a different NIC driver. Add its NQN with `ceph nvmeof host add`, tag `vmk2`, `fabrics enable` on `vmnic3`, and connect. If the R450 connects and the nested host does not, the target is fine and the fault is on the nested host. Tear it down afterwards per 7.5.

## 7.7 Datastore sizing — how many, how big

The lab's six 40 GiB datastores are sized for the lab, against a `MAX AVAIL` of 390 GiB (5.1). **To change that size later, use 10.5** — it is a four-layer operation and the order is not optional. The question of what production should look like has a different answer, and it is driven by one property of the gateway rather than by VMFS.

### Why not one big datastore

**ANA optimization is per namespace.** A namespace belongs to exactly one load-balancing group, and that group's gateway is the only optimized path for it. One enormous datastore means one namespace, one group, one gateway carrying every byte while the other two sit as non-optimized standby. You would buy three gateways and use one.

Ceph itself has no objection to a single large RBD image — it stripes over objects across the whole pool regardless. The penalty is entirely on the gateway and ESXi side.

### The rule

**Namespace count should be a multiple of the number of gateways**, so the load-balancing groups fill evenly. With three gateways: 3, 6, 9 or 12 namespaces. The lab's six is two per gateway.

Then size each one from how many VMs it will hold:

| Guideline | Value | Why |
|---|---|---|
| VMs per VMFS datastore | **15–25** | Limits blast radius and metadata contention. VMFS-6 with ATS handles far more, but recovery and troubleshooting do not |
| Datastore size | **2–8 TB**, 4 TB a good default | Large enough to avoid datastore sprawl, small enough that one restore is not a weekend |
| Hard ceiling | 64 TB per single-extent VMFS-6 | Architectural limit, not a target |

Worked for the ~200 VM target this platform is sized against:

| Approach | Namespaces | Size each | Total | VMs per datastore |
|---|---|---|---|---|
| **Recommended** | 12 | 2 TB | 24 TB | ~17 |
| Fewer, larger | 9 | 3 TB | 27 TB | ~22 |
| Conservative | 6 | 4 TB | 24 TB | ~33 — above the guideline |

Twelve namespaces across three gateways gives four per gateway and keeps every datastore inside the VM-count guideline. Build them with the same `--block_size 512` and let 1.7.23 auto-balance the groups (6.4), then verify the distribution from ESXi with the path check in 7.2.

### What about spanning one datastore across several namespaces?

VMFS-6 supports multi-extent volumes, and extents on namespaces in different load-balancing groups would spread I/O across all three gateways. It works, and it is still the wrong choice: the first extent holds the metadata, losing any extent loses the whole datastore, and troubleshooting a spanned volume is markedly harder. Use separate datastores.

### Using the six lab datastores now

They are independent VMFS volumes, so place VMs on them deliberately rather than at random:

- Spread VMs so that each gateway owns at least one active workload — the table in 7.2 says which gateway owns which datastore.
- A **Datastore Cluster** with Storage DRS automates this, but needs vSphere Enterprise Plus. On a lower edition, place by hand.
- Keep one datastore empty as a Storage vMotion target. It makes the planned-maintenance test (T6) and the gateway-failure test (T3) in 8.1 much easier to run.

## 7.8 Gate for Part 7

- [ ] Six controllers and six namespaces on **every** nested host
- [ ] Block size 512 on every device
- [ ] Six paths per device, two active and four standby, `LB-RR`
- [ ] ANA ownership spread two namespaces per gateway
- [ ] Six datastores visible cluster-wide
- [ ] `Blocks Written` within a few percent across both fabrics
- [ ] Test VMs running on Ceph, spread across all three load-balancing groups
- [ ] Heartbeat datastores repointed
- [ ] Any temporary R450 connection torn down
- [ ] `ceph -s` still `HEALTH_OK` under load

With this done, every test in Part 8 can run.

---

# PART 8 — TEST PLAN

This is why the lab exists. Record what you **observe**, not what you expected. Run each destructive test at least twice; the second run is where you notice what you missed the first time.

Before each test: `load-loop` on one console and `stall-watch` on another, in all three test VMs.

## 8.1 The tests

All of these need Part 7 complete. T9 is worth running early among them: it tests the single-subnet VMkernel question from 4.6, which is a property of the lab's design rather than of Ceph, and 4.4 now records that single-subnet multipathing was proven to work.

### T1 — Paths and block size

Every nested host: six controllers, six namespaces, block size 512.

```
# ===== RUN ON: each nested host in turn =====
esxcli nvme controller list
esxcli nvme namespace list
esxcli storage core device list | grep -iE "Display Name|Block Size"
```

### T2 — Load-balancing distribution

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph nvmeof namespace list --nqn $NQN
ceph orch ps --daemon-type nvmeof
```

**Pass:** two namespaces per group, all three gateways carrying traffic. **Record** which command shows per-gateway load — you'll want it at 3am.

### T3 — Gateway daemon failure under load

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch ps --daemon-type nvmeof              # note the daemon name on ceph02
ceph orch daemon stop nvmeof.gw-lab.ceph02.xxxxxx
```

**Pass:** group 2's namespaces fail over, `stall-watch` shows one bounded pause, no APD, no VM crash. **Record** the pause length, what appears in `/var/log/vmkernel.log` on a nested host, and whether failback on `ceph orch daemon start` is equally clean. Flapping on failback is what Tentacle's configurable delayed failback exists for.

### T4 — Storage path failure

vSphere Client → R450 → VM `lab-esxi01` → Edit settings → **Network adapter 3** (vmnic2, NVMe path A) → untick **Connected**.

**Pass:** `lab-esxi01` drops to three controllers, I/O continues on path B, no datastore event. Reconnect and confirm six return.

### T5 — Ceph node failure

Power off `ceph02` hard — pull the power or use its BMC.

**Pass:** `HEALTH_WARN`, `min_size 2` keeps I/O alive, group 2 fails over.

**Observe:** you lost two OSDs **and** a gateway at once, on real hardware. Compare `stall-watch` with T3, where only the gateway went away. That difference is the argument for dedicated gateway nodes when the budget allows — recovery I/O and gateway failover otherwise land on the same machine at the same moment.

### T6 — Planned Ceph maintenance

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch host ok-to-stop ceph03
ceph orch host maintenance enter ceph03
# reboot ceph03
ceph orch host maintenance exit ceph03
ceph -s
```

**Pass:** no data movement during the reboot, `HEALTH_OK` afterwards, controllers back on every nested host. This rehearses 12.5 exactly.

### T7 — vMotion and DRS

1. Migrate `lab-vm01` between nested hosts with `stall-watch` running. **Pass:** at most a sub-second blip.
2. Put `lab-esxi01` into maintenance mode. **Pass:** DRS evacuates it without intervention.

### T8 — HA host failure

With test VMs spread across hosts, hard power-off VM `lab-esxi02` from the R450.

**Pass:** its VMs restart on the other two hosts with no action from you. **Record** the time from power-off to each VM being powered on again (vCenter → Monitor → Events) and reaching a login prompt on its console.

Worth knowing: this works **without vCenter**. Once configured, HA is host-based.

### T9 — HA isolation, and the single-subnet question

Disconnect **network adapter 1** (vmnic0, vmk0) of VM `lab-esxi03`.

**What should happen:** management heartbeats stop, the host pings its isolation addresses, gets no answer, declares itself isolated, and the isolation response powers off its VMs so the others restart them.

**What may happen instead:** vmk2 and vmk3 are still up in the same subnet. If the TCP/IP stack sends the isolation pings out of an NVMe port, they succeed and the host concludes it is **not** isolated — its VMs keep running on a host vCenter can't reach. That's the multihoming ambiguity from 4.4.

During the test, on the host's console:

```
# ===== RUN ON: each nested host in turn =====
esxcli network ip route ipv4 list
vmkping -I vmk0 100.66.69.110
vmkping 100.66.69.110
```

**Record which outcome you got.** This is the most production-relevant result in the lab: it's how a production host with every VMkernel port in `100.66.69.0/24` will behave. Reconnect the adapter afterwards.

### T10 — Live namespace addition

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
rbd create vmfs-flash/ds07 --size 40G
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds07 --block_size 512 --load_balancing_group 1
```

Check `esxcli nvme namespace list` **before** rescanning, then after `esxcli storage core adapter rescan --all`. **Record** whether the manual rescan was needed — in ESXi 8.0 and earlier, Namespace Attribute Notices are disabled by default, which prevents automatic detection. That answer becomes your capacity-expansion runbook.

### T11 — Gateway rebuild without listeners

Remove `ceph03` from the cluster, rebuild it, re-add it, re-apply the nvmeof placement — **without** re-adding its listeners at first.

**Observe:** the gateway looks healthy in `ceph orch ps` and serves nothing. Then add the listeners and watch it come alive. This failure is invisible in every status command.

### T12 — The hosts guard

On vCenter:

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
sed -i '/lab-esxi02/d' /etc/hosts
sleep 2
grep lab-esxi02 /etc/hosts
journalctl -t hosts-guard --no-pager | tail -3
```

**Pass:** the line is back within seconds. Then reboot vCenter and run `vc-health.sh`.

### T13 — ESXi patch and NQN drift

When the next ESXi patch ships, apply it to `lab-esxi01` first, following 12.4. **Before** exiting maintenance mode, compare `esxcli nvme info get` with the NQN recorded in 4.5. If it changed, you've caught a production outage in advance.

### T14 — Cold start, and the wrong order

Full lab shutdown and cold start per 8.3. Then deliberately start the nested hosts **before** Ceph is healthy. **Record** what breaks and the exact recovery steps — that becomes your power-restore runbook.

## 8.2 Snapshots and rollback

`vzfspool/lab` holds the nested ESXi hosts and the test VMs, so one ZFS snapshot captures that whole layer in seconds — far faster than snapshotting five VMs individually.

**The Ceph nodes are not covered.** They're physical, so a rollback restores the nested cluster while Ceph carries on. In practice that's fine: Ceph state after a rollback is still valid, because the datastores and namespaces haven't changed. What you lose is the ability to undo a Ceph-side experiment — use `ceph orch host maintenance` and the findings log for those instead.

**Never snapshot the lab running.** A crash-consistent image of a nested cluster is not a consistent image.

```text
1. Shut down the test VMs, then the nested ESXi hosts
2. On stor-gw01:  zfs snapshot vzfspool/lab@gate-cluster-up
3. Optional: snapshot vcenter803 too, so vCenter's view matches the lab
4. Power the nested hosts back on per 7.3
```

Ceph keeps running throughout; nothing needs to be flagged for a snapshot of the nested layer alone.

Rolling back, with every lab VM powered off:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
zfs list -t snapshot -r vzfspool/lab
zfs rollback vzfspool/lab@gate-cluster-up          # the most recent snapshot
zfs rollback -r vzfspool/lab@gate-ceph-healthy     # an older one — -r DESTROYS the newer snapshots
```

Then on the R450, reload the VMs so ESXi rereads their files:

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
vim-cmd vmsvc/getallvms | grep -E 'ceph0|lab-esxi|lab-vm'
vim-cmd vmsvc/reload VMID     # from vim-cmd vmsvc/getallvms
```

If VMs show as inaccessible, remount the datastore — `esxcli storage nfs remove -v r450-zfs-lab`, then `esxcli storage nfs add -H 100.66.69.105 -s /vzfspool/lab -v r450-zfs-lab` — and reload again.

If you didn't snapshot vCenter at the same gate, it may remember a newer lab state; reconnect hosts it shows as disconnected, or remove and re-add them.

Gate snapshots worth keeping: `gate-ceph-healthy`, `gate-cluster-up`, `gate-test-vms`. Watch their space with `zfs list -o name,used,usedbysnapshots -r vzfspool/lab`.

## 8.3 Lab power order

### Shutdown

```text
1. Test VMs
2. lab-esxi01-03   (vCenter: host → Power → Shut Down)
3. Ceph flags set, then ceph01-03 shut down
4. Only if the R450 itself is going down: vcenter803, then stor-gw01
```

### Start

```text
1. R450 → autostart: stor-gw01 (NFS + NTP), then vcenter803
2. Power on ceph01-03 (BMC) → wait for quorum → clear flags in reverse:
     for f in pause nodown nobackfill norecover norebalance noout; do ceph osd unset $f; done
   → HEALTH_OK → ceph orch ps --daemon-type nvmeof all running
3. lab-esxi01-03 → esxcli storage core adapter rescan --all → six controllers each
4. Test VMs (HA may already have started some)
```

The flags stop Ceph treating a planned shutdown as mass failure. Don't forget to clear them: `pause` alone stops all I/O.

Until Part 5 is built, skip the Ceph steps entirely — shutdown becomes test VMs, nested hosts, then vCenter and `stor-gw01`; start becomes the R450's autostart pair, then the nested hosts, then the test VMs. The order that matters either way is that `stor-gw01` comes up first and goes down last, because everything else lives on its datastores.

## 8.4 Lab artefacts versus real findings

When something breaks, decide which column it's in before spending time on it.

| Symptom | Lab artefact? | Notes |
|---|---|---|
| Throughput and latency figures | **Yes** | Many layers of indirection. Ignore |
| A nested VMkernel port reaches nothing while vmk0 works | **Yes** | Its MAC doesn't match its vNIC (4.1, 4.3) |
| EVC wizard refuses the nested cluster | **Yes** | Nested CPU exposure; doesn't predict R630 behaviour |
| Ceph node cores busy at idle | **Yes** | SPDK polling in the gateways. Expected — and no longer on the R450 |
| Evaluation licence expiry | **Yes** | 60 days from each nested install |
| "No subsystem found" at connect | **No** | Effective NQN — production behaves identically |
| All namespaces in one LB group | **No** | A build that does not auto-balance, with `--load_balancing_group` omitted |
| New namespace needs a rescan | **No** | ESXi 8.0 behaviour |
| Rebuilt gateway serves nothing | **No** | Listeners not re-added |
| Clock skew warnings | **No** | NTP design. Fix it here, not in production |
| Hosts-file lookup failures | **No** | The no-DNS design. Exactly what the lab is for |
| Traffic leaving by the wrong VMkernel port | **No** | Single-subnet multihoming — production shares it |
| Desktop can't reach a lab VM on one address | **No** | That NIC is on the wrong port group |

## 8.5 Findings log

Keep this beside the lab. It, not the lab itself, is the deliverable.

| # | Finding | Evidence | Production action |
|---|---|---|---|
| 1 | Effective NQN format on this build | `subsystem list` | |
| 2 | Auto-balance across LB groups: yes/no | T2 pass 1 | |
| 3 | LB reassignment command | | |
| 4 | Gateway failover pause | T3 `stall-watch` | |
| 5 | Ceph node loss pause | T5 `stall-watch` | |
| 6 | HA restart time | T8 | |
| 7 | Isolation behaviour with all VMkernel ports in one subnet | T9 | |
| 8 | Rescan needed after namespace add | T10 | |
| 9 | NQN drift on patch | T13 | |
| 10 | Working cold-start order | T14 | |
| 11 | CLI syntax differences from this guide | `--help` output | |
| 12 | VMkernel-MAC matching worked without promiscuous mode | 4.6 | |

---

# PART 9 — PERFORMANCE TUNING

Tune in this order. Each layer caps the one above it, so VM-level tuning is wasted on a host that throttles its CPUs.

## 9.1 BIOS — every physical host

| Setting | Value | Why |
|---|---|---|
| System Profile | **Performance** | Disables C-states and power capping; removes latency jitter |
| Turbo Boost | Enabled | |
| Logical Processor | Enabled | ESXi's scheduler uses hyper-threading well |
| Virtualization Technology | Enabled | Mandatory |
| VT-d / Directed I/O | Enabled | Passthrough and general correctness |
| SR-IOV Global Enable | Enabled | Harmless, useful later |
| Node Interleaving | **Disabled** | Keeps NUMA visible to ESXi |
| x2APIC | Enabled | |
| Memory Operating Mode | Optimizer | |

Pick one owner of power management: either the BIOS Performance profile, or "Performance Per Watt (OS)" plus the ESXi High Performance policy from 1.3. Not both half-way.

## 9.2 ESXi hosts

| Item | Setting |
|---|---|
| Power policy | High Performance (1.3) |
| Firmware and drivers | Current Dell firmware; stay on the Dell custom image line |
| X710 NIC | Firmware matched to the `i40en` driver on the compatibility guide |
| Host swap | Local SSD; never on Ceph |

## 9.3 EVC

EVC presents every VM with the CPU feature set of the **oldest** generation in the cluster. On a cluster of matched hosts it costs nothing. Mixing the R450 (Ice Lake) with R630s (Broadwell) would mask the newer instruction sets, including AVX-512, from every VM. For most server workloads that's invisible; for compression, analytics or crypto-heavy VMs it can be measurable.

**Per-VM EVC** (hardware version 14+) is the alternative: set a baseline only on the VMs that must migrate between generations.

## 9.4 VM sizing

**vCPUs**
- Start small, grow on evidence. Oversized VMs run *slower*, because every vCPU must be co-scheduled.
- Keep a VM's vCPU count within one socket's cores where possible, so it stays NUMA-local. The R450 has 2 NUMA nodes of 8 cores each, so 4 vCPU is comfortably local and 8 is the practical ceiling.
- **Don't enable CPU Hot Add on large VMs.** It disables vNUMA, so the guest sees a flat memory topology and places memory badly.

**Memory**
- Size to the working set plus headroom. Judge by ballooning and swapping (9.8), not the guest's "used" figure.
- No reservations except where required: the ZFS storage gateway, the Ceph VMs and nested ESXi need them; vCenter does not.
- Never set a memory **Limit** below configured RAM. The guest uses what it thinks it has, and the excess comes from balloon and swap — invisible from inside.

**Devices:** remove unused floppy, serial, CD and USB devices.

## 9.5 Storage

| Practice | Why |
|---|---|
| PVSCSI for data disks on busy VMs | Deeper queues, less CPU per I/O |
| Split heavy databases across several disks on separate controllers | Parallel queues |
| Thin provisioning plus datastore alarms at 75/85% | Fine if someone watches the datastores |
| **No snapshot older than 72 hours** | They grow, slow every I/O, and make consolidation painful |
| Distribute VMs across all Ceph datastores | Each is served by one gateway at a time |

Test space reclamation on NVMe-backed VMFS before depending on thin-provisioning economics.

## 9.6 Network

| Practice | Why |
|---|---|
| VMXNET3 everywhere | Paravirtual; E1000/E1000E cost CPU and cap throughput |
| RSS enabled in the guest | Spreads network load across vCPUs |
| Jumbo frames only where verified end to end | Currently nowhere — MTU is 1500 |
| Multi-NIC vMotion on production hosts | Faster evacuations, shorter windows |

## 9.7 Guest OS

**Linux:** `open-vm-tools` running; time from chrony against `100.66.69.105`, **not** VMware Tools periodic sync — never both; disk scheduler `none` or `mq-deadline` on virtual disks.

**Windows:** VMware Tools current, PVSCSI and VMXNET3 drivers, High performance power plan.

## 9.8 Measuring — esxtop reference

| Metric | View | Healthy | Investigate | Meaning |
|---|---|---|---|---|
| `%RDY` | `c` | < 5% per vCPU | > 10% per vCPU | Waiting for a physical CPU |
| `%CSTP` | `c` | < 3% | > 3% | Co-stop — too many vCPUs |
| `%MLMTD` | `c` | 0 | > 0 | A CPU limit is throttling |
| `MCTLSZ` | `m` | 0 | > 0 | Balloon driver active |
| `SWCUR`, `SWR/s` | `m` | 0 | > 0 | Host swapping — serious |
| `N%L` | `m` (NUMA fields) | ≥ 90% | < 80% | Memory local to the NUMA node |
| `DAVG/cmd` | `u` | < 2 ms flash | > 10 ms | Latency from storage itself |
| `KAVG/cmd` | `u` | < 0.5 ms | > 2 ms | Queuing inside ESXi |
| `QUED` | `u` | 0 | sustained > 0 | Queue full |
| `%DRPTX`, `%DRPRX` | `n` | 0 | > 0 | Dropped packets |

`%RDY` in the VM row is summed across vCPUs — divide by the vCPU count before comparing.

Capture a baseline while things are healthy and quiet:

```
# ===== RUN ON: each nested host in turn =====
esxtop -b -d 10 -n 60 > /tmp/esxtop-baseline-$(hostname)-$(date +%F).csv
```

Ten minutes of data. Copy it off the host. A baseline is what turns "it feels slow" into a number.

---

# PART 10 — PLATFORM OPERATIONS

## 10.1 Routine checks

Five kinds of machine, each with its own failure modes. The table is grouped by **when**, because that is how it gets used; the per-component commands follow.

| Frequency | Component | Check |
|---|---|---|
| **Daily** | vCenter | `vc-health.sh` clean |
| | Cluster | No triggered alarms; three hosts Connected |
| | Ceph | `ceph -s` is `HEALTH_OK`; three gateways active |
| | Backups | vCenter file-based backup succeeded |
| **Weekly** | Storage | `zpool status` clean, scrub results |
| | Ceph | `ceph df` and `ceph osd df tree` — capacity and balance |
| | NVMe paths | Six controllers on every nested host |
| | Snapshots | Nothing older than 72 hours |
| | Capacity | Everything against 10.4 |
| **Monthly** | All | Security advisories, from a machine with internet |
| | Credentials | vCenter root, SSO admin, iDRAC expiry |
| | Certificates | Certificate Management, plus the calendar in 12.6 |
| | Licences | Three nested evaluations, three different dates |
| | Backups | ESXi config bundles exist and are not empty |
| | Restore | One VM restored to an isolated network |
| **Quarterly** | HA | Failover test, as T8 |
| | Cold start | Full shutdown and restart drill, 8.3 |
| | Firmware | iDRAC Lifecycle Controller review |
| | Capacity | Forecast against 10.4 |

### The daily five minutes

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
/usr/local/sbin/vc-health.sh
```

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph -s
ceph df
```

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli nvme controller list
esxcli storage filesystem list | grep lab-nvme
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
zpool status
zfs list
```

Four machines, four commands each at most. Anything that is not clean gets explained the same day — on a platform this size, every warning has a cause you can find, and the habit of ignoring one is how the first real failure gets missed.

### What "clean" looks like on each component

| Component | Healthy reads |
|---|---|
| `esxi8-dell-r450` | 5 disks present, both X710 uplinks at 10 Gb, a core dump target active |
| `vcenter803` | `vc-health.sh` with no `FAIL` or `WARN`; `hosts-guard` enabled |
| `stor-gw01` | `vzfspool` ONLINE, no errors, both NFS exports served |
| `lab-esxi01/02/03` | 4 VMkernel ports, active uplinks on every port group, 6 NVMe controllers, 6 datastores |
| `ceph01/02/03` | `HEALTH_OK`, 3 mons in quorum, 6 OSDs up/in, 3 gateways active, PGs `active+clean` |

### The checks that would have caught this build's real faults

Three things went wrong during the build that no obvious check noticed, and each left a specific test behind:

| What happened | The check that catches it |
|---|---|
| vSwitch uplinks left Standby with no Active adapter — NVMe/TCP could not connect while every network check passed | `esxcli network vswitch standard portgroup policy failover get -p NVME-A` |
| `lab-esxi03` joined the cluster with `vmk1` entirely absent | `esxcli network ip interface ipv4 get` — **count the rows**, expect four |
| `cephadm` silently reduced `osd_memory_target` to 411 MB | `ceph config show osd.0 \| grep osd_memory_target` |

All three share a shape: the attribute-level checks passed and nothing checked existence or effective value. Worth running them monthly even once the build is settled.

```
# ===== RUN ON: each nested host, monthly =====
esxcli network ip interface ipv4 get
for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done
esxcli nvme controller list
```

## 10.2 Monitoring and alerting

**vCenter alarms** worth confirming are enabled and routed somewhere a human sees: host connection and power state, host hardware health, datastore usage (75% warning / 85% alert), HA status and failover events, certificate expiry.

For email, point **vCenter → Configure → Settings → General → Mail** at an internal SMTP relay by IP. SNMP traps to your NMS are the alternative.

**Prometheus** can poll vCenter's API from a monitoring VM that reaches `100.66.69.110`, iDRAC on every physical host, Ceph's `prometheus` manager module on 9283, and `node_exporter` on stor-gw01 and the Ceph nodes.

Alert on the thresholds in 9.8 and 10.4, not on raw utilisation. Two alerts that specifically matter here:

- **NVMe-oF gateway daemon down** — a silent gateway loss halves redundancy with no user impact until the second failure
- **LB group distribution drift** — namespaces bunching into one group after adds or rebalances

## 10.3 Backups

**vCenter:** daily file-based backup (2.2). Test the restore path once a year. A restore rebuilds the appliance without the hosts guard — reinstall it.

**ESXi configuration**, from a Linux host with SSH key access:

```bash
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
cat > /usr/local/sbin/esxi-config-backup.sh <<'EOF'
#!/bin/bash
# Backs up ESXi host configuration bundles; keeps 90 days.
set -uo pipefail
HOSTS="100.66.69.101 100.66.69.121 100.66.69.122 100.66.69.123"   # R450 + nested hosts
ROOT=/backup/esxi-config
DEST="$ROOT/$(date +%F)"
mkdir -p "$DEST"
for h in $HOSTS; do
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$h" \
      'vim-cmd hostsvc/firmware/sync_config && vim-cmd hostsvc/firmware/backup_config' >/dev/null; then
    echo "FAIL backup_config on $h"; continue
  fi
  f=$(ssh -o BatchMode=yes "root@$h" 'ls -t /scratch/downloads/*/configBundle-*.tgz 2>/dev/null | head -1')
  if [ -n "$f" ] && scp -q -o BatchMode=yes "root@$h:$f" "$DEST/$h-$(basename "$f")"; then
    echo "OK   $h"
  else
    echo "FAIL copy from $h"
  fi
done
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} +
EOF
chmod 755 /usr/local/sbin/esxi-config-backup.sh
```

Schedule weekly and after any host configuration change. Restoring requires the **same ESXi build**: host in maintenance mode, then `vim-cmd hostsvc/firmware/restore_config /tmp/configBundle-<host>.tgz`.

**Ceph metadata**, weekly from a node with the admin keyring:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
D=/root/ceph-meta/$(date +%F); mkdir -p "$D"
ceph config dump            > "$D/config-dump.txt"
ceph orch ls --export       > "$D/orch-specs.yaml"
ceph osd tree               > "$D/osd-tree.txt"
ceph osd pool ls detail     > "$D/pools.txt"
ceph nvmeof subsystem list  > "$D/nvmeof-subsystems.txt" 2>&1
ceph nvmeof listener list --nqn $NQN > "$D/nvmeof-listeners.txt" 2>&1
cp -a /etc/ceph             "$D/etc-ceph"
```

Not a data backup — it's what you need to rebuild the configuration if the monitors are lost.

**ZFS:** snapshots plus `zfs send` off-box. The storage gateway's pool sits on physical RDMs, which VM-level backup tools **cannot** capture, so this is the only protection it has:

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
zfs snapshot vzfspool/pro@$(date +%Y%m%d)
zfs send -i vzfspool/pro@old vzfspool/pro@new | ssh backup-target zfs recv -F pool/prod
```

If the receiving system runs an older OpenZFS, a send from a pool with newer features enabled is rejected. Either create the pool with `zpool create -d` and enable only mutually supported features, or make the newer box the receiver.

## 10.4 Capacity thresholds

| Resource | Plan to expand at | Act now at |
|---|---|---|
| Cluster CPU (average) | 60% | 75% |
| Cluster memory | 70% | 85%, or any host swapping |
| VMFS datastore | 75% | 85% |
| Ceph pool (`ceph df`) | 60% | 70% — Ceph degrades well before full; `nearfull` fires at 85% |
| ZFS pool | 70% | 80% |
| vCenter `/storage/*` | 70% | 80% |

With HA admission control set to tolerate one host failure, a fraction of cluster capacity is always reserved. Treat that reserve as unavailable when planning.

Watch `sys-ssd` in particular. It starts at 309 GiB free and only ever needs to hold the gateway's 80 GB OS disk, three tiny RDM mapping files and your ISOs — call it 100 GiB in use. If it climbs much beyond that, something has been put there that belongs on `r450-zfs-lab`; find it rather than raising the threshold. Superseded ISOs are the usual culprit: a vCenter patch ISO alone is 7.9 GB and has no job once the build it patches is already running.

## 10.5 Capacity expansion — growing a datastore

A datastore on this platform is four stacked objects, and growing it means telling each one in turn:

```
RBD image  →  NVMe-oF namespace  →  ESXi device  →  VMFS partition + filesystem
   (Ceph)        (gateway cache)       (rescan)          (partedUtil + vmkfstools)
```

Skip a layer and the next one still believes the old size. Do them out of order — grow VMFS before ESXi has seen the larger device — and the operation fails or damages the filesystem.

**This was run end to end on the live platform on 2026-10-05**, taking all six datastores from 25 GiB to 40 GiB with VMs running and no downtime. Every value below is measured.

### Before you start — is there room?

The number that matters is **`MAX AVAIL`**, which Ceph derives from the fullest OSD and the full ratio. It is not the same as raw capacity and it is always lower than the arithmetic you would do by hand.

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph df
```

On this build `MAX AVAIL` is **390 GiB** against 1.2 TiB raw — `size=3` plus the full-ratio reserve. Measure the proposal against that, not against the raw figure:

| Size each | Six total | % of 390 GiB | Verdict |
|---|---|---|---|
| 25 GiB | 150 GiB | 38% | the original build |
| 38 GiB | 228 GiB | 58% | inside the 60% ceiling in 10.4 |
| **40 GiB** | **240 GiB** | **62%** | what was done — acceptable |
| 50 GiB | 300 GiB | 77% | too far; `nearfull` territory |

**RBD images are thin, so these are provisioned figures, not consumed ones.** After the live expansion, `vmfs-flash` still showed `STORED 1.4 GiB` — 0.35% of the pool. You are not spending 240 GiB; you are promising it. Over-provisioning is legitimate as long as you watch `%USED` rather than vSphere's free-space display, because ESXi will cheerfully report room on a datastore while Ceph fills underneath it.

### The arithmetic

Every namespace on this platform uses **512-byte blocks**, so:

```
sectors        = size_in_MB × 2048
last usable    = sectors − 34        (GPT reserves the final 34 for the backup header)
```

| Target | MB | Sectors | **End sector for partedUtil** |
|---|---|---|---|
| 25 GiB | 25600 | 52,428,800 | 52428766 |
| **40 GiB** | **40960** | **83,886,080** | **83886046** |
| 50 GiB | 51200 | 104,857,600 | 104857566 |
| 100 GiB | 102400 | 209,715,200 | 209715166 |

The value is identical on every device of the same size — compute it once.

### Step 1 — the RBD images and the namespaces

Check the flag spelling first; this build uses underscores and the help output is authoritative:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph nvmeof namespace resize --help
```

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
NQN=nqn.2016-06.io.spdk:lab01.gw-lab

for i in 1 2 3 4 5 6; do rbd resize vmfs-flash/ds0$i --size 40G; done
rbd ls -l vmfs-flash

for n in 1 2 3 4 5 6; do
  ceph nvmeof namespace resize --nqn $NQN --nsid $n --size 40G
done
ceph nvmeof namespace list --nqn $NQN
```

NSIDs 1–6 correspond to `ds01`–`ds06` in creation order (the mapping table is in 7.2).

**Both commands are required.** The gateway caches each namespace's size in SPDK, so resizing the RBD image alone enlarges the Ceph object without the gateway ever advertising it. This is the step most likely to be missed, and its symptom appears two layers later as a VMFS grow that fails for no visible reason.

### Step 2 — make ESXi see the new size

```
# ===== RUN ON: lab-esxi01, lab-esxi02 and lab-esxi03 =====
esxcli storage core adapter rescan --all
esxcli nvme namespace list
```

**Every row must show the new `Capacity in MB` before you go further.** With six namespaces across six controllers you will see 36 rows; all of them must read the new value.

A manual rescan is required because **ESXi 8.0 has Namespace Attribute Notices disabled by default**, so the gateway's AEN never reaches the host. There is no automatic detection to wait for.

If a namespace still reports the old size, the gateway did not re-advertise it. Go back to Step 1 and confirm `ceph nvmeof namespace list` shows the new size on the Ceph side.

### Step 3 — grow the VMFS

One host only; the others pick it up on rescan. Do the first datastore on its own and confirm the result before looping the rest.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
partedUtil resize /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7 1 2048 83886046
vmkfstools --growfs /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7:1 \
                    /vmfs/devices/disks/eui.950cd3515e7548ff99c7f86f77f14fb7:1
esxcli storage filesystem list | grep lab-nvme-ds01
```

`--growfs` takes the head extent and the span extent; for an in-place grow they are the same partition, written twice.

Then the remaining five:

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
for d in \
  eui.9162389c18e04af6982a389f0b07a768 \
  eui.552097d44ab54b0baad9101784e07eac \
  eui.fdb17d20f8d34576ae73df1e2ead0a76 \
  eui.c07b900445294fffa07d7618acc94f02 \
  eui.9c15af2f14234f1294f92e18ca6a4faa ; do
  partedUtil resize /vmfs/devices/disks/$d 1 2048 83886046
  vmkfstools --growfs /vmfs/devices/disks/$d:1 /vmfs/devices/disks/$d:1
done

esxcli storage filesystem list | grep lab-nvme
```

### The `partedUtil` message that looks like a failure

Expect this, once per device:

```
Error: The backup GPT table is not at the end of the disk, as it should be.
This might mean that another operating system believes the disk is smaller.
Fix, by moving the backup to the end (and removing the old backup)?
Warning: Not all of the space available to /dev/disks/eui.… appears to be used …
diskSize (83886080)  AlternateLBA (52428799)  LastUsableLBA (52428766)  NewLastUsableLBA (83886046)
```

**This is `partedUtil` doing the right thing, not failing.** When a device grows, its GPT backup header is still sitting at the old end — sector 52,428,799 — while the device now reports 83,886,080 sectors. `partedUtil` detects the mismatch, reports it, moves the backup header to the new end, and proceeds. The four numbers in the warning are a complete account of what it did.

It prints on some invocations and not others — a single interactive command may be silent where the same command inside a `for` loop is not. The outcome is identical either way, and the proof is the resulting size.

### Step 4 — the other hosts

```
# ===== RUN ON: lab-esxi02 and lab-esxi03 =====
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

### Verify, on both sides

```
# ===== RUN ON: each nested host =====
esxcli storage filesystem list | grep lab-nvme
```

All six at the new size on all three hosts. A 40 GiB namespace yields a **39.75 GB** VMFS — `42681237504` bytes — the difference being GPT and VMFS metadata.

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph df
ceph -s
```

`STORED` should be essentially unchanged — growing thin images writes almost nothing. On the live run it stayed at 1.4 GiB and gained a single object, the VMFS metadata update. `MAX AVAIL` does not move.

### The GUI route

vCenter's **Datastore → Increase Datastore Capacity** replaces Step 3 entirely, one datastore at a time, after Step 2 has been done. Same result, no arithmetic. Steps 1, 2 and 4 are unchanged.

### Rules that are not negotiable

| Rule | Why |
|---|---|
| Ceph → rescan → VMFS, in that order | Growing VMFS onto a device ESXi still sizes at the old value fails, and can damage the filesystem |
| Never `rbd resize` **downward** under a live VMFS | RBD will shrink the image without complaint and the filesystem is destroyed |
| VMFS grows, never shrinks | There is no reverse operation. Plan the target size before you start |
| Rescan **every** host before placing new workload | A host running on a stale size will misreport free space |

### When to add instead of grow

Growing is right when a specific datastore is full. **Adding is usually better when you simply want more room**, because:

- three new namespaces keep the load-balancing groups evenly filled, where growing six existing ones changes nothing about distribution;
- there is no VMFS grow operation, so no partition arithmetic and no GPT repair;
- it is the operation T10 already tests.

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
rbd create vmfs-flash/ds07 --size 40G
ceph nvmeof namespace add --nqn $NQN --rbd_pool vmfs-flash --rbd_image_name ds07 --block_size 512
ceph nvmeof namespace list --nqn $NQN
```

Then rescan on every host and create the VMFS as in 7.5. Add in multiples of three so the groups stay balanced.

## 10.6 Boot SSD failure — rebuilding the storage gateway

`sys-ssd` shares its physical device with the ESXi boot partitions, and nothing on that device is mirrored. Losing it costs the hypervisor install, the storage gateway's OS disk, and the RDM mapping files together. The ZFS data itself is untouched — it lives on the three 3.7 TB SSDs — so this is a rebuild, not a restore.

What you need on hand before that day:

- The ESXi 8.0 U3k installer ISO, and the host config backup from `esxi-config-backup.sh` (10.3).
- The storage gateway's `zfs send` stream, or at minimum `/etc/network/interfaces`, `/etc/hosts`, `/etc/exports` and the ARC setting from 2.x. Keep a copy off the R450 — a copy on `sys-ssd` is no copy at all.
- The three device identifiers from 0.1, written down somewhere that is not this host.

The rebuild, in order:

1. Replace the SSD. Reinstall ESXi 8.0 U3k, choosing the new device. Restore the host configuration from the config bundle, which brings back the vSwitches, port groups and vmk2 exactly as they were.
2. Recreate the datastore on the free space and name it `sys-ssd` again — the name is what the RDM paths and the storage gateway's VMX reference.
3. `vcenter803` is on `vca-ssd` and survived. Register it again: browse `vca-ssd` in the host client, right-click `vcenter803.vmx` → **Register VM**. Power it on before anything else, so you have a management plane.
4. Recreate the three RDM mappings with the same `vmkfstools -z` commands from 3.2 and the same file names. The mapping file is only a pointer; recreating it against the same `naa.` identifier restores the same disk.
5. Build a fresh Debian 13 storage gateway per 3.3–3.5, attach the three RDMs on their own PVSCSI controllers as Independent-Persistent, then `zpool import -f vzfspool`. ZFS reads the pool from the disk labels, so the pool comes back whole regardless of controller order.
6. Re-export NFS, re-mount both datastores on the R450, then register the nested hosts and lab VMs from `r450-zfs-lab` — they were never on the failed SSD, so they come back as they were.

Expect most of a working day. The two things that turn it into a much longer day are not having the config bundle and not having the device identifiers, and both are cheap to keep.

**Worth deciding now:** whether to keep a spare 447 GB SSD on the shelf. The R450 has no free bay in the current arrangement, so the swap is a replace-in-place, and the difference between a same-day rebuild and a week of waiting is one disk.

---

## 10.7 Symptom index

Start here. Each row names the first command to run and where the full procedure lives.

### Storage

| Symptom | First command | Go to |
|---|---|---|
| Datastore missing on one host | `esxcli storage core adapter rescan --all` | 7.3 |
| Datastore missing on every host | `ceph -s`, then `ceph orch ps --daemon-type nvmeof` | 11.7 |
| `esxcli nvme fabrics connect` fails | `tail -50 /var/log/vmkernel.log \| grep NVMFNET` | **7.6** |
| Connects, but no usable device | `esxcli nvme namespace list` — block size must be 512 | 6.4 |
| Fewer than six controllers on a host | `esxcli nvme controller list` | 7.2 |
| Datastore full | `ceph df` before vSphere's free space | **10.5** |
| Need more capacity | `ceph df` — check `MAX AVAIL` | **10.5** |
| I/O slow, no errors anywhere | `ceph config show osd.0 \| grep memory` | **11.6** |
| One gateway doing all the work | `ceph nvmeof namespace list` | 11.7 |
| NFS datastore inaccessible | `zpool status` on `stor-gw01` | 10.6 |

### Networking

| Symptom | First command | Go to |
|---|---|---|
| Nested VMkernel port reaches nothing | `esxcli network ip interface list \| grep -E "Name:\|MAC"` | 4.1 |
| A VMkernel port is simply missing | `esxcli network ip interface ipv4 get` — count four rows | 4.3.5 |
| Storage path dead, network looks perfect | `portgroup policy failover get` — **print the teaming policy** | **4.1** |
| Guest VM has no connectivity | `portgroup policy security get -p vlan.2002` on the R450 | 4.1 |
| vMotion fails, "Networking stack mismatch" | destination `vmkernel.log` — `Server instance:` | **4.8**, reboot that host |

### vCenter and the cluster

| Symptom | First command | Go to |
|---|---|---|
| Host "Not responding" after joining | `getent hosts` on vCenter | 4.7 |
| Add Host fails outright | `getent hosts`, then `date` on both ends | 4.7 |
| Host disconnects at roughly 60 days | Host → Configure → Licensing | 12.6 |
| Names stop resolving anywhere | `systemctl status hosts-guard` | 2.1 |
| SSH gone after a reboot | `chkconfig --list \| grep -i ssh` | 1.5 |
| `/etc/hosts` empty after a reboot | `cat /etc/rc.local.d/local.sh` | 1.5, 4.3.7 |
| VMs named `vCLS-*` you did not create | — | 2.5 |
| HA reports every host isolated | Cluster → Configure → vSphere Availability → Advanced | 4.8, **12.11** |
| A VM did not restart after a host failed | Monitor → vSphere HA; then admission control | **12.11** |
| A whole ESXi host is down | `vc-health.sh`, then the HA summary | **12.11** |
| A whole Ceph node is down | `ceph -s`, then `ceph health detail` | **12.10** |
| VM froze, then carried on | `ceph -s` — did a gateway move? | **12.10** |
| VM filesystem went read-only | `mount \| grep ' / '` **inside the guest** | **12.10.6** |
| New host added, datastores do not appear | `ceph nvmeof host list --subsystem $NQN` | **13.2** |
| New Ceph node added, capacity unchanged | `ceph osd df tree` — are its OSDs in? | **13.3** |

### Ceph

Full runbook in 11.9. The entry points:

| Symptom | First command |
|---|---|
| Anything other than `HEALTH_OK` | `ceph health detail` |
| A daemon in `error` | `ceph orch ps`, then `cephadm logs` **on that host** |
| Maintenance mode refused | read the error — it names the fix |
| `autoscale-status` empty | 11.5 — overlapping CRUSH roots |

### Two habits worth keeping

**Print the teaming policy before theorising.** The longest fault of this build — an afternoon, five wrong hypotheses — was a vSwitch uplink sitting in Standby. `vmkping` passed, routes were correct, tags were present, the target was listening, and a physical host connected to the same target first time. One command would have ended it.

**Check existence, not just attributes.** `lab-esxi03` reached the cluster with no `vmk1` at all while every port-group check passed. A gate that inspects the properties of things never notices a thing that is not there.

---

# PART 11 — CEPH OPERATIONS

> **Runs on:** `ceph01` / `ceph02` / `ceph03`, and the NVMe-oF gateways they host.
> This part is day-2. Part 5 built the cluster and Part 6 built the gateways; this is how you run them.

Everything here is specific to Ceph and the gateways. Platform-wide operations — routine checks across all five machine types, alerting, backups and capacity — are Part 10. The symptom index in 10.7 points into both.

## 11.1 Where to run Ceph commands, and the two traps

**Any node with the `_admin` label** can run `ceph` commands. The label is what distributes `/etc/ceph/ceph.client.admin.keyring`; the CLI talks to the **monitors**, not to the manager, so the active mgr's location is irrelevant.

```bash
# ===== RUN ON: any Ceph node =====
ceph orch host ls
```

All three carry `_admin` on this build. `ceph03` was added later:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch host label add ceph03 _admin
```

`cephadm` distributes the keyring to a newly labelled host automatically.

### Trap 1 — the container prompt

`cephadm shell` drops you into a container. Inside it, `/etc/ceph/` holds only the config inferred from the local mon's directory — **the admin keyring is not there**, the host's `/var/log` is not there, and `cephadm` itself will not run because there is no container engine inside a container.

The prompt is the only tell:

| Prompt | Where you are |
|---|---|
| `root@ceph02:~#` | the **host** |
| `root@ceph02:/#` | inside **`cephadm shell`** |

`ceph` commands work in both. Anything touching host files, host logs or `cephadm` itself must be run on the host. This cost time twice during the live build.

### Trap 2 — `cephadm logs` is host-local

```bash
# ===== RUN ON: ceph01 — host shell =====
cephadm logs --name mgr.ceph02.ulsaze
# ERROR: Daemon not found: mgr.ceph02.ulsaze. See `cephadm ls`
```

`cephadm logs` reads the **local** machine's journal. To read a daemon's log you must be on the host that runs it. `ceph orch ps` tells you which host that is.

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch ps
```

## 11.2 Reading cluster health

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph -s
ceph health detail
```

A healthy cluster on this build reads:

```
health: HEALTH_OK
mon:    3 daemons, quorum ceph01,ceph03,ceph02 [leader: ceph01]
mgr:    ceph02.ulsaze(active), standbys: ceph01.szccct
osd:    6 osds: 6 up, 6 in
nvmeof: 3 gateways active (3 hosts)
pgs:    161 active+clean
```

Four things to check in that output, in order of how much they matter:

| Line | What must be true |
|---|---|
| `mon` | **3 in quorum.** Two is survivable; one means the cluster stops |
| `osd` | `6 up, 6 in`. An OSD `up` but `out` is draining; `down` is a fault |
| `nvmeof` | **3 gateways active.** A silent gateway loss halves redundancy with no user-visible symptom until the second failure |
| `pgs` | Everything `active+clean`. Anything else is recovering, degraded, or stuck |

### Warnings you will see, and what they mean

| Warning | Meaning | Action |
|---|---|---|
| `PG_DEGRADED` | A replica is missing — normal while a node is down or rebalancing | Wait. If it persists with all OSDs up, investigate |
| `OSD_NEARFULL` | An OSD crossed 85% | Act. 10.4 has the thresholds; 10.5 has expansion |
| `POOL_TOO_FEW_PGS` | The autoscaler wants to split a pool | Advisory. See 11.5 |
| `CephNodeDiskspaceWarning` | A **node's root filesystem**, not an OSD | Check `df -h` on that host. Logs and container images are the usual cause |
| `NVMeoFInterfaceDuplex` | `ethtool` reports Speed/Duplex `Unknown!` | **A virtio artefact on these KVM guests.** Lab-only; on physical hardware this would be real |
| `CephadmDaemonFailed` | A daemon is in `error` | `ceph orch ps` to find it, then `cephadm logs` on **that** host |

### Time

Ceph warns at 50 ms of monitor drift and the symptoms are strange rather than obvious.

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph time-sync-status
```

All three take NTP from `stor-gw01` at `100.66.69.105`.

## 11.3 Routine Ceph checks

| Frequency | Check | Command |
|---|---|---|
| **Daily** | Health | `ceph -s` — anything but `HEALTH_OK` gets explained today |
| | Gateways | `ceph orch ps --daemon-type nvmeof` — three `running` |
| **Weekly** | Capacity | `ceph df` — watch `%USED` and `MAX AVAIL`, not raw |
| | OSD balance | `ceph osd df tree` — `STDDEV` and `MIN/MAX VAR` |
| | Time | `ceph time-sync-status` |
| **Monthly** | Daemon versions | `ceph versions` — all components on one release |
| | Orchestrator | `ceph orch ls` — no unexpected drift from the spec |
| | Config drift | `ceph config dump` against what 5.7 set |

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph -s
ceph df
ceph osd df tree
ceph orch ps --daemon-type nvmeof
ceph versions
ceph time-sync-status
```

**The balance figures are worth knowing by sight.** On this build: 75–86 PGs per OSD, `%USE` 0.86 to 1.13, `STDDEV` 0.09, `MIN/MAX VAR` 0.82/1.07. On six OSDs that is about as even as it gets. A `VAR` drifting past roughly 1.3 means one OSD is carrying disproportionate load and is worth investigating before it becomes a `nearfull`.

## 11.4 OSD operations

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph osd tree
ceph osd df tree
ceph device ls
```

**Device class matters and is easy to get wrong.** These OSDs are `hdd` because they sit on 10k SAS spindles, and the CRUSH rule is `hdd-rule`. Do not override a device class to make a rule match — a CRUSH map that misdescribes the hardware produces placement you did not intend and performance figures that mean nothing. Appendix E19 records this being got wrong and corrected.

### Taking a node out safely

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch host ok-to-stop ceph03
ceph orch host maintenance enter ceph03
```

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch host maintenance exit ceph03
ceph -s          # wait for HEALTH_OK before touching the next node
```

**Two things refuse maintenance mode**, both discovered during the live build:

- **The host runs the active manager.** The error names the fix: `ceph mgr fail ceph01.szccct`. Fail it over, confirm the standby took the role, then re-enter maintenance.
- **NVMe-oF gateways are configured on it.** The gateway service has to be removed first (`ceph orch rm`), which is why the CPU remediation in 6.1 is ordered the way it is.

**`min_size 2` is what keeps you alive.** Three nodes at `size=3`: one node down is degraded but writable; **two nodes down stops I/O entirely.** Never take a second node down until the first is fully back and health reads `HEALTH_OK`.

### Replacing an OSD

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph osd out osd.N
ceph -s                                   # wait for rebalance to finish
ceph orch daemon stop osd.N
ceph orch osd rm osd.N --replace
ceph orch device ls --refresh
```

On these KVM guests the "device" is a virtual disk, so replacement means giving the VM a new disk of the same size and letting `cephadm` claim it.

## 11.5 Pools, PGs and the autoscaler

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph osd pool ls detail
ceph osd pool get vmfs-flash pg_num
ceph osd pool get vmfs-flash pg_autoscale_mode
ceph osd pool autoscale-status
```

Current state: `.mgr` (1 PG), `nvmeof-cfg` (32), `vmfs-flash` (128, `size=3`, `min_size=2`, rule `hdd-rule`).

### The autoscaler does not work on this cluster, and there is a reason

`ceph osd pool autoscale-status` returns an **empty list**. The module is loaded and running — the explanation is in the manager's log:

```
pool vmfs-flash won't scale due to overlapping roots: {-1, -2}
pool 1 contains an overlapping root -1... skipping scaling
```

**Root `-1` is `default`. Root `-2` is the shadow root `default~hdd`.** Ceph maintains a hidden per-device-class hierarchy, and a rule saying `step take default class hdd` actually targets that shadow root. On this cluster:

| Pool | Rule | Root |
|---|---|---|
| `.mgr` | `replicated_rule` (stock) | `default` → **-1** |
| `nvmeof-cfg` | `hdd-rule` | `default~hdd` → **-2** |
| `vmfs-flash` | `hdd-rule` | `default~hdd` → **-2** |

Those roots contain the same OSDs, so they overlap, and the autoscaler refuses to compute capacity for **any** pool when that is true. It has therefore never adjusted anything on this cluster.

The fix is to put every pool on the same root. All OSDs are `hdd`, so moving `.mgr` onto `hdd-rule` changes no placement, and `.mgr` holds 577 KiB:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph osd pool get .mgr crush_rule
ceph osd pool set .mgr crush_rule hdd-rule
ceph osd pool autoscale-status
```

```bash
# ===== RUN ON: ceph02 — host shell, where the mgr log lives =====
cephadm logs --name mgr.ceph02.ulsaze | grep -iE 'overlapping|autoscal|pg_num' | tail -30
```

### Freeze PG topology before measuring anything

Whether or not you fix the overlap, set the pool to `warn` before any performance test. A PG split starts a backfill, and a latency measurement taken during one describes a rebalancing cluster rather than your design:

```bash
# ===== RUN ON: any Ceph node with the _admin label — at the start of testing =====
ceph osd pool set vmfs-flash pg_autoscale_mode warn
```

```bash
# ===== RUN ON: any Ceph node with the _admin label — when testing is done =====
ceph osd pool set vmfs-flash pg_autoscale_mode on
```

`warn` still tells you what it would do, through `POOL_TOO_FEW_PGS`, without doing it.

## 11.6 Memory, and the setting that undoes itself

**`cephadm` overrides `osd_memory_target`.** 5.7 sets it to 1 GiB; `osd_memory_target_autotune` is on by default and recalculates it from host memory. On this build the manager log shows:

```
Adjusting osd_memory_target on ceph01 to 411.6M
Adjusting osd_memory_target on ceph02 to 411.5M
```

411 MB is below Ceph's own `osd_memory_target_min` of 896 MiB. At that size the BlueStore cache is effectively gone and every metadata lookup reaches the spindle. **Any performance number collected in that state measures a starved OSD, not your storage design.**

The cause is specific to this platform: autotune takes roughly 70% of host RAM, subtracts what other daemons need, and divides by the OSD count. With 16 GB per node and **the NVMe-oF gateway reserving 8 GiB of hugepages**, there is very little left for two OSDs.

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph config get osd osd_memory_target
ceph config show osd.0 | grep osd_memory_target
```

If the effective value is far below what 5.7 set, pin it:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph config set osd osd_memory_target_autotune false
ceph config set osd osd_memory_target 1073741824
ceph config show osd.0 | grep osd_memory_target
```

Restart the OSDs one host at a time, waiting for `HEALTH_OK` between each:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch daemon restart osd.0
ceph -s
ceph orch daemon restart osd.1
ceph -s
```

1 GiB remains modest against Ceph's 4 GiB default, but it is what fits beside the gateway's hugepages on a 16 GB node, and it is nearly three times what autotune imposed. **On production hardware, size the nodes so autotune lands somewhere sensible on its own** rather than pinning it — the pin is a workaround for a node that is too small.

It also explains the `META` figure in `ceph df`: of 12–13 GiB used, about 9 GiB is BlueStore's RocksDB and WAL — roughly 1.5 GiB per OSD. Under 1% of a 208 GB OSD and entirely normal, but it means `RAW USED` never reads zero and should not be read as "data I put there".

## 11.7 NVMe-oF gateway operations

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch ps --daemon-type nvmeof
ceph nvmeof subsystem list
ceph nvmeof listener list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
ceph nvmeof namespace list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
ceph nvmeof host list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

Three gateways `running` on version 1.7.23, three listeners, six namespaces at 512 bytes spread two per load-balancing group.

### Things in that output that look wrong and are not

**`Active: False` on two of three listeners.** On this build only `ceph01`'s listener reports `Active True` while all three demonstrably serve traffic. The column is bookkeeping. Verify at the transport layer instead:

```bash
# ===== RUN ON: each Ceph node =====
ss -tlnp | grep -E '4420|8009'
```

```bash
# ===== RUN ON: stor-gw01 (100.66.69.105) =====
for ip in 100.66.69.201 100.66.69.202 100.66.69.203; do
  nc -z -w2 $ip 4420 && echo "$ip:4420 open" || echo "$ip:4420 CLOSED"
done
```

**SPDK at 100% CPU.** `nvmf_tgt` is a polled-mode target — it burns every assigned core regardless of load. On a 4 vCPU node that is the whole VM, and it is not a fault. Reduce it through the service spec if you need the cores back:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch ls --service-type nvmeof --export
```

Set `tgt_cmd_extra_args: "--lcores (0-1)"` to give SPDK two cores instead of four.

**8 GiB of hugepages reserved per node.** Expected, and the reason for the memory arithmetic in 11.6:

```bash
# ===== RUN ON: each Ceph node =====
grep -i huge /proc/meminfo
free -h
```

### The effective NQN carries a suffix

Whatever you created, the gateway appends the gateway-group name. `nqn.2016-06.io.spdk:lab01` is served as **`nqn.2016-06.io.spdk:lab01.gw-lab`**, and only the suffixed form works from ESXi. Re-read it rather than reconstructing it:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph nvmeof subsystem list
```

### Authorising a new ESXi host

```
# ===== RUN ON: the ESXi host =====
esxcli nvme info get
```

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph nvmeof host add --nqn nqn.2016-06.io.spdk:lab01.gw-lab --host_nqn 'PASTE_HOST_NQN'
ceph nvmeof host list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

Paste what `esxcli nvme info get` printed. **Host NQNs change across ESXi patches**, which silently orphans that host's datastores — 12.4 re-checks them after every patch.

### Rebuilding a gateway

Removing and re-applying the service does **not** restore listeners. Re-add them explicitly, or that gateway's load-balancing group has nowhere to fail over to and you will not notice until the group's owner fails. This is what T11 tests.

## 11.8 Logs and diagnostics

`cephadm` logs to **journald**, not to files. `/var/log/ceph/<fsid>/ceph.log` usually does not exist on a cephadm cluster, so reach for the journal instead.

```bash
# ===== RUN ON: the host that runs the daemon =====
cephadm ls
cephadm logs --name mgr.ceph02.ulsaze
cephadm logs --name osd.0
cephadm logs --name nvmeof.nvmeof-cfg.ceph01.DAEMON_SUFFIX
```

Take the exact daemon name from `ceph orch ps`, and remember 11.1 — you must be on that daemon's host, in the **host** shell.

The cluster log, which the monitors hold, is reachable from anywhere but has short retention:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph log last 200
ceph log last 200 | grep -iE 'error|warn'
ceph crash ls
ceph crash info CRASH_ID
```

`ceph log last 50` covers minutes, not days. For anything older than the current session, go to the daemon's journal.

## 11.9 Ceph failure runbook

**Losing a whole node is a scenario rather than a symptom — the full walkthrough, including recovery and failback, is 12.10.** This runbook is for everything smaller.

| Symptom | First command | Likely cause |
|---|---|---|
| `HEALTH_WARN`, no detail obvious | `ceph health detail` | Start here always |
| A daemon in `error` | `ceph orch ps`, then `cephadm logs` on that host | 6.1 covers the `x86-64-v3` case |
| Gateway won't start | `cephadm logs --name nvmeof.…` | `Fatal glibc error: CPU does not support x86-64-v3` → the VM is on `kvm64` |
| ESXi connect fails, no subsystem | `ceph nvmeof subsystem list` | NQN missing the `.gw-lab` suffix |
| ESXi connects, no devices | `ceph nvmeof namespace list` | Namespace block size is 4096, not 512 |
| ESXi connects, host rejected | `ceph nvmeof host list` | Host NQN not authorised, or changed by a patch |
| Datastore visible on one host only | `esxcli storage core adapter rescan --all` | That host has not rescanned |
| One gateway carries everything | `ceph nvmeof namespace list` | Namespaces bunched into one load-balancing group |
| Maintenance mode refused | read the error text | Active mgr, or gateways still configured |
| `%RAW USED` climbing with no new VMs | `ceph df` | Thin images filling — 10.5 and 10.4 |
| Everything slow, no warnings | `ceph config show osd.0 \| grep memory` | Autotune squeezed `osd_memory_target` — 11.6 |

### Before any disruptive change

These nodes cannot be rolled back with a ZFS snapshot the way the nested hosts can. `ceph orch host maintenance enter` is the equivalent safety net, and `ceph orch host ok-to-stop` is the question to ask first.

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph -s
ceph df
ceph orch ls
ceph osd pool ls detail
ceph config dump
```

Capture that before you start. It is five commands and it is the difference between restoring a setting and guessing at it.

---

# PART 12 — MAINTENANCE AND FAILURE PROCEDURES

## 12.1 Before any change

- [ ] `vc-health.sh` — no `FAIL`, no `WARN`
- [ ] `ceph -s` — `HEALTH_OK`
- [ ] `zpool status` — no errors
- [ ] No unexplained alarms
- [ ] Last vCenter and ESXi config backups succeeded
- [ ] Rollback path written down: snapshot, backup, or previous boot bank
- [ ] Change logged (Appendix C)

## 12.2 Order of operations

vCenter first, then ESXi hosts, then Ceph — vCenter must always be at or above the hosts' version. The R450 goes **last** among hosts, because patching it takes vCenter down with it.

## 12.3 Patching vCenter

1. Run 8.1. The name-resolution lines are the ones that caused two failed patches.
2. VAMI → Actions → **Shutdown**. From the **R450 host client**, snapshot `vcenter803` powered off. Power on, wait for services.
3. Attach the `patch-FP` ISO from the R450 host client.
4. At the `Command>` prompt:
   ```
   software-packages stage --iso --acceptEulas
   software-packages install --staged
   ```
5. In a second session: `tail -f /var/log/vmware/applmgmt/PatchRunner.log`.
6. **If it fails, don't resume blindly.** Read `PatchRunner.log` and `/var/log/vmware/vmdird/vmdird.log` first. A component-hook failure usually means revert the snapshot, fix the cause on the working version, and rerun clean. Resume attempts are limited.
7. After success: `vc-health.sh`, confirm `systemctl is-enabled hosts-guard.path`, detach the ISO, delete the snapshot after 2–3 days.

## 12.4 Patching ESXi

### Cluster hosts

1. Run 8.1.
2. Record the host's NQN: `esxcli nvme info get`.
3. Enter maintenance mode; wait until the host holds no VMs.
4. Upgrade via the iDRAC ISO (**Upgrade, preserve VMFS**) or `esxcli software profile update`. **Never `profile install`** — it removes VIBs not in the new profile, which on a Dell host means the OEM drivers.
5. After reboot:
   ```
   vmware -vl
   esxcli storage core adapter list
   esxcli network nic list
   esxcli nvme info get
   ```
6. **Compare the NQN with step 2.** Patching can change it. If it did, authorise the new one **before** exiting maintenance mode, or the host's datastores stay missing:
   ```bash
   ceph nvmeof host add --nqn $NQN --host_nqn 'PASTE_NEW_HOST_NQN'
   ```
7. Confirm the full controller count and all datastores, then exit maintenance mode and let DRS rebalance before the next host.

### The R450

1. Shut down VMs on `r450-zfs-lab` (the nested hosts and their test VMs), then `stor-gw01`, then `vcenter803`. The Ceph nodes are unaffected — they're separate machines.
2. Maintenance mode, upgrade, reboot.
3. Autostart brings up `stor-gw01`, then vCenter. Verify `esxcli storage nfs list` shows both datastores accessible.
4. Run `vc-health.sh`.

## 12.5 Patching Ceph

**Version upgrades:**

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch upgrade start --image quay.io/ceph/ceph:v20.2.x
ceph orch upgrade status
ceph -W cephadm
```

`cephadm` rolls daemons one at a time with safety checks. Each **gateway** restart is a failover for its LB group, so watch the hosts' controller counts during the run. Downgrades from Tentacle are not supported; upgrade the lab first.

**OS patching a node** — one at a time, never two. **12.10 is what happens if one goes down unplanned**, and 12.10.7 is the planned path in full:

```bash
# ===== RUN ON: ceph01, inside cephadm shell =====
ceph orch host ok-to-stop ceph02
ceph orch host maintenance enter ceph02
#   ... patch and reboot ceph02 ...
ceph orch host maintenance exit ceph02
ceph -s                                  # wait for HEALTH_OK before the next node
```

## 12.6 Expiry calendar

Every item here, in a shared calendar, with a reminder **30 days ahead**:

| Item | Default lifetime | Where to check |
|---|---|---|
| vCenter root password | 90 days | `chage -l root` |
| `administrator@vsphere.local` | 90 days | SSO password policy |
| vCenter machine SSL certificate | per Certificate Management | vSphere Client |
| ESXi host certificates | per host | Host → Configure → System → Certificate |
| Nested ESXi evaluation licences | 60 days | Lab only |
| iDRAC passwords and certificates | local policy | iDRAC |
| vSphere 8 general support | Oct 2027 | R630 replacement plan (Part 14) |

## 12.7 Full shutdown and cold start

Same as the lab order in 8.3, extended to production workloads: application VMs first, then cluster hosts, then Ceph with its flags set, then the R450's own stack (its VMs → storage gateway → vCenter → host). Reverse on the way up, clearing the Ceph flags once quorum is back.

## 12.8 Adding a node — the name-plumbing checklist

**Part 13 is the full procedure** for a new nested host or a new Ceph node. This section is the one thing Part 13 cannot verify for you: on a platform with no DNS, every machine carries its own copy of every name, and the failure mode of this design is forgetting one of them. Work this list after Part 13's build, before you call the node done.

- [ ] IP and name agreed; added to the master list (1.4)
- [ ] vCenter: added to `REQUIRED` in `hosts-guard.sh`, then run it
- [ ] Every ESXi host: added to `/etc/hosts`, then `/sbin/auto-backup.sh`
- [ ] Every Ceph node and stor-gw01: added to `/etc/hosts`
- [ ] `NAMES` in `vc-health.sh` updated
- [ ] NTP and time verified
- [ ] ESXi: EVC compatibility confirmed **before** joining a cluster
- [ ] ESXi: NQN authorised on the gateway (`ceph nvmeof host add`)
- [ ] Networking identical to its peers; `vmkping` matrix passes
- [ ] Added to the config-backup host list (10.3)
- [ ] Monitoring and alarms include it
- [ ] Every *count* in this guide that was three is now four — the daily checks (10.1), the capacity table (10.4) and the gates in 13.4

## 12.9 Troubleshooting runbook

| Symptom | First checks | Usual fix |
|---|---|---|
| vCenter patch fails at the `vmdir` hook | `getent hosts localhost`, `getent hosts 100.66.69.110` | Restore hosts entries; revert and rerun clean |
| vCenter services won't start after reboot | `vc-health.sh`, `service-control --status --all` | Name resolution first, then `/var/log/vmware/vmon/vmon.log` |
| vCenter UI and logins slow | `time getent hosts no-such-name.test` | Remove unreachable DNS servers in VAMI |
| Host shows *Disconnected* | Ping, time sync, `esxcli system ntp get` | `/etc/init.d/hostd restart && /etc/init.d/vpxa restart` |
| Datastore missing after an ESXi patch | `esxcli nvme info get` vs `ceph nvmeof host list` | NQN changed — authorise the new one (12.4) |
| Datastore APD on all hosts | `ceph -s`, `ceph orch ps --daemon-type nvmeof` | Gateway or Ceph health; check for flags left set after a shutdown |
| New namespace invisible on ESXi | `esxcli nvme namespace list` | `esxcli storage core adapter rescan --all` |
| `HEALTH_WARN clock skew` | `chronyc tracking` on each node | Is `100.66.69.105` up and reachable? |
| `r450-zfs-*` inaccessible after a reboot | Is `stor-gw01` running? `esxcli storage nfs list` | Autostart order; start it, then remount |
| NFS mounts using the wrong port | `esxcli network ip connection list \| grep 2049` | Should be local `100.66.69.101` |
| VM slow | `esxtop` per 9.8 | Oversized vCPUs, ballooning, storage latency |
| "Consolidation needed" | Snapshot Manager | Consolidate; find the backup job that left it |

## 12.10 Losing a Ceph node — failure, failover and recovery

The short version: **a running VM pauses and then resumes.** It does not restart, and it does not lose memory. Exactly two of the six datastores are affected, and which two is knowable in advance.

This section is the complete sequence. 12.11 is the same treatment for an ESXi host, and 12.12 compares them.

### 12.10.1 The four layers that keep storage up

Storage HA here is four independent mechanisms, and only one of them is genuinely active/active. Knowing which is which is what makes the rest of this section predictable rather than surprising.

| Layer | Mechanism | Mode | Survives | Does **not** cover |
|---|---|---|---|---|
| **1 — Fabric** | `vmk2` + `vmk3`, two vSwitches, two uplinks | **Active / active** | One vmnic, vSwitch or uplink | A gateway or node dying |
| **2 — Gateway** | ANA load-balancing groups | **Active / standby** | A gateway daemon or whole node | Anything *instantly* — failover takes time |
| **3 — Data** | RADOS `size=3` / `min_size=2`, failure domain `host` | 2 of 3 | One host's worth of OSDs | A second host — I/O stops |
| **4 — Control** | 3 monitors, majority of 2 | 2 of 3 | One monitor, and the mgr | Two monitors |

**Layer 1 is the only one where both paths carry traffic at once.** Both VMkernel ports are active to whichever gateway owns the namespace — measured at 0.3% apart in `Blocks Written` during the T2 run. Layer 2 is **not** extra bandwidth: a namespace is optimized on exactly one gateway and reported `inaccessible` by the other two.

### 12.10.2 The blast radius is knowable in advance

ANA ownership is fixed per namespace, so you can say before the event which datastores a given node's loss will touch:

| Namespace | ANA group | Owned by | If that node dies |
|---|---|---|---|
| `lab-nvme-ds01` | 1 | `ceph01` | pauses, then resumes |
| `lab-nvme-ds04` | 1 | `ceph01` | pauses, then resumes |
| `lab-nvme-ds02` | 2 | `ceph02` | pauses, then resumes |
| `lab-nvme-ds05` | 2 | `ceph02` | pauses, then resumes |
| `lab-nvme-ds03` | 3 | `ceph03` | pauses, then resumes |
| `lab-nvme-ds06` | 3 | `ceph03` | pauses, then resumes |

Two of six. The other four never notice. Confirm the current map before relying on it — the gateway assigns groups round-robin and a rebuild can change them:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph nvmeof namespace list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

### 12.10.3 Unplanned — the node crashes or loses power

Three things leave at the same instant: a monitor, two OSDs and a gateway. That simultaneity is the character of this failure, and it is why T5 and T3 give different answers.

| When | What happens | Effect |
|---|---|---|
| t = 0 | `ceph02` stops | `mon.ceph02`, two OSDs and the gateway all go at once |
| 0–1 s | TCP to `100.66.69.202:4420` drops | Every ESXi host falls from 6 controllers to 4. `ds02`/`ds05` I/O stalls here |
| seconds | Monitors re-elect if the leader was there | 3 → 2, majority of 2 holds, the cluster keeps taking commands |
| seconds | Gateway group reassigns LB group 2 | A surviving gateway marks `ds02`/`ds05` **optimized**; ESXi re-points and I/O resumes |
| ~20–30 s | Mons mark the two OSDs `down` | PGs → `active+undersized+degraded`. I/O continues on 2 of 3 copies |
| 600 s | `mon_osd_down_out_interval` expires | OSDs marked `out`. CRUSH re-maps and **finds no third host** |
| until it returns | Cluster runs degraded | No backfill, no self-heal, **no redundancy margin** |

**The three-host trap.** With exactly three hosts and failure domain `host`, Ceph **cannot** rebuild the third replica — there is nowhere to put it. Short term that is a mercy: no recovery I/O storm competing with your VMs. Long term it means you are running with no margin, and one more OSD failure anywhere takes PGs below `min_size` and blocks I/O. A fourth Ceph node (13.3) is what changes this, and that is a better argument for it than the capacity is.

### 12.10.4 What to do while it is down

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph -s
ceph health detail
ceph osd tree
```

Expect `HEALTH_WARN` with `osds down`, `PG_DEGRADED` and `PG_UNDERSIZED`. All three are correct reports, not problems to fix.

```
# ===== RUN ON: lab-esxi01 (100.66.69.121), then 02 and 03 =====
esxcli nvme controller list
esxcli storage filesystem list | grep lab-nvme
```

Four controllers per host, six datastores still mounted. **If a datastore is missing rather than slow, that is a different fault** — go to 7.6.

| Do | Do not |
|---|---|
| Let recovery proceed on its own | Take a second node down for any reason |
| Watch guest filesystems for read-only remounts | Mark OSDs `out` by hand to "speed things up" |
| Bring the node back as soon as you can | Change pool `size` or `min_size` to clear the warning |

**Setting `min_size 1` to make a warning disappear is the single most destructive thing available in this section.** It converts a degraded-but-safe cluster into one that will accept writes it cannot protect, and a subsequent failure then loses them for real.

### 12.10.5 Recovery — what happens when it comes back

| What | Who does it |
|---|---|
| `mon.ceph02` rejoins quorum | automatic, seconds |
| OSDs start, peer and catch up the writes they missed | automatic |
| PGs return to `active+clean` | automatic |
| Gateway container restarts and rejoins the group | automatic |
| **ANA group 2 fails *back* to `ceph02`** | automatic — **and this is a second pause** |
| ESXi reconnects its two lost controllers | automatic |
| **`ceph orch host maintenance exit ceph02`** | **you**, if you entered maintenance |

**Coming back is a second outage.** When the gateway rejoins it reclaims its load-balancing group, which is another ANA handover on `ds02` and `ds05`, at a moment you did not plan for. A VM therefore pauses **twice** in one maintenance cycle. Tentacle has configurable delayed failback precisely because repeated handovers can flap; the failback half of T3 is what tells you whether yours is clean.

**The maintenance-mode row is the one that catches people.** The node boots, SSH works, everything looks healthy at the OS level — and Ceph ignores it entirely until you run the exit command.

```bash
# ===== RUN ON: ceph02 (100.66.69.202) — HOST shell, not cephadm shell =====
systemctl --failed
cephadm ls --no-detail | head -20
```

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch host maintenance exit ceph02      # ONLY if you entered maintenance
ceph -s
ceph orch host ls
ceph orch ps --hostname ceph02
```

Watch recovery finish rather than assuming it has:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
watch -n5 'ceph -s | grep -E "pgs|recovery|objects|health"'
```

Recovery is proportional to **what changed while the node was away**, not to the whole dataset — the OSDs catch up from the PG log where they can. A node down for minutes recovers in seconds; one down for days may need a full backfill of its PGs instead.

Then the gateway and the ESXi side:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch ps --daemon-type nvmeof
ceph nvmeof namespace list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

```
# ===== RUN ON: lab-esxi01 (100.66.69.121) =====
esxcli nvme controller list
```

```
# ===== RUN ON: lab-esxi02 (100.66.69.122) =====
esxcli nvme controller list
```

```
# ===== RUN ON: lab-esxi03 (100.66.69.123) =====
esxcli nvme controller list
```

Six each. If a host is stuck at four:

```
# ===== RUN ON: the host that is short =====
esxcli storage core adapter rescan --all
esxcli nvme controller list
```

### 12.10.6 Check the guest, not just the cluster

This is the part that is about your VM rather than about Ceph, and it is the one most often skipped:

```bash
# ===== RUN ON: each VM that sat on an affected datastore =====
dmesg -T | tail -40
mount | grep ' / '
cat /sys/block/sda/device/timeout
```

Two things to look for. I/O errors or `task blocked for more than 120 seconds` in `dmesg` mean the pause was long enough to hurt. **`ro` on `/` in `mount` output means the kernel remounted the root filesystem read-only to protect it** — the VM is running, nothing can write, and no amount of Ceph recovery fixes it. A guest reboot does.

**Raise the timeout before you ever test this.** Linux defaults to 30 seconds, which is shorter than a slow ANA handover. VMware's recommendation is 180:

```bash
# ===== RUN ON: each test VM (lab-vm01 / lab-vm02 / lab-vm03) =====
cat /sys/block/sda/device/timeout
echo 180 > /sys/block/sda/device/timeout
```

For persistence, a udev rule — or install `open-vm-tools`, which ships one.

### 12.10.7 Planned maintenance instead

Rebooting a Ceph node on purpose is 12.5, and it is the same shape with one addition at the front:

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph orch host ok-to-stop ceph02
```

**Ask that question every time.** It answers honestly, it costs nothing, and it is the one command that will stop you taking down a node whose loss would breach `min_size`.

A planned Ceph maintenance still costs a pause — the ANA handover happens whether you planned it or not. There is no zero-downtime path on this side, which is the sharpest contrast with the ESXi side in 12.11.

### 12.10.8 Gate — the node is back

- [ ] `ceph -s` reads `HEALTH_OK`
- [ ] `3 mons` in quorum, `6 osds: 6 up, 6 in`
- [ ] All PGs `active+clean`, no recovery or backfill in progress
- [ ] `ceph orch ps` shows every daemon `running`, none in `error`
- [ ] Six controllers and six datastores on **all three** ESXi hosts
- [ ] Guest filesystems still read-write, nothing new in `dmesg`
- [ ] Host out of maintenance mode, if it was ever in it

**Until that first box is ticked, do not touch another node.** The degraded window is the only genuinely dangerous part of this whole sequence.

## 12.11 Losing an ESXi host — failure, HA and recovery

The short version: **a running VM dies and cold-boots somewhere else.** Guest memory is lost. Every VM on that host is affected, regardless of which datastore its disks live on.

This is the opposite shape from 12.10, and the difference is worth stating plainly before the detail:

> **vSphere HA never moves a running VM. It restarts a dead one.**
>
> Moving a running VM is vMotion, which is a *planned* action and the subject of 12.11.4.

### 12.11.1 Unplanned — the host crashes or loses power

| When | What happens |
|---|---|
| t = 0 | The host dies. Its VMs die with it — power loss, not a pause |
| ~1–3 s | The HA master stops receiving network heartbeats from it |
| ~15–30 s | The master checks the heartbeat datastores and the isolation addresses, then declares the host dead |
| then | VMFS locks held by the dead host expire, releasing its VMs' files |
| then | HA powers those VMs on, on the surviving hosts, and the guests boot normally |

**Ceph notices nothing.** Namespaces keep their owners, the surviving hosts keep their six controllers, and the dead host's controllers simply cease to exist from the gateway's point of view.

The guest comes up as though someone pulled its power. A journalled filesystem replays and is fine; anything not flushed to disk is gone.

**Record the real number with T8** rather than trusting the estimate above — time from power-off to each VM powered on again, and to a login prompt.

**This works without vCenter.** Once HA is configured it is host-based; the master and slaves agree among themselves. Losing `vcenter803` costs you the ability to *change* HA configuration, not the protection itself.

### 12.11.2 The two things HA needs to tell "dead" from "isolated"

Both were configured in 4.8, and both matter here.

**Heartbeat datastores** — `lab-nvme-ds01` and `lab-nvme-ds02`. A host that stops answering on the network but keeps updating its heartbeat region is *isolated*, not dead, and HA treats the two differently.

Those two datastores were chosen deliberately: `ds01` is ANA-owned by `ceph01` and `ds02` by `ceph02` (7.2). **Losing either Ceph node therefore leaves one heartbeat datastore alive.** Had both been on one gateway, a single Ceph node failure would have blinded HA at the same moment it disturbed storage. If you ever re-pick them, keep them on different gateways.

**Isolation addresses** — `100.66.69.110` and `100.66.69.105`, with `das.usedefaultisolationaddress = false`. HA's default test pings the management gateway, and `vmk0`'s gateway here is a workstation that does not route, so the default test would fail on every host and declare the whole cluster isolated.

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
/usr/local/sbin/vc-health.sh
```

In the client, **Cluster → Monitor → vSphere HA → Summary**: one master, two slaves, protected VMs listed.

### 12.11.3 Capacity — will the VMs actually restart?

Admission control is set to tolerate **one host failure**, which reserves roughly a third of cluster memory. Three hosts at 8 GB is 24 GB total, so about 8 GB is held back.

| | Value |
|---|---|
| Cluster memory | 24 GB (3 × 8 GB) |
| Reserved by admission control | ~8 GB |
| Test VMs | 3 × 2 GB = 6 GB |
| vCLS agents | 2 × ~128 MB |

Comfortable today. As you add VMs, **HA will refuse power-on operations before the hosts look full** — that is admission control working, not a fault. The fix is more capacity or a lower tolerance setting, never disabling admission control, which simply converts a refused power-on now into a failed restart later.

### 12.11.4 Planned — taking a host down on purpose

**Always Maintenance Mode. Never simply shut the host down.**

Right-click the host → **Maintenance Mode → Enter**. DRS is fully automated at migration threshold 3, so it vMotions every VM off the host live, with no interruption to any guest. Wait until the host actually reads *Maintenance Mode*, then power it off.

```
# ===== RUN ON: the host being taken down, to confirm before powering off =====
vim-cmd hostsvc/hostsummary | grep -i inMaintenanceMode
```

Must read `true`.

| Route | Guest impact |
|---|---|
| Maintenance Mode, then power off | **none** — every VM vMotions off live |
| Power off with VMs running | VMs die, HA restarts them — an outage you did not need |

**This is the single biggest operational difference between the two tiers.** An ESXi host has a genuine zero-downtime maintenance path. A Ceph node does not (12.10.7).

### 12.11.5 Recovery — what happens when it comes back

| What | Who does it |
|---|---|
| `vpxa` starts, the host reconnects to vCenter | automatic |
| The HA agent rejoins the cluster as a slave | automatic |
| NVMe controllers reconnect, datastores remount | automatic |
| **Exit Maintenance Mode**, if you entered it | **you** |
| VMs that HA restarted elsewhere move back | **they do not.** DRS may rebalance later, on its own schedule |

That last row surprises people. HA restarts VMs wherever there is capacity and leaves them there. A VM does not return to its original host because that host came back.

**A host that rebooted is a host that gets re-gated.** This is the 4.x.9 checklist again, and it is not ceremony — SSH, the ESXi Shell, `/etc/hosts` and the uplink failover policy are each capable of not surviving a reboot, and each failure is silent:

```
# ===== RUN ON: lab-esxi02 (100.66.69.122), after it boots =====
cat /etc/hosts
chkconfig --list | grep -iE 'ssh|esxshell'

esxcli network ip interface ipv4 get
esxcli network ip interface list | grep -E "Name:|MAC Address:|Netstack Instance:"

for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done

esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3
esxcli nvme controller list
esxcli storage filesystem list | grep lab-nvme
```

Four VMkernel ports, four port groups with an Active Adapter and empty Standby, `NVMeTCP` on `vmk2` and `vmk3`, six controllers, six datastores.

**If the host was reinstalled rather than merely rebooted**, two things from the build apply again: its **host NQN has changed** and must be re-authorised on the gateway (7.1), and it needs its **own reboot before it rejoins** the cluster (4.1, Condition 4) or vMotion will fail with `Networking stack mismatch` while every check passes.

### 12.11.6 Correlated failures — what HA cannot save you from

HA protects against *one host* failing. These are the cases where more than one fails at once, and no HA configuration helps:

| Failure | Effect | Fixable here? |
|---|---|---|
| **The R450 dies** | All three nested hosts die. HA has nowhere to restart anything | No — it is one machine hosting all the hosts. This is why Part 14 exists |
| **`vmnic3` or its switch port dies** | `vSwitch1` has a single uplink, and every `vlan.2001-infa` vNIC rides it. All three hosts lose management, vMotion **and** both storage fabrics at once | No — `vmnic6` 1 Gb is the only spare and both X710 ports are committed |
| **All three Ceph VMs on one Proxmox host** | `size=3` across three Ceph hosts protects against nothing. CRUSH cannot see hypervisor placement and will not warn you | **Yes — and it is free.** Spread them across three physical hosts |

The first two are lab artefacts, honestly recorded. **The third is a real fault that can be fixed today**, and it should be settled before T5 is run, because otherwise T5 measures a failure mode that is not the one you actually have.

### 12.11.7 Gate — the host is back

- [ ] Host shows **Connected** in vCenter, not in maintenance mode
- [ ] `vc-health.sh` clean
- [ ] **Monitor → vSphere HA** — one master, two slaves, VMs protected
- [ ] Four VMkernel ports, `vmk1` on netstack `vmotion`
- [ ] Four port groups with an Active Adapter and empty Standby
- [ ] Six NVMe controllers, six datastores
- [ ] SSH and ESXi Shell `on`; nine entries in `/etc/hosts`
- [ ] A test vMotion **onto** this host succeeds — it is the destination that fails when a stack is mis-bound

## 12.12 Which failure is worse — and what outranks both

A natural assumption is that losing a Ceph node is the more serious event, because Ceph holds the data. That is half right, and the half that is wrong matters operationally.

### 12.12.1 It depends on the dimension

| Dimension | Ceph node | ESXi host | Worse |
|---|---|---|---|
| One node fails — impact on a running VM | pause, memory preserved | **killed, cold boot** | **ESXi** |
| One node fails — how many VMs affected | only those on 2 of 6 datastores | **every VM on that host** | **ESXi** |
| One node fails — guest filesystem | fine, if under the SCSI timeout | journal replay on boot | **ESXi** |
| Two nodes fail | **all I/O stops, platform-wide** | surviving host restarts what fits | **Ceph** |
| Worst credible outcome | **permanent data loss** | a reboot | **Ceph** |
| Can you rebuild it from this guide | no — the data *is* the thing | yes, Part 4, about 30 minutes | **Ceph** |
| Planned maintenance | a pause, every time | **zero downtime** via Maintenance Mode | **Ceph** |

**An ESXi host failure hurts more right now. A Ceph failure hurts more if it goes wrong.**

The reason is that they are different kinds of machine. The nested ESXi hosts are **stateless compute** — nothing lives on them that Part 4 cannot recreate. Lose one and you lose capacity and some uptime. Ceph nodes hold **state**. Lose enough of them in the wrong order and you lose the thing itself, and no runbook brings it back.

### 12.12.2 What that means for how you work

The asymmetry is not really in how bad one failure is. It is in **how much room for error you have**:

| | ESXi host | Ceph node |
|---|---|---|
| Reboot one | routine — Maintenance Mode, DRS moves everything, zero downtime | never routine — every one is a pause |
| Ask permission first | not needed | **`ceph orch host ok-to-stop <node>`, every time** |
| Two at once | degraded service | **outage** |
| Recovery is | nothing to recover — it is stateless | data catching up, and it must finish |

Reboot an ESXi host casually. Never reboot a Ceph node casually.

### 12.12.3 The coupling — where a storage failure becomes a compute failure

The two tiers are less independent than the layer model in 12.10.1 suggests.

HA's APD response is set to **Power off and restart VMs** (4.8). If an ANA handover ever takes longer than the APD timeout, a Ceph node failure stops being a pause and becomes an HA event: VMs killed and restarted, *plus* a degraded cluster underneath. The gentle failure and the harsh one are separated only by how fast the gateway group reassigns a load-balancing group.

**That is the real reason T3 and T5 matter.** They are not box-ticking. They tell you which of the two behaviours this platform actually has, and until they are run the answer is unknown.

### 12.12.4 What outranks both

Neither single-node case is the largest risk here:

| Risk | Why it beats a single node failure | Fixable |
|---|---|---|
| **The R450** | All three ESXi hosts are VMs on one machine. It dies, the cluster dies, HA has nowhere to restart anything | Part 14 — separate hardware |
| **`vmnic3`** | One uplink carries management, vMotion and both storage fabrics for all three nested hosts | No spare 10 Gb port; accept and record |
| **Ceph VM placement** | If all three Ceph VMs sit on one Proxmox host, `size=3` protects against nothing and CRUSH cannot see it | **Yes, today, at no cost** |

Two are lab artefacts with known fixes that cost hardware. The third costs a migration and nothing else, and it is still open in the Still Open list.

**Settle the placement question before running T5.** Otherwise the test measures a failure mode you do not have, and passes for the wrong reason.


---

# PART 13 — SCALING OUT: ADDING NODES

> Two independent procedures. **13.2** adds a fourth nested ESXi host; **13.3** adds a fourth Ceph node. They share nothing except the addressing scheme, so read only the one you need.

Both begin with a constraint that decides whether you can proceed at all. Read 13.1 first in either case.

## 13.1 Before you add anything

### Addressing — the scheme already reserves it

The tens digit is the function and the last digit is the host, so a fourth node needs no new design:

| Node | Management | vMotion | NVMe path A | NVMe path B | VLAN 2002 |
|---|---|---|---|---|---|
| `lab-esxi04` | `100.66.69.124` | `100.66.69.134` | `100.66.69.144` | `100.66.69.154` | — |
| `ceph04` | `100.66.69.204` | — | — | — | `100.66.66.204` |

Add the new name to **every** hosts file before you start — the master list in 1.4, `hosts-guard`'s `REQUIRED` array on vCenter (2.1), and the `add` block in `/etc/rc.local.d/local.sh` on all existing ESXi hosts (1.5, 4.x.7). A node that other machines cannot resolve joins and then misbehaves in ways that look like network faults.

### The R450 memory budget — this is the blocker for `lab-esxi04`

0.5 accounts for 63.5 GiB with roughly 6 GiB of headroom:

| Item | RAM | Reserved |
|---|---|---|
| ESXi hypervisor overhead | ~5 GiB | — |
| `vcenter803` | 16 GB | no |
| `stor-gw01` | 12 GB | yes |
| `lab-esxi01`–`03` | 24 GB | yes |
| **Current total** | **~57 GiB** | ~6 GiB headroom |

**A fourth nested host at 8 GB takes it to ~65 GiB, which does not fit.** And 8 GB is the floor — ESXi 8 will not install below it, and a nested ESXi guest has no balloon driver, so the memory cannot be reclaimed under pressure. Overcommitting here does not degrade gracefully; it fails.

So `lab-esxi04` requires freeing memory first. The options, in the order I would take them:

| Option | Frees | Cost |
|---|---|---|
| Reduce `vcenter803` to 12 GB | 4 GB | Sized for ~200 VMs; this lab runs a handful. Check the minimum for your deployment size before setting it |
| Reduce `stor-gw01` to 8 GB and the ARC cap to 4 GB | 4 GB | Smaller ZFS cache. The NFS datastores are used for nested host boot disks, not hot I/O |
| Both | 8 GB | Comfortable at four nested hosts |
| Build `lab-esxi04` and retire one existing host | 0 | Keeps the budget but defeats the point |

Decide this before building anything. A nested host that cannot power on because the R450 is out of memory is a confusing place to discover an arithmetic problem.

```
# ===== RUN ON: esxi8-dell-r450 (100.66.69.101) =====
esxcli hardware memory get
vim-cmd vmsvc/getallvms
```

Audit that list. Anything registered and not in the table above spends headroom, `dev-check-vm` included.

### Ceph capacity — what a fourth node buys

`ceph04` has no R450 dependency; it is a Proxmox VM. Two more 208 GB OSDs take the cluster from 6 to 8:

| | Now | With `ceph04` |
|---|---|---|
| OSDs | 6 | 8 |
| Raw | 1.2 TiB | ~1.6 TiB |
| `MAX AVAIL` at `size=3` | 390 GiB | ~520 GiB |
| Host failure domains | 3 | 4 |

The fourth failure domain matters more than the capacity. At `size=3` across three hosts, every host holds a replica of everything and one host down means no spare home for re-replication. With four hosts, Ceph can fully recover from one host loss while still holding three copies.

## 13.2 Adding `lab-esxi04`

**Prerequisite:** the memory decision in 13.1 is made and the memory is actually free.

### Step 1 — build the node

Follow **4.3 in full**, substituting `lab-esxi04` and its addresses throughout. The section is self-contained by design; every step applies unchanged:

| 4.3 step | Value for `lab-esxi04` |
|---|---|
| Install and first boot | `100.66.69.124/24` |
| Confirm vmnic order | five vNICs, all on the existing port groups |
| Identity and time | `lab-esxi04`, NTP `100.66.69.105` |
| vSwitches and failover | identical — `vSw-vMotion`, `vSw-NVMeA`, `vSw-NVMeB`, `vSwitch2` |
| VMkernel ports | vmk1 `100.66.69.134`, vmk2 `100.66.69.144`, vmk3 `100.66.69.154` |
| NVMe/TCP adapters | identical; record the new Host NQN |
| Persistence | identical, plus `add 100.66.69.124 lab-esxi04` in the block |
| **Reboot** | **mandatory, before vCenter** |
| Post-reboot gate | identical |

The VM specification is 4.2 unchanged: 4 vCPU with hardware virtualization exposed, 8 GB reserved, 40 GB thin PVSCSI, EFI with Secure Boot off, five VMXNET3 adapters — four on `vlan.2001-infa` and one on `vlan.2002`.

### Step 2 — update every other host's hosts file

```
# ===== RUN ON: lab-esxi01, lab-esxi02 and lab-esxi03, each in turn =====
vi /etc/rc.local.d/local.sh
```

Add `add 100.66.69.124 lab-esxi04` to the block, then:

```
# ===== RUN ON: lab-esxi01, lab-esxi02 and lab-esxi03, each in turn =====
sh /etc/rc.local.d/local.sh
grep lab-esxi04 /etc/hosts
/sbin/auto-backup.sh
```

And on vCenter, add it to `hosts-guard`'s `REQUIRED` array (2.1) — not just to `/etc/hosts`, which gets regenerated:

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
vi /usr/local/sbin/hosts-guard.sh
```

```bash
# ===== RUN ON: vcenter803 (100.66.69.110), in the appliance shell =====
/usr/local/sbin/hosts-guard.sh
getent hosts lab-esxi04
getent hosts 100.66.69.124
```

### Step 3 — authorise its NQN and connect the storage

```
# ===== RUN ON: lab-esxi04 (100.66.69.124) =====
esxcli nvme info get
```

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph nvmeof host add --nqn nqn.2016-06.io.spdk:lab01.gw-lab --host_nqn 'nqn.2014-08.local.vsphere:nvme:lab-esxi04'
ceph nvmeof host list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

Paste what `esxcli nvme info get` printed; do not assume the hostname suffix.

```
# ===== RUN ON: lab-esxi04 (100.66.69.124) =====
esxcli network vswitch standard portgroup policy failover get -p NVME-A
esxcli network vswitch standard portgroup policy failover get -p NVME-B
esxcli network ip interface tag get -i vmk2
esxcli network ip interface tag get -i vmk3

vmkping -I vmk2 -d -s 1472 100.66.69.201
vmkping -I vmk3 -d -s 1472 100.66.69.203

esxcli nvme adapter list
```

Then connect both adapters to all three gateways, substituting the `vmhba` numbers `adapter list` reported:

```
# ===== RUN ON: lab-esxi04 (100.66.69.124) =====
for ip in 100.66.69.201 100.66.69.202 100.66.69.203 ; do
  esxcli nvme fabrics connect -a vmhba65 -i $ip -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
  esxcli nvme fabrics connect -a vmhba66 -i $ip -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
done

esxcli nvme controller list
esxcli storage core adapter rescan --all
esxcli storage filesystem list | grep lab-nvme
```

Six controllers and all six datastores. No VMFS creation — the filesystems already exist on the namespaces.

### Step 4 — join the cluster and prove vMotion

Add it per 4.7, then **prove vMotion in both directions before letting DRS near it** (4.8):

| Migration | Must succeed |
|---|---|
| `lab-esxi01` → `lab-esxi04` | ✓ |
| `lab-esxi04` → `lab-esxi01` | ✓ |

If the second fails and the first succeeds, `lab-esxi04` was added without its reboot. Reboot it.

### Step 5 — what changes for HA

Admission control is set to tolerate one host failure. With four hosts instead of three, the reserved fraction drops from a third to a quarter, so **usable capacity increases by more than the 8 GB you added**. Nothing needs changing, but re-check:

- **Monitor → vSphere HA → Summary** — still one master, now three slaves
- **Configure → vSphere Availability** — admission control still shows the failover capacity you expect
- vCLS may deploy a third agent VM; leave it alone (2.5)

## 13.3 Adding `ceph04`

No R450 involvement. This is a Proxmox VM joining the existing Ceph cluster.

### Step 1 — build the VM

Identical to 5.1, with the prerequisites that are easy to get wrong:

| Setting | Value | Why |
|---|---|---|
| CPU type | **`x86-64-v3`** or `host` | `kvm64` lacks AVX2/BMI/FMA and `ceph-nvmeof` will not start (E26) |
| RAM | **16 GB** | 2 OSDs plus mon/mgr, plus 8 GiB hugepages if it runs a gateway |
| Disks | `sda` 40 GB OS, `sdb` and `sdc` 208 GB each, unpartitioned | `cephadm` claims the data disks |
| Placement | **a different Proxmox host from `ceph01`–`03`** | A fourth failure domain that shares a hypervisor is not a fourth failure domain |
| OS | Ubuntu 24.04 LTS Server, minimal, on `sda` only | |

Network per 5.2 — `100.66.69.204` on VLAN 2001 and `100.66.66.204` on VLAN 2002, keeping the installer's `50-cloud-init.yaml` with no `match` and no `set-name`.

```bash
# ===== RUN ON: ceph04 (100.66.69.204) =====
lscpu | grep -oE 'avx2|bmi1|bmi2|fma' | sort -u
free -h
lsblk
```

All four CPU flags present, ~15 GiB RAM, `sdb` and `sdc` with no partitions. If `lscpu` stops at `pni`, the VM is still on `kvm64` — fix that before going further.

Then hostname, time, hosts file and SSH exactly as 5.2 does for `ceph01`, plus the new line on the three existing Ceph nodes:

```bash
# ===== RUN ON: ceph01, ceph02 and ceph03, each in turn =====
echo '100.66.69.204  ceph04.vsphere.local ceph04' >> /etc/hosts
getent hosts ceph04
```

### Step 2 — add the host to the cluster

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph cephadm get-pub-key > /tmp/ceph.pub
```

```bash
# ===== RUN ON: ceph04 (100.66.69.204) =====
mkdir -p /root/.ssh && chmod 700 /root/.ssh
# append the key printed above to /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph cephadm check-host ceph04 100.66.69.204
ceph orch host add ceph04 100.66.69.204 --labels _admin
ceph orch host ls
ceph -s
```

The `_admin` label gives it the keyring so `ceph` commands work there too (11.1).

### Step 3 — pin the monitor count before `cephadm` decides for you

**This is the step people miss.** `cephadm` targets five monitors by default and will happily place a fourth on a newly added host. **Four monitors is strictly worse than three** — quorum still requires a majority, so four tolerates exactly one failure just as three does, while adding a daemon and more Paxos traffic. Odd numbers only.

Decide and pin explicitly:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph orch ls --service-type mon
```

To keep three:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph orch apply mon --placement="ceph01,ceph02,ceph03"
ceph orch ps --daemon-type mon
```

To go to five, you need a fifth host; with four, three is the correct answer.

### Step 4 — add the OSDs

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph orch device ls --refresh
ceph orch daemon add osd ceph04:/dev/sdb
ceph orch daemon add osd ceph04:/dev/sdc
ceph osd tree
```

New OSDs come up as class `hdd`, which is correct — do not override it (11.4).

**A rebalance starts immediately.** Ceph moves data onto the new OSDs, and on 10k SAS this takes time and makes the cluster slow. Do it in a window, and never during a performance test:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph -s
ceph osd df tree
```

Watch until PGs return to `active+clean` with no `backfilling` or `recovering`. Throttle it if the cluster is in use:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 1
```

Put those back afterwards, or leave them — slower recovery is often the right production default.

### Step 5 — decide about a fourth NVMe-oF gateway

**Think before you deploy one.** Three gateways means three load-balancing groups, and your six namespaces sit two per group. Adding a fourth gateway creates a fourth group — **and existing namespaces do not migrate into it.** You would have four gateways where three carry all the traffic and one carries none, which is worse than three in every respect except theoretical headroom.

| Choice | Result |
|---|---|
| **Leave three gateways** | Even distribution preserved. `ceph04` contributes capacity and a failure domain. **Recommended** |
| Add a fourth gateway | Four groups; existing namespaces stay in groups 1–3. Only sensible if you also add namespaces in multiples of four and rebalance the existing ones |

If you do add one:

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph orch apply nvmeof --pool nvmeof-cfg --group gw-lab --placement="ceph01,ceph02,ceph03,ceph04"
ceph orch ps --daemon-type nvmeof
ceph nvmeof listener add --nqn nqn.2016-06.io.spdk:lab01.gw-lab --host_name ceph04 --traddr 100.66.69.204 --trsvcid 4420
ceph nvmeof listener list --nqn nqn.2016-06.io.spdk:lab01.gw-lab
```

**A gateway without a listener serves nothing**, and its load-balancing group has nowhere to fail over to — that is what T11 tests. Then connect every ESXi host to the new listener and re-check the distribution:

```
# ===== RUN ON: each nested host =====
esxcli nvme fabrics connect -a vmhba65 -i 100.66.69.204 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme fabrics connect -a vmhba66 -i 100.66.69.204 -p 4420 -s nqn.2016-06.io.spdk:lab01.gw-lab
esxcli nvme controller list
```

Eight controllers per host instead of six.

### Step 6 — verify

```bash
# ===== RUN ON: any Ceph node with the _admin label, inside cephadm shell =====
ceph -s
ceph df
ceph osd df tree
ceph orch host ls
ceph orch ps
ceph osd pool ls detail
```

- [ ] `HEALTH_OK`, PGs `active+clean`, no backfill in progress
- [ ] `mon: 3 daemons` — **not four**
- [ ] `osd: 8 osds: 8 up, 8 in`, class `hdd`
- [ ] `MAX AVAIL` risen from 390 GiB to roughly 520 GiB
- [ ] Distribution still even — `STDDEV` and `MIN/MAX VAR` in `ceph osd df tree`
- [ ] Gateway count matches your decision in Step 5
- [ ] Datastores still visible on every ESXi host

## 13.4 After adding either node

| Check | Where |
|---|---|
| Hosts files updated everywhere | 1.4, 2.1, 1.5, 4.x.7 |
| New node in the routine checks | 10.1 |
| Licence expiry recorded (ESXi only) | 12.6 |
| Capacity figures refreshed | 10.4 |
| Diagram and address table updated | 0.4 |
| Findings log updated | 8.5 |

**And re-run the checks that catch silent faults** (10.1), because a new node is exactly where they recur:

```
# ===== RUN ON: the new ESXi host =====
esxcli network ip interface ipv4 get
for pg in vMotion NVME-A NVME-B vlan.2002; do
  echo "== $pg"
  esxcli network vswitch standard portgroup policy failover get -p $pg | grep -E 'Active Adapters|Standby Adapters'
done
esxcli nvme controller list
```

```bash
# ===== RUN ON: any Ceph node with the _admin label =====
ceph config show osd.6 | grep osd_memory_target
```

That last one matters on a new Ceph node specifically: `cephadm` recalculates `osd_memory_target` across the cluster when host memory changes, and it may re-impose the autotune value that 11.6 pinned.

---

# PART 14 — PATH TO PRODUCTION

## 14.1 The Ceph nodes are already production

Because they were built on separate hardware from the start, `ceph01`–`03` don't need replacing or re-IPing — they graduate from lab to production as they are. What changes is only what runs against them.

Before that happens, decide two things:

- **Gateways stay colocated, or move to dedicated nodes?** T5 is the evidence. Colocated means a node loss takes OSDs and a gateway together; dedicated costs three more machines.
- **Do the OSD disks have power-loss protection?** If the lab ran on whatever was spare, this is the moment to put enterprise flash under it.

## 14.2 Adding the R630s

1. Set the hostnames and hosts files first (12.8), and check the CPU generation: `esxcli hardware cpu list | grep -m1 Brand`
2. Create the production cluster and **set EVC before adding any host** — Intel Broadwell for E5-26xx v4, Haswell for v3. On an empty cluster this is free; later it needs VMs powered off
3. Add them by IP, then follow 13.2 — the same procedure as a new nested host, with their own VMkernel addresses from the reserved block and their own NQNs granted per 13.2 Step 2
4. Configure HA and DRS as in 4.8, with the same isolation addresses

**Know what you're buying into:** Broadwell-EP is deprecated in vSphere 8.0 and discontinued in the next major release, and the R630 isn't listed for ESXi 8 on the compatibility guide. They run, but they can't go to vSphere 9, and you're off-support for hardware issues. Plan replacement before vSphere 8 leaves general support.

## 14.3 What to change for production

| Lab choice | Production |
|---|---|
| `osd_memory_target` 2 GB | 4 GB |
| `--skip-monitoring-stack` | Deploy it, or point Prometheus at the mgr module |
| NTP from the storage gateway | A dedicated source outside the cluster it serves |
| Container images from the internet | A local registry mirror (6.5) |
| Every VMkernel port in `100.66.69.0/24` | A separate storage VLAN and subnet — routed and reachable, just not the management subnet |
| Gateways colocated on Ceph nodes | Dedicated gateway nodes if the budget allows; T5 shows why |
| Nested ESXi hosts at 8 GB | Real hosts with real memory |
| Nested evaluation licences | Real licences |

The storage-VLAN item is the one to push hardest, and T9's result is your evidence for it.

## 14.4 Carrying the findings forward

The findings log from 8.5 is what makes the production build boring. Before every production Ceph or ESXi upgrade, restore the lab to `gate-cluster-up`, run the new version through T3, T10 and T11, and update the log. A lab you can resurrect in ten minutes gets used; one you have to rebuild does not.

---

# APPENDICES

## Appendix A — Master hosts list

```
100.66.69.110  vcenter803.vsphere.local vcenter803
100.66.69.101  esxi8-dell-r450.vsphere.local esxi8-dell-r450
100.66.69.105  stor-gw01.vsphere.local stor-gw01
100.66.69.121  lab-esxi01.vsphere.local lab-esxi01
100.66.69.122  lab-esxi02.vsphere.local lab-esxi02
100.66.69.123  lab-esxi03.vsphere.local lab-esxi03
100.66.69.201  ceph01.vsphere.local ceph01
100.66.69.202  ceph02.vsphere.local ceph02
100.66.69.203  ceph03.vsphere.local ceph03
```

On vCenter, its own line reads `100.66.69.110  100.66.69.110 vcenter803.vsphere.local vcenter803`.

## Appendix B — Port reference

| Port | Protocol | From → To | Purpose |
|---|---|---|---|
| 443 | TCP | Desktop, hosts → vCenter | vSphere Client, API |
| 5480 | TCP | Desktop → vCenter | VAMI |
| 902 | TCP/UDP | vCenter ↔ ESXi | Host management, heartbeat |
| 8000 | TCP | ESXi ↔ ESXi | vMotion |
| 8182 | TCP/UDP | ESXi ↔ ESXi | vSphere HA |
| 22 | TCP | Backup host → ESXi | SSH |
| 111, 2049 | TCP/UDP | R450 → stor-gw01 | NFS |
| 123 | UDP | All → stor-gw01 | NTP |
| 8022 | TCP | Desktop, Ceph ↔ Ceph | SSH / cephadm |
| 3300, 6789 | TCP | Ceph clients → MONs | Ceph monitors |
| 6800–7568 | TCP | Ceph ↔ Ceph | OSD / MGR |
| 4420 | TCP | ESXi → gateways | NVMe/TCP data |
| 8009 | TCP | ESXi → gateways | NVMe discovery |
| 5500 | TCP | Ceph ↔ gateways | Gateway gRPC |
| 8443 | TCP | Desktop → Ceph MGR | Ceph dashboard |
| 9283 | TCP | Prometheus → Ceph MGR | Ceph metrics |
| 9090 | TCP | Desktop → stor-gw01 | Cockpit |

## Appendix C — Change log template

```text
Date:        YYYY-MM-DD HH:MM (Asia/Dhaka)
Operator:
Scope:       vCenter | r450 | lab-esxi0N | ceph0N | stor-gw01
Change:
Pre-checks:  vc-health OK / ceph HEALTH_OK / zpool OK / backups OK
Rollback:    snapshot name / backup id / boot bank
Result:
Follow-up:
```

## Appendix D — What was dropped from the earlier guides

| Dropped | Why |
|---|---|
| Ceph as VMs on the R450 | The host has 63.5 GiB; that design needed ~128 GB |
| Internal vSwitches and `10.x` subnets (`StorageNet`, fabric A/B, Ceph public) | You can't change the R450's switching, and everything must be reachable from your desktop |
| New `LAB-MGMT` / `LAB-SVC` port groups | Same reason — the lab now adds nothing to the R450 |
| Firewall sections on stor-gw01 and the Ceph nodes | Not wanted here |
| Source-based routing on dual-homed Linux VMs | Your desktop is on-link in both VLANs |
| The 5-node / R740xd2 production Ceph design | Superseded by 3 nodes |
| VMware Workstation lab | Superseded by the nested lab on the R450 |
| Jumbo frames | MTU stays 1500 until a physical VLAN supports it end to end |
## Appendix E — Build log: what Revision 3 said, and what actually happened

Every row below was found by running the guide against the hardware on 2026-09-28. They are recorded rather than silently corrected, because the reasoning is more useful than the fix.

| # | Revision 3 said | Reality | Fixed in |
|---|---|---|---|
| E1 | `apt` sources live in `/etc/apt/sources.list.d/debian.sources` | The netinst installer wrote the **legacy** `/etc/apt/sources.list`; the `sed` failed with "No such file or directory" | 3.4 handles both layouts |
| E2 | Set the ARC cap, then regenerate the initramfs | The order was reversed during the build, so the cap was absent from the boot image. It looked correct because ZFS's default is half of RAM — the same 6 GB | 3.4 states the order and adds the live write |
| E3 | Nothing about the state of the data disks | All three arrived carrying an **old Proxmox ZFS pool** (`sdX1` + 8 MB `sdX9`). `zpool create` would have needed `-f`, papering over it | 3.6 adds a mandatory `zpool import` check and a wipe procedure |
| E4 | `sgdisk` and `partprobe` assumed present | Neither is on a minimal Debian 13 install. `wipefs -a` alone cleared both GPTs and the PMBR | 3.4 installs `gdisk` and `parted` |
| E5 | "Attach them with Add hard disk → Existing hard disk" | Easy to skip, and the guest then shows only its OS disk. A SCSI controller **cannot** be added to a running VM, so this needs a power-off | 3.2 has the full procedure |
| E6 | Pool `tank`, datasets `prod` and `lab` | Built as `vzfspool` with `pro` and `lab`; every export and datastore path follows | 3.6, 3.7, 10.6 throughout |
| E7 | Storage gateway OS disk 64 GB | Built at 80 GB | 3.1 |
| E8 | `sys-ssd` holds the nested ESXi boot disks | It does not — those live on `r450-zfs-lab`, the NFS datastore. Revision 3 contradicted its own nested-lab section | 0.1 and 10.4 |
| E9 | Roughly 7.4 TB usable | Measured: 10.9 TiB raw, **7.14 TiB available** | 3.6 |
| E10 | Autostart configured in the GUI | Done with `vim-cmd`, which is exact and scriptable, and needs the per-host VMIDs | 3.10 |
| E11 | Nothing about property inheritance | `zfs set sync=... vzfspool` did **not** reach `pro` and `lab`, because both had explicit values already. The root ended up unsafe while the children stayed safe — the opposite of the intent | 3.6 |
| E12 | `nfsd` bound to the VLAN 2001 address | A good addition made during the build, but it binds `nfsd` only; `mountd` and `rpcbind` still answer everywhere | 3.7 |

### Two that are worth reading twice

**E3 is the one that could have cost data.** The disks looked empty in every casual check, and `zpool create -f` would have worked without complaint. The habit that catches it is running `zpool import` — which lists without importing — before creating anything, on any disk whose history you did not personally write.

**E11 is the one that will recur.** ZFS inheritance only flows to properties a child has never had set. Every time you set a property at the pool root and want it everywhere, confirm with `zfs get -r <property> <pool>` rather than assuming. The failure is silent and it reads as if it worked.

### From building `lab-esxi01` (2026-09-29)

| # | Revision 6 said | Reality | Fixed in |
|---|---|---|---|
| E13 | `esxcli network ip interface add -i vmk1 -N vmotion` | Fails with **"The netstack vmotion does not exist."** A fresh ESXi 8.0 U3 install has only `defaultTcpipStack`; the vSphere Client normally creates the vMotion stack for you when you add a vMotion VMkernel through the GUI, and from the CLI you must create it yourself | `esxcli network ip netstack add -N vmotion` is the first line of 4.3.4, 4.4.4 and 4.5.4 |
| E14 | The VM specification table | Four of its settings never appear on the wizard's "Ready to complete" page — hardware virtualization, memory reservation, firmware, and the CD/DVD device. Easy to believe they were applied | 4.2 has a before-you-power-it-on checklist |
| E15 | Nothing about vmnic ordering | The `-u vmnicN` arguments assume adapter order equals vmnic order. It did on host 01, but nothing in the guide said to check | 4.3.2, 4.4.2 and 4.5.2 check it before the uplink commands |
| E16 | Nothing about where the names come from | Reasonable to look for `vmnic0` and `vmk1` in the VM wizard. They are not there — and the GUI route for vmk1–vmk3 actively breaks the design by generating a new MAC | 4.2 |

### From preparing the Ceph nodes (2026-10-01)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E17 | "OS disk + 2 SSDs for OSDs", unspecified | The nodes are **KVM/QEMU VMs**: `sda` 40 GB OS, `sdb` and `sdc` 208 GB each for OSDs, and only a `drive-scsiN` by-id alias — the hypervisor set no serial on the data disks | 5.1 carries the measured layout |
| E18 | `apt install … open-vm-tools` | These are KVM guests, not VMware. `qemu-guest-agent` is the right package | 5.2–5.4 |
| E19 | ~~QEMU virtual disks misreport flash as rotational, so override the OSD class to `ssd`~~ | **Withdrawn — this instruction was wrong.** The Ceph VMs sit on **10k SAS spinning disks**. Ceph classed the OSDs `hdd` because they *are* `hdd`. Overriding the class would have produced a CRUSH map that lies and performance figures that mean nothing | 5.7 renames the rule `hdd-rule` and states when an override is legitimate |
| E20 | Six namespaces at 50 GB | 50 GB × 6 × 3 replicas = 900 GB of 1,248 GB raw — 72%, past the threshold this guide's own 9.4 calls "act now". Measured capacity makes 25 GB the right size | 5.1 and 6.4 |
| E21 | Ceph, NVMe-oF and the ESXi connection in one part | Three stages, three different failure modes, potentially three different people. One gate each | Parts 5, 6, 7 |

**E19 is the one worth reading twice**, because the error was mine and it is the kind that propagates. A plausible general fact — QEMU disks often do present as rotational — was applied to a build where it did not hold, and the instruction it produced would have silently invalidated every performance measurement taken afterwards. `ceph osd tree` is not the thing to correct; it is the thing to believe, after you have checked what the disks actually are.

### From configuring the Ceph nodes' networking (2026-10-01)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E22 | Write `/etc/netplan/60-lab.yaml`, then `rm /etc/netplan/50-cloud-init.yaml` | The Ubuntu installer already wrote a correct file. Replacing it is work for no benefit — and on a VM whose cloud-init is *not* disabled, the deletion is undone on the next boot while the hand-written file quietly conflicts with the regenerated one | 5.2–5.4 verify and keep what the installer wrote |
| E23 | Pin each interface with `match: {macaddress: …}` and `set-name` | `set-name` is cosmetic. `match` binds to the MAC — correct on bare metal, wrong on a Proxmox VM, where cloning regenerates MACs and a non-matching stanza leaves the node with no network at all. Interface-name binding fails more gracefully here | 5.2, with the trade-off stated |

### From bringing up NVMe-oF and connecting ESXi (2026-10-04)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E24 | `esxcli network vswitch standard uplink add` is enough to put a NIC behind a vSwitch | It adds the uplink but can leave it **Standby with no Active adapter**. It did so on every storage and vMotion vSwitch on every nested host. IP traffic is unaffected — `vmkping` is clean — but NVMe/TCP resolves its source VMkernel port through the portset's *active* teaming member, so `fabrics connect` fails with `Failed to get source vmknic` | Every node section's `.4` subsection sets `policy failover set --active-uplinks=` after every `uplink add`, and its `.9` gate verifies it; 7.6 is the decision tree |
| E25 | Two VMkernel ports cannot share a subnet with `vmk0`; production needs two storage subnets | **Withdrawn.** `vmk2` `.141` and `vmk3` `.151` both carry NVMe/TCP to all three gateways while `vmk0` owns the `100.66.69.0/24` route. NVMe/TCP never consults the routing table, so route ownership is irrelevant | 4.1 Condition 2, and 7.2 |
| E26 | Nothing about the Ceph nodes' CPU model | `ceph-nvmeof` 1.7 runs on Rocky Linux 10, which requires **x86-64-v3**. Proxmox's default `kvm64` stops at `pni`. The cluster builds and runs perfectly, then every gateway lands in `error` with `Fatal glibc error: CPU does not support x86-64-v3` — visible only in the daemon log | 5.1 sets the prerequisite; 6.1 has the late recovery |
| E27 | `ceph orch apply nvmeof nvmeof-cfg gw-lab` | Rejected: `Invalid command: Unexpected argument`. This build takes named flags | 6.1 uses `--pool` and `--group` |
| E28 | Hyphenated CLI flags (`--rbd-pool`, `--host-name`, `--load-balancing-group`) | This build uses **underscores** throughout | 6.1 says to check `--help`; 6.3 and 6.4 use the underscore forms |
| E29 | "Add the first three namespaces without the group flag to find out whether your build auto-balances" | It does. 1.7.23 assigns groups round-robin, so six namespaces land two per group with no flag at all | 6.4 records the measured behaviour and keeps the check |
| E30 | Block size defaults to 512, so nothing to do | True, but a default is not an intent. Set it explicitly so the requirement is visible in the command rather than inherited | 6.4 passes `--block_size 512` |
| E31 | Nothing about gateway resource consumption | SPDK is a polled-mode target: `nvmf_tgt` sits at 100% on every assigned core regardless of load, and the gateway reserves **8 GiB of hugepages** per node. On 4 vCPU and 11 GB that is the whole VM | 5.1 raises RAM to 16 GB and drops `osd_memory_target` to 1 GiB; 6.1 explains both and gives the `--lcores` tuning |
| E32 | Nothing about the `Active` column in `listener list` | It read `True` for `ceph01` and `False` for the other two while all three were serving traffic. Verify with `ss -tlnp` and `nc`, not with the column | 6.3 |
| E33 | Nothing about `NVMeoFInterfaceDuplex` | `ethtool` reports `Speed: Unknown!` on a virtio NIC because there is no physical link. A lab artefact here, a real alert on physical hardware | 6.3 |
| E34 | Nothing about the ESXi hosts file or SSH surviving a reboot | `/etc/hosts` is regenerated from ConfigStore at every boot and `auto-backup.sh` does not save manual entries. SSH and the ESXi Shell default to manual start and are switched off again by their timeouts | 1.5 on the R450; each node section's `.7` subsection on the nested hosts |

### The ones that cost the most time

**E24 took an afternoon**, and the reason is worth recording: every diagnostic that was easy to run reported success. `vmkping` passed, the route table was correct, the tag was present, the target was listening, and the physical R450 connected to the same subsystem first time. Five hypotheses were tested and eliminated — a `vmxnet3` limitation, the MAC override, a stale adapter, route-table ownership, and two ports in one subnet — before anyone printed the failover policy. The lesson is specific: **when a storage path fails and the network looks perfect, print the port group's teaming policy before theorising.**

**E24 also produced E25.** One of the eliminated hypotheses was promoted to a conclusion and written into Revision 9 as a production requirement for two storage subnets. It was wrong, and it would have put an unnecessary VLAN into the R630 design. A hypothesis that merely failed to be disproved is not a finding.

### From forming the cluster and adding the application VLAN (2026-10-04)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E35 | Nothing about Cluster Quickstart | Creating a cluster puts a **Configure cluster** button in front of you that builds a vDS and migrates every VMkernel port onto it. On nested hosts that dismantles the MAC-matching, the `NVMeTCP` tags and the active-uplink policy in one action, and can drop management connectivity mid-migration | New 2.4 — skip it, with the reasoning |
| E36 | Nothing about vCLS | Two VMs named `vCLS-<uuid>` appear on their own and cannot be deleted. They also silently consumed ~750 MB on `lab-nvme-ds06`, which looked like unexplained usage | New 2.5 — what they are and how to pin their datastore |
| E37 | "Nested test VMs have no network adapter; giving them one would need a port-group change" | Half right. Guest MACs cannot use the MAC-matching trick, so guest traffic **does** need promiscuous mode and forged transmits — but `vlan.2002` already permits both, inherited from `vswitch2`. No change to the R450 was needed | 4.1 Condition 3 |
| E38 | `nested-shared` carries HA until Ceph exists | Ceph is built before the cluster is finished, so the scaffold never had a job. Ceph-only is also the more faithful test, since production will have Ceph and nothing else | Part 4's opening, and 4.8 |
| E39 | The node gate checked port groups, MACs, tags and pings | None of those notice a **missing VMkernel port**. `lab-esxi03` joined the cluster with no `vmk1` at all, and every other check passed | Each node section's `.5` — count the rows, expect four |
| E40 | `DC-LAB` / `CL-LAB` | The live objects are `DC-DEV` and `VCLOUD` | Renamed throughout |

**E37 is the one that changes the lab's reach.** The no-network-adapter decision shaped Part 8: in-guest load had to be generated with `dd` because nothing could be installed into a VM with no network. With `fio` available, storage tests can specify queue depth, block size and read/write mix — which is the difference between "it did not stall" and an actual characterisation.

**E39 is the cheapest lesson here.** Four `esxcli` calls looked at port groups, uplinks, tags and MACs and all passed. One call that simply counted the VMkernel ports would have caught it immediately. When a gate inspects attributes, make sure something also inspects existence.

### From day-2 operations (2026-10-05)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E41 | Nothing about growing a datastore | It spans four layers and the ordering is not optional. Resizing the RBD image alone leaves the gateway advertising the old size, and the symptom surfaces two layers later as a VMFS grow that fails for no visible reason | New 10.5 |
| E42 | Nothing about `partedUtil`'s GPT warning | Growing a device leaves the GPT backup header at the old end. `partedUtil` reports this as `Error:` and `Warning:`, then fixes it and proceeds. It reads like a failure and is not | 10.5 |
| E43 | Plan capacity against raw TB | `MAX AVAIL` is the only number that matters, and on this cluster it is **390 GiB** against 1.2 TiB raw — `size=3` plus the full-ratio reserve | 10.5 |
| E44 | 5.7 sets `osd_memory_target` to 1 GiB | `cephadm`'s `osd_memory_target_autotune` is on by default and **overrode it to 411 MB**, below Ceph's own 896 MiB minimum. The gateway's 8 GiB hugepage reservation is what starves the calculation. Any performance number taken in that state is meaningless | New 11.6 |
| E45 | The PG autoscaler manages pool sizing | It has **never run on this cluster**. `.mgr` uses `replicated_rule` (root `default`, -1) while the other pools use `hdd-rule` (shadow root `default~hdd`, -2); overlapping roots make the autoscaler skip every pool. `autoscale-status` returns an empty list, which looks like a broken command and is a correct report | New 11.5 |
| E46 | `ceph` commands run on `ceph01` | Any host with the `_admin` label works — the CLI talks to the monitors, not the manager. `ceph03` had no label until it was added. The one genuine exception is `cephadm logs`, which reads the **local** journal | 11.1 |
| E47 | Nothing about the `cephadm shell` prompt | Inside the container there is no admin keyring, no host log tree and no container engine. The prompt (`/#` versus `~#`) is the only indication, and it cost time twice | 11.1 |

**E44 and E45 share a shape worth naming.** Both are settings that the system quietly overrides or declines to apply, while every status command keeps reading `HEALTH_OK`. Neither produces a warning. The only way either surfaces is by comparing what you configured against what is *effective* — `ceph config show osd.0` rather than `ceph config get`, and the manager's own log rather than the command's output. Add that comparison to the monthly checks; it is the class of fault that silently invalidates results.

### From proving vMotion (2026-10-05)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E48 | A VMkernel port on the `vmotion` netstack with the `VMotion` tag is ready for live migration | **Not until the host has rebooted.** The vmkernel's vMotion server binds its TCP/IP stack when it initialises; if no vMotion vmknic existed at boot it binds `defaultTcpipStack` and keeps that binding. `esxcli network ip netstack list`, `interface list`, `tag get` and `vmkping -S vmotion` all pass, and migration fails with `Failed to start migration: Networking stack mismatch`. Only `vmkernel.log` names it: `Migration instance: vmotion.  Server instance: defaultTcpipStack.` | 4.1 Condition 4; a mandatory reboot in 4.3.8, 4.4.8 and 4.5.8, before any host joins vCenter |
| E49 | `esxcli network ip interface ipv4 set` manages an interface's routing | It manages the **interface**, not the netstack's routes. `lab-esxi02` carried an extra `default via 100.66.69.198` in the `vmotion` stack's table; re-running `ipv4 set` with no gateway did not remove it, because netstack routes are a separate object — `esxcli network ip route ipv4 remove -N vmotion …`. It was also not the fault: the route was a red herring chased before the log was read | 4.6 checks the `vmotion` route table and says what to do about it |

**E48 is the one that cost the most on this revision, and the method failure is worth recording.** Two hypotheses were formed from configuration output and tested — netstack tags, then the stray default route — before anyone opened `vmkernel.log`. Both were wrong, and neither *could* have been right, because every configuration command had already reported the configuration as correct. When the configuration is correct and the operation still fails, the remaining difference is runtime state, and no config command can see runtime state. **Read the log first** in that situation; it is the only thing that reports what the running kernel actually bound.

**E48 and Condition 2 are the same fault in different clothing.** A Standby uplink with no Active adapter passes every IP test and breaks NVMe/TCP. A vMotion server bound to the wrong stack passes every network test and breaks live migration. Both are runtime state that no `get` command exposes. The guide's response to both is the same: reboot each host before it is trusted, and verify the thing that actually matters — a connect, a migration — not the configuration that should produce it.

### From writing down the failure modes (2026-10-05)

| # | Earlier revisions said | Reality | Fixed in |
|---|---|---|---|
| E50 | 5.1, 6.4 and 7.5 build 25 GiB datastores; 10.5 grows them to 40 | The live platform was grown because it already existed, not because growing is the right build order. A reader rebuilding from the guide would have built small and then run a four-layer expansion for no reason | 5.1, 6.4 and 7.5 build at **40 GiB** directly; 10.5 stays as the expansion runbook for when you genuinely need it |
| E51 | Nothing about what a node loss actually does | The two tiers fail in **opposite shapes** — a Ceph node pauses a VM and preserves its memory, an ESXi host kills it and cold-boots it elsewhere — and the guide described neither. The natural assumption, that Ceph is the more serious loss, is only half right | New 12.10, 12.11 and 12.12 |

**E51 carries a coupling worth naming.** HA's APD response is set to *Power off and restart VMs*, so if an ANA handover ever exceeds the APD timeout, a Ceph node failure stops being a pause and becomes an HA event — the gentle failure and the harsh one are separated only by gateway failover speed. T3 and T5 are what reveal which one this platform has, and **both are still unrun**. Until then, every timing statement in 12.10 and 12.11 is a design expectation, not a measurement, and the guide says so in place.

### Still open

- **`dev-check-vm`** (a VM registered on `sys-ssd`, outside this plan) has not been accounted for in the 0.5 memory budget. Delete it or confirm it stays powered off before the three nested hosts are built.
- **A spare 447 GB SSD** (10.6). The R450 has no free bay, so a boot-SSD failure is a replace-in-place, and the difference between a same-day rebuild and a week of waiting is one disk on a shelf.
- **Where the three Ceph VMs run.** If all three sit on one hypervisor host, `size=3` across three Ceph hosts does not protect you — losing that one machine stops I/O. Spread them across three physical hosts, or record it as a lab artefact (5.1). **This is the one correlated failure in 12.12.4 that costs nothing to fix, and it should be settled before T5 runs** — otherwise T5 measures a failure mode you do not have.
- **Production datastore layout** — 7.7 recommends 12 namespaces of 2 TB for the ~200 VM target. Confirm against the real capacity once the production Ceph hardware is specified.
- **Storage fabric design for the R630s** — a single subnet works (E25), so two subnets is now a choice rather than a requirement. Two separate fabrics on separate physical switches is still the better production pattern; decide deliberately.
- **The PG autoscaler is disabled by overlapping CRUSH roots** (11.5). Moving `.mgr` onto `hdd-rule` fixes it and moves no data. Decide whether to do it, or to run with fixed PG counts deliberately.
- **`osd_memory_target` autotune** (11.6) — confirm the effective value, and on production hardware size the nodes so autotune lands sensibly rather than pinning it.
- **`vzfspool/nested` on `stor-gw01`** is left over from the retired `nested-shared` scaffold. Nothing mounts it. Destroy it or leave it; it costs nothing either way.
- **`vmk0`'s gateway is `100.66.69.198`** — the management workstation, which does not route. Harmless, because everything is on-link, and 4.8's `das.*` overrides mean HA ignores it. The guide specifies `100.66.69.105`. Level it out when convenient, on all three hosts at once.
- **`vmk1`'s gateway is inconsistent** — `0.0.0.0` on hosts 01 and 03, `100.66.69.198` on host 02, and `lab-esxi02` additionally carries a default route inside the `vmotion` stack's own table. All vMotion traffic is on-link, so none of it matters functionally, and it was *not* the cause of the migration failure (E49). Level it out with `esxcli network ip route ipv4 remove -N vmotion -n default -g 100.66.69.198` when convenient.
- **No fourth node exists yet.** Part 13 is written from the design and from what the first three builds taught, not from a fourth build. Expect to correct it the first time it is used, and record what differed.
- **One NVMe controller negotiated a smaller queue.** On `lab-esxi03`, the controller to `100.66.69.203` on `vmhba66` came up with IO Queue Size 64 where every other controller on every host got 128. Disconnect and reconnect that one controller if you want it even; record it either way, because an asymmetric path is worth knowing about before you interpret a latency result.
- **The nested port group is named `vlan.2002`, same as the R450's** (4.1, Condition 3). Every other nested object has a deliberately distinct name so a wrong-shell paste fails harmlessly. This one does not.