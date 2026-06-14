# kvm2pve

Low-downtime KVM/Virtualizor to Proxmox disk migration helper.

This repository now uses the tested QMP workflow:

```text
blockdev-add target NBD node
block-dirty-bitmap-add
blockdev-backup sync=full
blockdev-backup sync=incremental
final incremental during cutover
```

`drive_mirror` and old `virsh blockcopy --pivot` are not used in the new workflow.

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
examples/kvm2pve.env.example   Example shared config
kvm2pve.sh                     Legacy wrapper notice
```

## Quick start

Copy the example config on both hosts:

```bash
cp examples/kvm2pve.env.example kvm2pve.env
```

Edit the basic values first:

```bash
VM_NAME=kvm3023
PVE_HOST=10.0.0.10
PVE_VMID=2672
PVE_DISK=/dev/pve/vm-2672-disk-0
```

Then on the source host run discovery. It parses `virsh qemu-monitor-command VM --hmp "info block"`, shows the detected disk/device/node, and asks before writing them to `kvm2pve.env`:

```bash
./kvm2pve-src.sh discover
```

On destination Proxmox:

```bash
./kvm2pve-dst.sh show
./kvm2pve-dst.sh export
```

On source:

```bash
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh watch
```

When full sync is completed:

```bash
./kvm2pve-src.sh final
```

Then on destination:

```bash
./kvm2pve-dst.sh close
./kvm2pve-dst.sh boot
```

## Source commands

```bash
./kvm2pve-src.sh init
./kvm2pve-src.sh discover
./kvm2pve-src.sh show
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh incremental
./kvm2pve-src.sh final
./kvm2pve-src.sh watch
./kvm2pve-src.sh status
./kvm2pve-src.sh cleanup
./kvm2pve-src.sh stop-source
```

## Destination commands

```bash
./kvm2pve-dst.sh init
./kvm2pve-dst.sh show
./kvm2pve-dst.sh export
./kvm2pve-dst.sh close
./kvm2pve-dst.sh boot
./kvm2pve-dst.sh status
```

## Important notes

During full sync, the VM may keep running. Guest OS reboot normally does not break the QMP job because the QEMU process stays alive.

During final cutover, lock the VM in the customer/Virtualizor panel before suspending it. Disable reboot, shutdown, power off, and VNC/power controls if possible.

Do not shut down the source VM before final incremental. If QEMU exits, QMP disappears and the final incremental cannot run.

## Safe production sequence

```text
1. Prepare destination VM disk on Proxmox
2. Export destination disk with qemu-nbd
3. Create SSH tunnel from source to destination NBD
4. Add destination NBD as QEMU block node
5. Create dirty bitmap on source disk node
6. Run full sync while VM is running
7. Wait until full sync completes
8. Lock customer panel controls
9. Suspend source VM
10. Run final incremental
11. Stop source VM
12. Close qemu-nbd export
13. Boot destination VM
14. Validate guest services
```

## Monitoring without jq

The source script uses only `awk` for progress output, so it works on old servers without installing `jq`.

## Warning

This tool writes directly to the destination VM disk via qemu-nbd. Use only with a prepared destination disk. Do not point it at a disk containing data you need.
