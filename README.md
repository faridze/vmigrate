# kvm2pve

KVM/libvirt to Proxmox disk migration helper.

## Current workflow

1. Export target disk on Proxmox using qemu-nbd (localhost only)
2. Create SSH/autossh tunnel
3. Run virsh blockcopy from source disk to destination NBD export
4. Suspend source VM and perform pivot
5. Create/start Proxmox VM configuration
6. Verify VM
7. Cleanup source VM manually

## WARNING

Test on a small VM first.
This tool migrates the disk. It does not perform full RAM/CPU live migration.

## Quick start

```bash
cp config.example config.txt
./kvm2pve.sh init
./kvm2pve.sh preflight
./kvm2pve.sh migrate
```

## Commands

```bash
./kvm2pve.sh init
./kvm2pve.sh preflight
./kvm2pve.sh show
./kvm2pve.sh migrate
./kvm2pve.sh cleanup-source
```
