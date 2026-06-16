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
```

## Recommended start

On the source host, run discovery with the VM name:

```bash
./kvm2pve-src.sh discover kvm3023
```

If `kvm2pve.env` does not exist, the script asks for the destination values first:

```text
Proxmox host/IP
Destination VMID
Destination disk path
NBD port
NBD export name
```

Then it reads:

```bash
virsh qemu-monitor-command VM_NAME --hmp "info block"
```

It auto-detects and shows:

```text
SRC_DISK
QEMU_DEVICE
QEMU_NODE
```

After confirmation, it writes those values to `kvm2pve.env`.

You can also run without an argument and let it ask the VM name:

```bash
./kvm2pve-src.sh discover
```

## Quick handoff workflow

Use `handoff` after destination discovery to copy only the destination values
that the source must match: `PVE_VMID`, `PVE_DISK`, `NBD_PORT`, and
`NBD_EXPORT`.

Destination:

```bash
./kvm2pve-dst.sh discover 2679
./kvm2pve-dst.sh handoff
```

Example output:

```text
KVM2PVE_HANDOFF_V1:UFZFX1ZNSUQ9MjY3OQpQVkVfRElTSz0vZGV2L3B2ZS92bS0yNjc5LXh4eHgKTkJEX1BPUlQ9MTA4MDkKTkJEX0VYUE9SVD12bS0yNjc5Cg==
```

Source:

```bash
./kvm2pve-src.sh discover kvm3023
./kvm2pve-src.sh apply-handoff 'KVM2PVE_HANDOFF_V1:UFZFX1ZNSUQ9MjY3OQpQVkVfRElTSz0vZGV2L3B2ZS92bS0yNjc5LXh4eHgKTkJEX1BPUlQ9MTA4MDkKTkJEX0VYUE9SVD12bS0yNjc5Cg=='
./kvm2pve-src.sh show
```

`apply-handoff` updates only `PVE_VMID`, `PVE_DISK`, `NBD_PORT`, and
`NBD_EXPORT` in `kvm2pve.env`. It does not overwrite source-side values such
as `VM_NAME`, `SRC_DISK`, `QEMU_DEVICE`, `QEMU_NODE`, `BITMAP`, or
`TARGET_NODE`, and it does not set `PVE_HOST` or `PVE_SSH_PORT`.

## Migration workflow

Destination:

```bash
./kvm2pve-dst.sh discover 2679
./kvm2pve-dst.sh handoff
./kvm2pve-dst.sh show
./kvm2pve-dst.sh preflight
./kvm2pve-dst.sh export
```

Source:

```bash
./kvm2pve-src.sh discover kvm3023
./kvm2pve-src.sh apply-handoff 'KVM2PVE_HANDOFF_V1:...'
./kvm2pve-src.sh show
./kvm2pve-src.sh preflight
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-status
./kvm2pve-src.sh tunnel-check

./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target

./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap

./kvm2pve-src.sh full
./kvm2pve-src.sh watch
```

Cutover:

```bash
./kvm2pve-src.sh check-paused
./kvm2pve-src.sh final
./kvm2pve-src.sh stop-source
```

Destination:

```bash
./kvm2pve-dst.sh close
./kvm2pve-dst.sh boot
```

## Source commands

```bash
./kvm2pve-src.sh discover [VM_NAME]
./kvm2pve-src.sh init
./kvm2pve-src.sh show
./kvm2pve-src.sh apply-handoff HANDOFF_TOKEN
./kvm2pve-src.sh preflight
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-status
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh incremental
./kvm2pve-src.sh check-paused
./kvm2pve-src.sh final
./kvm2pve-src.sh watch
./kvm2pve-src.sh status
./kvm2pve-src.sh cleanup
./kvm2pve-src.sh stop-source
```

## Destination commands

```bash
./kvm2pve-dst.sh discover [VMID]
./kvm2pve-dst.sh init
./kvm2pve-dst.sh show
./kvm2pve-dst.sh handoff
./kvm2pve-dst.sh preflight
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
2. Run source discovery and confirm config
3. Export destination disk with qemu-nbd
4. Create SSH tunnel from source to destination NBD
5. Check tunnel status and validate the NBD export
6. Add destination NBD as QEMU block node
7. Create dirty bitmap on source disk node
8. Run full sync while VM is running
9. Wait until full sync completes
10. Lock customer panel controls
11. Suspend source VM
12. Verify source VM is paused
13. Run final incremental
14. Stop source VM
15. Close qemu-nbd export
16. Boot destination VM
17. Validate guest services
```

## Monitoring without jq

The source script uses only `awk` for progress output, so it works on old servers without installing `jq`.

## Warning

This tool writes directly to the destination VM disk via qemu-nbd. Use only with a prepared destination disk. Do not point it at a disk containing data you need.
