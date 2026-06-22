# kvm2pve

Low-downtime KVM/Virtualizor to Proxmox disk migration helper.

The supported production workflow is the CLI in `kvm2pve-src.sh` and
`kvm2pve-dst.sh`. The old whiptail UI is kept only as legacy/experimental code
under `legacy/kvm2pve-ui.sh` and is not part of the supported migration path.

The default production backup method is `drive-backup`, which writes directly to
the destination NBD export. `blockdev-backup` remains available for modern QEMU
block graph workflows, but it requires `attach-target` and `check-target`.

`drive_mirror`, old `virsh blockcopy --pivot`, and wrapper-driven workflows are
not used.

## Prerequisites

### 1. Verify SSH connectivity

From the source host:

```bash
ssh root@PVE_HOST
```

Example:

```bash
ssh root@192.0.2.10
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

## Files

```text
kvm2pve-src.sh                 Run on source Virtualizor/KVM host
kvm2pve-dst.sh                 Run on destination Proxmox host
legacy/kvm2pve-ui.sh           Legacy/experimental terminal UI
examples/kvm2pve.env.example   Example shared config
```

## Supported Remote CLI Workflow

Run from the SOURCE host only. `remote-prepare` writes the remote connection
settings, copies the destination helper over SSH, runs destination discovery,
applies the handoff locally, then runs source discovery. Source discovery writes
`SRC_DISK`, `QEMU_DEVICE`, and `QEMU_NODE` automatically when the source VM has a
single unambiguous disk. If multiple source block devices are found, run
`./kvm2pve-src.sh discover VM_NAME` manually and confirm the correct disk.

Main workflow with the default `drive-backup` method:

```bash
./kvm2pve-src.sh remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]
./kvm2pve-src.sh set-backup-method
./kvm2pve-src.sh preflight
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report
```

Normal tunnel flow:

```bash
./kvm2pve-src.sh remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]
./kvm2pve-src.sh preflight
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
```

For `blockdev-backup` only, run these after `tunnel-check` and before `bitmap`:

```bash
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
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

## Optional Incremental Sync

Run an incremental sync between full sync and final cutover:

```bash
./kvm2pve-src.sh incremental
./kvm2pve-src.sh wait-inc
```

`incremental` submits job `inc1` only. `wait-inc` waits for the block job to
finish and dismisses concluded jobs so they do not block later steps.

## Job Tools

Use these if QEMU reports a running or concluded block job:

```bash
./kvm2pve-src.sh jobs
./kvm2pve-src.sh job-dismiss inc1
./kvm2pve-src.sh jobs-dismiss-all
```

`jobs` prints raw `query-block-jobs` JSON and a short summary. QMP calls use a
timeout so status/report/job commands do not wait forever on a stuck monitor.

## Troubleshooting Tunnel Warnings

If `tunnel-check` prints `OK NBD metadata reachable` but warns that the read
sample failed or timed out, retry once:

```bash
./kvm2pve-src.sh tunnel-check
```

The read sample is a best-effort probe. `qemu-img info` proving the NBD metadata
is reachable is the hard tunnel health requirement.

If `tunnel-check` hangs or fails because an old SSH/autossh forwarder is stale,
restart only the local tunnel and check again:

```bash
./kvm2pve-src.sh tunnel-restart
./kvm2pve-src.sh tunnel-check
```

If that still fails, reset the destination export and rebuild the tunnel:

```bash
./kvm2pve-src.sh tunnel-stop
./kvm2pve-src.sh remote-dst-close
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
```

If `full` hangs after a read sample warning, reset the block jobs and
tunnel/export path:

```bash
./kvm2pve-src.sh jobs
./kvm2pve-src.sh jobs-dismiss-all
./kvm2pve-src.sh remote-dst-close
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
```

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

## Legacy/Experimental Terminal UI

The terminal UI is retained for reference only and is not part of the supported
production workflow:

```bash
./legacy/kvm2pve-ui.sh
```

## Source Commands

```text
discover [VM_NAME] [--yes]
init
show
apply-handoff
remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]
remote-export
remote-dst-status
remote-dst-close
quick
next
preflight
tunnel
tunnel-stop
tunnel-restart
tunnel-status
tunnel-check
attach-target
check-target
bitmap
check-bitmap
full
wait-full
mark-full
set-backup-method
incremental
wait-inc
jobs
job-dismiss JOB_ID
jobs-dismiss-all
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
4. Choose/confirm backup method with set-backup-method
5. Run source preflight
6. Export destination disk with qemu-nbd using remote-export or destination export
7. Create SSH tunnel from source to destination NBD
8. Validate the tunnel and the real NBD export with tunnel-check
9. For blockdev-backup only, add and check the destination target node
10. Create dirty bitmap on source disk node
11. Run full sync while VM is running
12. Wait until full sync completes with wait-full
13. Run optional incremental syncs with incremental and wait-inc
14. Run cutover-check
15. Lock customer panel controls
16. Suspend source VM through final
17. Let final run the final incremental and wait internally
18. Stop source VM
19. Close qemu-nbd export
20. Boot destination VM
21. Validate guest services
```

## Warning

This tool writes directly to the destination VM disk via qemu-nbd. Use only with
a prepared destination disk. Do not point it at a disk containing data you need.

`stop-source` only stops/destroys the source VM. It must never delete disks or
storage.
