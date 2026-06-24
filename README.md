# vmigrate

Low-downtime KVM/Virtualizor to target disk migration helper.

`vmigrate` runs on the source KVM/Virtualizor host. `vmigrate-agent` runs on the destination Proxmox/target host.

The recommended production workflow is:

```bash
./vmigrate create VM_NAME TARGET_ID TARGET_HOST [SSH_PORT] [SSH_USER]
```

Use placeholders such as `TARGET_HOST`; do not copy example IP addresses into production commands without checking them.

## What create does

`create` is the supported guided workflow. It:

1. Creates a new migration run directory.
2. Makes that run the active run.
3. Prepares the destination automatically over SSH.
4. Runs source and destination checks.
5. Opens the destination NBD export.
6. Creates or reuses a healthy SSH tunnel.
7. Creates the dirty bitmap.
8. Starts FULL sync and waits for completion.
9. Optionally runs a pre-cutover incremental sync.
10. Suspends the source VM and runs final incremental.
11. Asks before stopping the source VM.
12. Asks before closing the destination NBD export and local tunnel.

The source VM remains running until final cutover.

## Run directories

Each `create` run is archived separately:

```text
migrations/<VM_NAME>/<RUN_ID>/
├── run.log
├── config
├── report.pre-full.txt
├── report.after-full.txt
└── report.final.txt
```

Example layout:

```text
migrations/v2698/20260624-013000/run.log
migrations/v2698/20260624-013000/config
```

The selected run is stored in:

```text
.vmigrate-active
```

Normal commands use the active run automatically. If no active run exists, `vmigrate` falls back to the legacy/default `vmigrate.env`.

## Active run commands

List migration runs:

```bash
./vmigrate list
```

Show the active run:

```bash
./vmigrate active
```

Switch to a run by VM and run ID:

```bash
./vmigrate use VM_NAME RUN_ID
```

Switch to a run by directory:

```bash
./vmigrate use migrations/VM_NAME/RUN_ID
```

Clear active run and fall back to `vmigrate.env`:

```bash
./vmigrate clear-active
```

Advanced override:

```bash
VMIGRATE_CONFIG=/opt/vmigrate/migrations/VM_NAME/RUN_ID/config ./vmigrate report
```

## Requirements

Verify SSH from the source host to the destination host:

```bash
ssh -p SSH_PORT root@TARGET_HOST hostname
```

Passwordless SSH is recommended:

```bash
ssh-keygen -t ed25519
ssh-copy-id -p SSH_PORT root@TARGET_HOST
```

Install `autossh` on the source host:

```bash
apt install -y autossh
```

or:

```bash
dnf install -y autossh
```

On the destination, the target VM should be powered off before export:

```bash
qm status TARGET_ID
```

If it is running, `create` asks before stopping it.

## Recommended workflow

Start a migration:

```bash
./vmigrate create VM_NAME TARGET_ID TARGET_HOST [SSH_PORT] [SSH_USER]
```

During the guided workflow, type only the requested confirmations:

```text
YES
FULL
CUTOVER
STOP
CLEAN
```

Use `STOP` only after final cutover has completed and you are ready to stop the source VM.

Use `CLEAN` to close the destination NBD export and local tunnel.

## Reports and logs

During `create`, logs and reports are saved automatically inside the run directory.

Show current run status:

```bash
./vmigrate report
```

Watch active block job progress:

```bash
./vmigrate watch
```

`watch` is read-only. It does not dismiss jobs or change VM/state.

## Manual workflow

For manual operation from the source host:

```bash
./vmigrate remote-prepare VM_NAME TARGET_ID TARGET_HOST [SSH_PORT] [SSH_USER]
./vmigrate doctor
./vmigrate remote-export
./vmigrate tunnel
./vmigrate tunnel-check
./vmigrate bitmap
./vmigrate check-bitmap
./vmigrate full
./vmigrate wait-full
./vmigrate report
```

Cutover:

```bash
./vmigrate cutover-check
./vmigrate final
./vmigrate report
./vmigrate stop-source
./vmigrate remote-dst-close
```

Start the destination VM only after:

- final completed successfully
- source VM is stopped
- destination NBD export is closed

## Optional pre-cutover incremental

After FULL completion and before final cutover:

```bash
./vmigrate incremental
./vmigrate wait-inc
```

This reduces the final delta before the source VM is suspended.

## Job tools

Show block jobs:

```bash
./vmigrate jobs
```

Dismiss concluded jobs:

```bash
./vmigrate jobs-dismiss-all
```

Cancel a running job:

```bash
./vmigrate job-cancel JOB_ID
```

Force-cancel a stuck job:

```bash
./vmigrate job-cancel-force JOB_ID
```

Use force cancel only to abort a stuck or failed migration. The destination disk may be incomplete afterward.

Common job IDs:

```text
full
inc1
final
```

## Tunnel and NBD checks

Normal check:

```bash
./vmigrate tunnel-check
```

By default, `tunnel-check` requires NBD metadata to be reachable.

Optional read sample:

```bash
VMIGRATE_NBD_READ_SAMPLE=1 ./vmigrate tunnel-check
```

If metadata is reachable and FULL sync starts with progress, the tunnel is usable.

If the tunnel/export is stale:

```bash
./vmigrate tunnel-stop
./vmigrate remote-dst-close
./vmigrate remote-export
./vmigrate tunnel
./vmigrate tunnel-check
```

## Destination helper

`remote-prepare` copies `vmigrate-agent` to the destination automatically.

Manual destination commands:

```bash
cd /root/vmigrate
./vmigrate-agent doctor
./vmigrate-agent export
./vmigrate-agent status
./vmigrate-agent close
```

Boot the destination VM only after final cutover and source stop:

```bash
./vmigrate-agent boot
```

## Safety notes

`vmigrate` does not delete disks, remove LVs, wipe filesystems, or undefine VMs.

`stop-source` refuses to stop the source VM unless final cutover completed.

`final` refuses to suspend the source VM unless `cutover-check` passes.

Do not resume the source VM after final cutover unless you are intentionally rolling back.

## Parallel migrations

Multiple migrations on different source hosts are fine.

Multiple concurrent migrations on the same source host are not recommended yet. Run-based config makes tracking safer, but parallel operation still needs separate ports and careful I/O planning.

Recommended production approach:

1. Run FULL syncs one by one.
2. Perform cutovers one by one.
3. Review each run with `./vmigrate list` and `./vmigrate report`.

## Files

```text
vmigrate          Source-side helper
vmigrate-agent    Destination-side helper
migrations/       Per-run logs, config, and reports
.vmigrate-active  Active run pointer
vmigrate.env      Legacy/default fallback config
```

## Legacy UI

The old terminal UI is retained only as legacy/experimental code under `legacy/`. The supported production workflow is the `vmigrate` CLI.
