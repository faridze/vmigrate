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
kvm2pve-ui.sh                  Optional whiptail terminal UI
examples/kvm2pve.env.example   Example shared config
```

## Manual source discovery

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

## Recommended remote workflow

This is now the preferred CLI path when the source host can SSH to the
destination Proxmox host. Run it from the source host only. The source helper
copies `kvm2pve-dst.sh` to the destination, runs destination discovery with
`--yes`, reads the handoff token, applies it locally, then runs source
discovery.

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

Cutover remains explicit:

```bash
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh final
./kvm2pve-src.sh report
./kvm2pve-src.sh stop-source
```

After final:

```bash
./kvm2pve-src.sh remote-dst-close
```

Then boot the destination manually on Proxmox.

`remote-prepare` does not start the NBD export or migration. It only prepares
config, discovery, and handoff:

- writes source config keys
- tests SSH
- creates `/root/kvm2pve` on destination
- copies `kvm2pve-dst.sh` to destination
- runs destination `discover VMID --yes`
- reads destination handoff
- applies handoff locally
- runs source discover
- shows final config and next steps

`remote-export` runs destination preflight/export/status over SSH:

```bash
cd /root/kvm2pve && ./kvm2pve-dst.sh preflight && ./kvm2pve-dst.sh export && ./kvm2pve-dst.sh status
```

Destination `qemu-nbd` uses `--fork`, so once export starts it should survive
the SSH command ending. The source tunnel is still separate and should be
started with:

```bash
./kvm2pve-src.sh tunnel
```

## Alternative manual handoff workflow

Use this path when the source host cannot SSH to the destination Proxmox host.
It starts on the destination and prints each next command with the host where it
must run:

Destination:

```bash
./kvm2pve-dst.sh quick 2679
```

Then follow the printed steps:

```bash
# On source, paste the handoff token printed by destination quick:
./kvm2pve-src.sh quick 'KVM2PVE_HANDOFF_V1:...'

# On destination, start the export:
./kvm2pve-dst.sh preflight
./kvm2pve-dst.sh export

# On source, continue with the quick/next checklist:
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report

# Cutover on source:
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh final
./kvm2pve-src.sh report
./kvm2pve-src.sh stop-source

# Finish on destination:
./kvm2pve-dst.sh close
./kvm2pve-dst.sh boot
```

`quick` keeps dangerous actions explicit. It prepares and verifies the config,
prints the next commands, and leaves `export`, `full`, `final`, `stop-source`,
`close`, and `boot` as deliberate operator commands.

## Terminal UI

Run:

```bash
./kvm2pve-ui.sh
```

Recommended usage:

1. Run UI on destination.
2. Choose Start New Migration > Destination host.
3. Copy the handoff token.
4. Export NBD when prompted.
5. Run UI on source.
6. Choose Start New Migration > Source host.
7. Paste handoff token.
8. Follow guided confirmations.
9. Return to destination.
10. Choose Continue Migration and close + boot.

The UI uses `whiptail` and is optional. The CLI scripts still work directly,
dangerous actions still require confirmation, and the UI does not implement
`resume-full`.

## Manual handoff workflow

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
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report

# Optional monitor in another terminal:
./kvm2pve-src.sh watch
```

Cutover:

```bash
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh final
./kvm2pve-src.sh report
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
./kvm2pve-src.sh remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh remote-dst-status
./kvm2pve-src.sh remote-dst-close
./kvm2pve-src.sh quick [HANDOFF_TOKEN]
./kvm2pve-src.sh quick [VM_NAME] [HANDOFF_TOKEN]
./kvm2pve-src.sh next
./kvm2pve-src.sh preflight
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-status
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh mark-full
./kvm2pve-src.sh incremental
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh check-paused
./kvm2pve-src.sh final
./kvm2pve-src.sh watch
./kvm2pve-src.sh status
./kvm2pve-src.sh report
./kvm2pve-src.sh verify-sample
./kvm2pve-src.sh cleanup
./kvm2pve-src.sh stop-source
```

## Destination commands

```bash
./kvm2pve-dst.sh discover [VMID]
./kvm2pve-dst.sh init
./kvm2pve-dst.sh show
./kvm2pve-dst.sh handoff
./kvm2pve-dst.sh quick [VMID]
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
18. Close qemu-nbd export using remote-dst-close or destination close
19. Boot destination VM
20. Validate guest services
```

## Monitoring without jq

The source script uses only `awk` for progress output, so it works on old servers without installing `jq`.

## Source safety state

The source helper writes a simple marker file next to `kvm2pve.env`, named like
`.kvm2pve-state-VM_NAME`. It stores plain `KEY=VALUE` markers for full sync,
final incremental, and source stop completion.

`full` still only submits the QMP blockdev-backup job. It records
`FULL_STARTED=1`, but it does not mark full as complete. After starting full,
`wait-full` is the recommended way to wait for completion and set
`FULL_COMPLETED=1`:

```bash
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report
```

`mark-full` is only for manual recovery when the operator is sure full completed
successfully and no active block job remains:

```bash
./kvm2pve-src.sh mark-full
```

`incremental` and `final` refuse to run until `FULL_COMPLETED=1` is present in
that state file. If full sync fails, this project does not implement
`resume-full`; the safe path is to restart full sync from scratch.

Before cutover, run:

```bash
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh report
```

`cutover-check` validates the VM, block-job state, target node, bitmap, tunnel,
NBD export reachability, and the full-completed marker without requiring `jq`.

## Warning

This tool writes directly to the destination VM disk via qemu-nbd. Use only with a prepared destination disk. Do not point it at a disk containing data you need.
