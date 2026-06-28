# vmigrate

Low-downtime VM migration helper for KVM/Virtualizor-style source hosts and Proxmox/KVM-style destination hosts.

`vmigrate` runs on the source host. `vmigrate-agent` runs on the destination host and is copied automatically during preparation.

The main goal is to copy a source VM disk to a destination disk with QEMU block jobs, NBD, SSH/autossh tunneling, dirty bitmaps, verification, reporting, cleanup, and safe resume guidance.

Use placeholders such as `VM_NAME`, `TARGET_ID`, `TARGET_HOST`, and `SSH_PORT` in the examples below. Do not put real public IP addresses in shared documentation or scripts.

---

## Quick start: guided migration

Use this when you want the safest guided workflow.

```bash
./vmigrate create VM_NAME TARGET_ID TARGET_HOST SSH_PORT root
```

Example with placeholders:

```bash
./vmigrate create v1001 2001 TARGET_HOST 22 root
```

What it does:

1. Creates a new local run directory.
2. Makes that run active.
3. Creates a per-run workspace on the destination.
4. Copies `vmigrate-agent` to that destination workspace.
5. Discovers the target disk and applies handoff values.
6. Selects an automatic per-run NBD port unless disabled.
7. Checks source and destination readiness.
8. Opens the destination NBD export.
9. Starts or reuses a healthy SSH tunnel.
10. Creates or verifies the dirty bitmap.
11. Starts the FULL sync and waits for completion.
12. Offers optional incremental sync before cutover.
13. Runs final cutover only after explicit confirmation.
14. Asks before stopping the source VM.
15. Asks before cleanup.

During the guided workflow, type only the exact confirmation words when requested:

```text
YES
FULL
CUTOVER
STOP
CLEAN
```

`STOP` should only be used after final cutover completed and you are ready to stop the source VM.

`CLEAN` closes the destination NBD export and local tunnel. It does not delete disks or VM definitions.

---

## Requirements

Run these checks on the source host.

Check SSH access to the destination:

```bash
ssh -p SSH_PORT root@TARGET_HOST hostname
```

Passwordless SSH is recommended:

```bash
ssh-keygen -t ed25519
```

```bash
ssh-copy-id -p SSH_PORT root@TARGET_HOST
```

Install `autossh` on the source host.

Debian/Ubuntu:

```bash
apt install -y autossh
```

RHEL/AlmaLinux/Rocky:

```bash
dnf install -y autossh
```

Check the destination VM status:

```bash
ssh -p SSH_PORT root@TARGET_HOST "qm status TARGET_ID"
```

The destination VM should normally be stopped before NBD export. If it is running, `vmigrate` asks before stopping it.

---

## Run directories and active run

Every migration is stored in a local run directory:

```text
migrations/<VM_NAME>/<RUN_ID>/
```

Typical files inside a run:

```text
run.log
config
summary.txt
report.pre-full.txt
report.after-full.txt
report.final.txt
```

The active run pointer is stored in:

```text
.vmigrate-active
```

Most commands automatically use the active run. If no active run exists, `vmigrate` falls back to the default `vmigrate.env` file.

Show all migration runs:

```bash
./vmigrate list
```

Show the active run:

```bash
./vmigrate active
```

Switch to a run by VM name and run ID:

```bash
./vmigrate use VM_NAME RUN_ID
```

Switch to a run by directory:

```bash
./vmigrate use migrations/VM_NAME/RUN_ID
```

Show the active run config:

```bash
./vmigrate show
```

Clear the active run pointer:

```bash
./vmigrate clear-active
```

Use a specific config without changing the active run:

```bash
VMIGRATE_CONFIG=/opt/vmigrate/migrations/VM_NAME/RUN_ID/config ./vmigrate report
```

---

## Destination per-run workspace

Each migration run gets its own destination workspace:

```text
/root/vmigrate/runs/<VM_NAME>-<RUN_ID>/
```

Typical destination files:

```text
vmigrate-agent
vmigrate.env
```

The local run config stores the remote workspace path as:

```text
REMOTE_RUN_DIR=/root/vmigrate/runs/<VM_NAME>-<RUN_ID>
```

Check that the local run config and remote `vmigrate.env` match:

```bash
./vmigrate remote-run-check
```

Show destination status for the active run:

```bash
./vmigrate remote-dst-status
```

Close the destination NBD export for the active run:

```bash
./vmigrate remote-dst-close
```

List old destination run directories without deleting anything:

```bash
./vmigrate cleanup-remote-runs --dry-run
```

---

## Fast manual workflow

Use this when you want to run each step yourself.

Prepare destination and source discovery:

```bash
./vmigrate remote-prepare VM_NAME TARGET_ID TARGET_HOST SSH_PORT root
```

Review local/remote run consistency:

```bash
./vmigrate remote-run-check
```

Run source-side doctor checks:

```bash
./vmigrate doctor
```

Open or reuse the destination NBD export:

```bash
./vmigrate remote-export
```

Start or reuse the local SSH/autossh tunnel:

```bash
./vmigrate tunnel
```

Check NBD metadata through the tunnel:

```bash
./vmigrate tunnel-check
```

Create the source dirty bitmap:

```bash
./vmigrate bitmap
```

Verify the bitmap exists:

```bash
./vmigrate check-bitmap
```

Start FULL sync:

```bash
./vmigrate full
```

Wait until FULL completes and mark it completed:

```bash
./vmigrate wait-full
```

Show a report:

```bash
./vmigrate report
```

Optional incremental sync before final cutover:

```bash
./vmigrate incremental
```

Wait for incremental sync:

```bash
./vmigrate wait-inc
```

Run final cutover checks:

```bash
./vmigrate cutover-check
```

Run final cutover:

```bash
./vmigrate final
```

Verify sample data after migration:

```bash
./vmigrate verify
```

Stop the source VM only after final cutover completed:

```bash
./vmigrate stop-source
```

Close the remote NBD export:

```bash
./vmigrate remote-dst-close
```

Stop the local tunnel:

```bash
./vmigrate tunnel-stop
```

---

## Resume after interruption

Use `resume` when SSH disconnected, tmux closed, the host rebooted, or you forgot the next step.

Read-only resume analysis:

```bash
./vmigrate resume
```

It checks:

```text
Remote env
Remote export
Tunnel
Target node
Bitmap
FULL state
FINAL state
SOURCE stopped state
VERIFY state
```

Then it prints one recommended next command.

Run the next safe step automatically:

```bash
./vmigrate resume --run
```

`resume --run` can run safe continuation steps such as:

```text
remote-run-check
remote-export
tunnel
attach-target
bitmap
full
wait-full
incremental
verify
```

It refuses high-risk steps such as `final` and `stop-source`. Run those manually after reviewing the status.

---

## Automatic and manual NBD ports

New runs select an automatic per-run NBD port by default.

The default auto formula is based on the destination target ID. For example, `TARGET_ID=2001` normally maps near:

```text
12001
```

If the selected port is busy, vmigrate scans the next available ports.

Disable automatic port selection for a new run:

```bash
VMIGRATE_AUTO_NBD_PORT=0 ./vmigrate create VM_NAME TARGET_ID TARGET_HOST SSH_PORT root
```

Select an automatic port manually for the active run:

```bash
./vmigrate set-nbd-port auto
```

Set a specific port manually:

```bash
./vmigrate set-nbd-port 10809
```

Check local and remote NBD settings after changing the port:

```bash
./vmigrate remote-run-check
```

Production note: parallel migration is still conservative. Use separate ports and test carefully before running multiple heavy migrations to the same destination host.

---

## Batch FULL workflow

Batch mode runs FULL syncs sequentially. It continues after an item failure and writes a batch summary.

Create a batch file:

```bash
cat > batch.txt <<'EOF'
v1001 2001 TARGET_HOST 22 root
v1002 2002 TARGET_HOST 22 root
EOF
```

Each non-comment line has this format:

```text
VM_NAME TARGET_ID TARGET_HOST [SSH_PORT] [SSH_USER]
```

Run batch FULL:

```bash
./vmigrate batch-full batch.txt
```

Batch behavior:

1. Creates one run per VM.
2. Prepares the destination per run.
3. Uses automatic per-run NBD port selection.
4. Starts remote export.
5. Starts tunnel.
6. Creates bitmap.
7. Runs FULL sync.
8. Waits for FULL completion.
9. Closes export/tunnel before the next item.
10. Continues after a failed item.

Show runs after batch:

```bash
./vmigrate list
```

Show latest history:

```bash
./vmigrate history
```

Show all history for one VM:

```bash
./vmigrate history VM_NAME --all
```

Resume or review a specific batch-created run:

```bash
./vmigrate use VM_NAME RUN_ID
```

```bash
./vmigrate resume
```

Batch mode only performs FULL sync. Final cutover should be done manually per VM after review.

---

## Monitoring and reports

Show runtime status:

```bash
./vmigrate status
```

Show a detailed report:

```bash
./vmigrate report
```

Watch active block job progress:

```bash
./vmigrate watch
```

`watch` is read-only. It does not dismiss jobs or change state.

Show block jobs:

```bash
./vmigrate jobs
```

Dismiss concluded jobs:

```bash
./vmigrate jobs-dismiss-all
```

Dismiss one job:

```bash
./vmigrate job-dismiss JOB_ID
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

---

## Tunnel and NBD checks

Check the tunnel and NBD metadata:

```bash
./vmigrate tunnel-check
```

Run an optional NBD read sample:

```bash
VMIGRATE_NBD_READ_SAMPLE=1 ./vmigrate tunnel-check
```

If the tunnel/export is stale, recover in this order:

```bash
./vmigrate tunnel-stop
```

```bash
./vmigrate remote-dst-close
```

```bash
./vmigrate remote-export
```

```bash
./vmigrate tunnel
```

```bash
./vmigrate tunnel-check
```

---

## Verification

Run default sample verification:

```bash
./vmigrate verify
```

Run verification with a specific sample count:

```bash
./vmigrate verify 128
```

Alias:

```bash
./vmigrate verify-sample 128
```

The result is stored in the run summary and shown in `list` and `history`.

---

## Cleanup and lock handling

Normal cleanup for the active run:

```bash
./vmigrate cleanup
```

Stale cleanup without force:

```bash
./vmigrate cleanup-stale
```

Stale cleanup with force:

```bash
./vmigrate cleanup-stale --force
```

Show locks:

```bash
./vmigrate lock-status
```

Remove stale locks:

```bash
./vmigrate unlock-stale
```

Show old remote run directories without deleting them:

```bash
./vmigrate cleanup-remote-runs --dry-run
```

---

## Destination helper commands

Normally you do not run these manually. `remote-prepare` copies and runs the agent in the destination per-run workspace.

Check agent version:

```bash
./vmigrate-agent version
```

Run destination doctor:

```bash
./vmigrate-agent doctor
```

Start destination NBD export:

```bash
./vmigrate-agent export
```

Show destination NBD status:

```bash
./vmigrate-agent status
```

Close destination NBD export:

```bash
./vmigrate-agent close
```

Boot destination VM after final cutover and source stop:

```bash
./vmigrate-agent boot
```

---

## Safety notes

`vmigrate` does not delete disks, remove LVs, wipe filesystems, or undefine VMs.

`stop-source` refuses to stop the source VM unless final cutover completed.

`final` refuses to suspend the source VM unless `cutover-check` passes.

`resume --run` refuses to run high-risk steps such as `final` and `stop-source` automatically.

Do not resume the source VM after final cutover unless you are intentionally rolling back.

Start the destination VM only after:

1. Final completed successfully.
2. Source VM is stopped.
3. Destination NBD export is closed.
4. Local tunnel is stopped.

---

## Files

```text
vmigrate          Source-side helper
vmigrate-agent    Destination-side helper
migrations/       Per-run logs, config, reports, and summaries
locks/            Runtime lock files
.vmigrate-active  Active run pointer
vmigrate.env      Legacy/default fallback config
```

Runtime files are ignored by Git.

---

## Troubleshooting quick reference

Find the next safe step:

```bash
./vmigrate resume
```

Run the next safe step:

```bash
./vmigrate resume --run
```

Remote env mismatch:

```bash
./vmigrate remote-run-check
```

NBD port busy:

```bash
./vmigrate remote-dst-status
```

```bash
./vmigrate remote-dst-close
```

```bash
./vmigrate set-nbd-port auto
```

Tunnel exists but health check fails:

```bash
./vmigrate remote-export
```

```bash
./vmigrate tunnel-check
```

If still failing:

```bash
./vmigrate tunnel-restart
```

```bash
./vmigrate tunnel-check
```

---

