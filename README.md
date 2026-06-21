# kvm2pve

Low-downtime KVM/Virtualizor to Proxmox disk migration helper.

This repository uses the tested QMP workflow:

```text
blockdev-add target NBD node
block-dirty-bitmap-add
blockdev-backup sync=full
blockdev-backup sync=incremental
final incremental during cutover
```

`drive_mirror`, old `virsh blockcopy --pivot`, and legacy wrapper files are not used.

## Prerequisites

### 1. Verify SSH connectivity

From the source host:

```bash
ssh root@PVE_HOST
```

Example:

```bash
ssh root@5.172.177.66
```

### 2. Configure passwordless SSH (recommended)

```bash
ssh-keygen -t ed25519
ssh-copy-id root@PVE_HOST
```

Verify:

```bash
ssh root@PVE_HOST hostname
```

### 3. Install autossh

Debian / Ubuntu:

```bash
apt update
apt install -y autossh
```

AlmaLinux / Rocky:

```bash
dnf install -y autossh
```

CentOS 7:

```bash
curl -LO https://dl.fedoraproject.org/pub/epel/7/x86_64/Packages/a/autossh-1.4g-1.el7.x86_64.rpm
yum install -y ./autossh-1.4g-1.el7.x86_64.rpm
autossh -V
```

### 4. Verify destination VM is powered off

```bash
qm status VMID
```

The destination VM must not be running during migration.

## Status

Proof-of-concept validation completed:

- QEMU `blockdev-add` works
- QEMU dirty bitmap works
- `blockdev-backup sync=full` works
- `blockdev-backup sync=incremental` works
- final incremental worked after source suspend
- destination Proxmox VM booted after migration test

## Files

```text
kvm2pve-src.sh                 Run on source Virtualizor/KVM host
kvm2pve-dst.sh                 Run on destination Proxmox host
kvm2pve-ui.sh                  Optional whiptail terminal UI
examples/kvm2pve.env.example   Example shared config
```

## Recommended Remote Workflow (Primary Method)

This is the preferred CLI path when the source host can SSH directly to the
destination Proxmox host.

Run from the SOURCE host only:

```bash
./kvm2pve-src.sh remote-prepare kvm3023 5.172.177.66 2679 22 root
./kvm2pve-src.sh preflight
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report
```

Optional monitor:

```bash
./kvm2pve-src.sh watch
```

Cutover:

```bash
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh final
./kvm2pve-src.sh report
./kvm2pve-src.sh stop-source
./kvm2pve-src.sh remote-dst-close
```

Start the destination VM only after:

- final completed successfully
- source VM stopped
- destination export closed

## Alternative Manual Handoff Workflow

Use this path when the source host cannot SSH to the destination Proxmox host.

Destination:

```bash
./kvm2pve-dst.sh quick 2679
```

Follow the printed instructions and use the handoff token manually.

## Handoff Token Format

Destination:

```bash
./kvm2pve-dst.sh discover 2679
./kvm2pve-dst.sh handoff
```

Example output:

```text
KVM2PVE_HANDOFF_V1:...
```

Source:

```bash
./kvm2pve-src.sh apply-handoff 'KVM2PVE_HANDOFF_V1:...'
```

## Terminal UI

```bash
./kvm2pve-ui.sh
```

New Migration now uses the source-driven remote workflow by default.

## Legacy Manual Workflow

This workflow is kept for troubleshooting and advanced manual operations.
For normal migrations use the Recommended Remote Workflow.

## Source Commands

```text
discover
init
show
apply-handoff
remote-prepare
remote-export
remote-dst-status
remote-dst-close
quick
next
preflight
tunnel
tunnel-status
tunnel-check
attach-target
check-target
bitmap
check-bitmap
full
wait-full
mark-full
incremental
cutover-check
check-paused
final
watch
status
report
verify-sample
cleanup
stop-source
```

## Destination Commands

```text
discover
init
show
handoff
quick
preflight
export
close
boot
status
```

## Safe Production Sequence

```text
1. Prepare destination VM disk on Proxmox
2. Run source discovery and confirm config
3. Apply destination handoff or run remote-prepare from source
4. Run source preflight
5. Export destination disk with qemu-nbd using remote-export or destination export
6. Create SSH tunnel from source to destination NBD
7. Check tunnel status and validate the NBD export
8. Add destination NBD as QEMU block node
9. Create dirty bitmap on source disk node
10. Run full sync while VM is running
11. Wait until full sync completes and mark it with wait-full or mark-full
12. Run cutover-check
13. Lock customer panel controls
14. Suspend source VM
15. Verify source VM is paused
16. Run final incremental
17. Stop source VM
18. Close qemu-nbd export
19. Boot destination VM
20. Validate guest services
```

## Warning

This tool writes directly to the destination VM disk via qemu-nbd.
Use only with a prepared destination disk.
Do not point it at a disk containing data you need.

