#!/usr/bin/env bash
# kvm2pve source-side helper
set -Eeuo pipefail

VERSION="0.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info(){ echo "${BLUE}>>${NC} $*"; }
ok(){ echo "${GREEN}OK${NC} $*"; }
warn(){ echo "${YELLOW}WARN${NC} $*"; }
die(){ echo "${RED}ERROR${NC} $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage(){ cat <<EOF
kvm2pve-src.sh v${VERSION}

Usage:
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
EOF
}

ask(){ local var="$1" prompt="$2" def="${3:-}" val; read -r -p "$prompt${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
confirm(){ local prompt="$1" ans; read -r -p "$prompt [yes/no]: " ans; [[ "$ans" == "yes" ]]; }

load_config(){
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE. Run: ./kvm2pve-src.sh init"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${VM_NAME:?}"; : "${PVE_HOST:?}"; : "${PVE_SSH_USER:=root}"; : "${PVE_SSH_PORT:=22}"; : "${PVE_VMID:?}"; : "${PVE_DISK:?}"
  SRC_DISK="${SRC_DISK:-}"
  QEMU_DEVICE="${QEMU_DEVICE:-}"
  QEMU_NODE="${QEMU_NODE:-}"
  BITMAP="${BITMAP:-kvm2pve}"
  TARGET_NODE="${TARGET_NODE:-kvm2pve-target}"
  NBD_PORT="${NBD_PORT:-10809}"
  NBD_EXPORT="${NBD_EXPORT:-$VM_NAME}"
  TUNNEL_MODE="${TUNNEL_MODE:-autossh}"
  AUTOSSH_MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20000}"
}

write_key(){
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  [[ -f "$CONFIG_FILE" ]] && grep -v -E "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

init_config(){
  local vm pve_host pve_vmid pve_disk pve_user ssh_port src_disk nbd_port nbd_export
  ask vm "Source VM name" "kvm3023"
  ask pve_host "Proxmox host/IP" "CHANGE_ME"
  ask pve_vmid "Destination Proxmox VMID" "2672"
  ask pve_disk "Destination disk path" "/dev/pve/vm-${pve_vmid}-disk-0"
  ask pve_user "Proxmox SSH user" "root"
  ask ssh_port "Proxmox SSH port" "22"
  ask src_disk "Source disk path, empty=auto-discover" ""
  ask nbd_port "NBD port" "10809"
  ask nbd_export "NBD export name" "$vm"
  cat > "$CONFIG_FILE" <<EOF
VM_NAME=$vm
SRC_DISK=$src_disk
QEMU_DEVICE=
QEMU_NODE=
BITMAP=kvm2pve
TARGET_NODE=kvm2pve-target
PVE_HOST=$pve_host
PVE_SSH_USER=$pve_user
PVE_SSH_PORT=$ssh_port
PVE_VMID=$pve_vmid
PVE_DISK=$pve_disk
NBD_PORT=$nbd_port
NBD_EXPORT=$nbd_export
TUNNEL_MODE=autossh
AUTOSSH_MONITOR_PORT=20000
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config written: $CONFIG_FILE"
}

show_config(){
  load_config
  cat <<EOF
Source VM      : $VM_NAME
Source disk    : ${SRC_DISK:-not set}
QEMU device    : ${QEMU_DEVICE:-not set}
QEMU node      : ${QEMU_NODE:-not set}
Bitmap         : $BITMAP
Target node    : $TARGET_NODE
Proxmox        : ${PVE_SSH_USER}@${PVE_HOST}:${PVE_SSH_PORT}
Proxmox VMID   : $PVE_VMID
Proxmox disk   : $PVE_DISK
NBD            : localhost:${NBD_PORT}, export=${NBD_EXPORT}
Tunnel mode    : $TUNNEL_MODE
EOF
}

qmp(){ local json="$1"; virsh qemu-monitor-command "$VM_NAME" --pretty "$json"; }

parse_info_block(){
  awk '
    /^[^[:space:]:]+[[:space:]]+\(#block[0-9]+\):/ {
      device=$1
      node=$2; gsub(/[()]/,"",node)
      disk=$0; sub(/^[^:]+:[[:space:]]*/,"",disk); sub(/[[:space:]]+\([^)]+\).*$/,"",disk)
      print device "\t" node "\t" disk
    }
  '
}

discover(){
  load_config; need virsh; need awk
  info "Reading QEMU info block for $VM_NAME"
  local out detected count chosen device node disk size
  out="$(virsh qemu-monitor-command "$VM_NAME" --hmp "info block")"
  echo "$out"
  detected="$(printf '%s\n' "$out" | parse_info_block)"
  [[ -n "$detected" ]] || die "Could not parse info block output"
  count="$(printf '%s\n' "$detected" | wc -l | awk '{print $1}')"
  if [[ -n "$SRC_DISK" ]]; then
    chosen="$(printf '%s\n' "$detected" | awk -F '\t' -v d="$SRC_DISK" '$3==d {print; exit}')"
    [[ -n "$chosen" ]] || chosen="$(printf '%s\n' "$detected" | head -n1)"
  else
    chosen="$(printf '%s\n' "$detected" | head -n1)"
  fi
  device="$(printf '%s' "$chosen" | awk -F '\t' '{print $1}')"
  node="$(printf '%s' "$chosen" | awk -F '\t' '{print $2}')"
  disk="$(printf '%s' "$chosen" | awk -F '\t' '{print $3}')"
  size="$(blockdev --getsize64 "$disk" 2>/dev/null || stat -c %s "$disk" 2>/dev/null || echo unknown)"
  cat <<EOF

Detected values
---------------
Block devices found : $count
Selected disk       : $disk
QEMU device         : $device
QEMU node           : $node
Disk size           : $size
EOF
  if confirm "Write these detected values to $CONFIG_FILE?"; then
    write_key SRC_DISK "$disk"
    write_key QEMU_DEVICE "$device"
    write_key QEMU_NODE "$node"
    write_key NBD_EXPORT "${NBD_EXPORT:-$VM_NAME}"
    ok "Config updated"
  else
    warn "Config not changed"
  fi
}

start_tunnel(){
  load_config; need ssh
  [[ "$PVE_HOST" != "CHANGE_ME" ]] || die "Set PVE_HOST in $CONFIG_FILE"
  if [[ "$TUNNEL_MODE" == "direct" ]]; then warn "Direct mode selected; no SSH tunnel started"; return; fi
  if [[ "$TUNNEL_MODE" == "autossh" ]]; then need autossh; fi
  pkill -f "${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  local args=(-f -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" -p "$PVE_SSH_PORT" "${PVE_SSH_USER}@${PVE_HOST}")
  if [[ "$TUNNEL_MODE" == "autossh" ]]; then autossh -M "$AUTOSSH_MONITOR_PORT" "${args[@]}"; else ssh "${args[@]}"; fi
  ok "Tunnel started: localhost:${NBD_PORT} -> ${PVE_HOST}:127.0.0.1:${NBD_PORT}"
  qemu-img info "nbd:localhost:${NBD_PORT}:exportname=${NBD_EXPORT}" || warn "qemu-img info failed; check destination export"
}

attach_target(){
  load_config; need virsh
  qmp '{
  "execute":"blockdev-add",
  "arguments":{
    "node-name":"'"$TARGET_NODE"'",
    "driver":"raw",
    "file":{
      "driver":"nbd",
      "server":{"type":"inet","host":"127.0.0.1","port":"'"$NBD_PORT"'"},
      "export":"'"$NBD_EXPORT"'"
    }
  }
}'
}

create_bitmap(){
  load_config; [[ -n "$QEMU_NODE" ]] || die "QEMU_NODE is empty. Run discover first."
  qmp '{"execute":"block-dirty-bitmap-add","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}'
}

backup_job(){
  local sync="$1" job="$2" extra=""
  load_config; [[ -n "$QEMU_DEVICE" ]] || die "QEMU_DEVICE is empty. Run discover first."
  if [[ "$sync" == "incremental" ]]; then extra=',"bitmap":"'"$BITMAP"'"'; fi
  qmp '{
  "execute":"blockdev-backup",
  "arguments":{
    "device":"'"$QEMU_DEVICE"'",
    "target":"'"$TARGET_NODE"'",
    "sync":"'"$sync"'"'"$extra"',
    "job-id":"'"$job"'",
    "auto-finalize":true,
    "auto-dismiss":true
  }
}'
}

watch_jobs(){
  load_config
  while true; do
    clear || true
    qmp '{"execute":"query-block-jobs"}' | awk '
      /"offset"/ {gsub(/[^0-9]/,"",$2); offset=$2}
      /"len"/ {gsub(/[^0-9]/,"",$2); len=$2}
      /"status"/ {gsub(/[",]/,"",$2); status=$2}
      /"device"/ {gsub(/[",]/,"",$2); device=$2}
      /"error"/ {err=$0}
      END {
        if (len > 0) {
          pct=int((offset*100)/len)
          printf "Job: %s\nProgress: %d%%\nOffset: %s\nTotal: %s\nStatus: %s\n", device, pct, offset, len, status
          if (err != "") print err
        } else {
          print "No active block job. If a job was running, it is probably completed."
        }
      }'
    sleep 2
  done
}

status(){
  load_config
  virsh domstate "$VM_NAME" || true
  qmp '{"execute":"query-block-jobs"}' || true
  qmp '{"execute":"query-block"}' | grep -A20 -B5 "$BITMAP" || true
}

final_cutover(){
  load_config
  warn "Before final cutover, lock customer/Virtualizor panel controls."
  confirm "Suspend source VM and run FINAL incremental now?" || die "Aborted"
  virsh suspend "$VM_NAME"
  virsh domstate "$VM_NAME"
  backup_job incremental final
  ok "Final incremental started. Run: ./kvm2pve-src.sh watch"
}

cleanup(){
  load_config
  pkill -f "${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  qmp '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}' || true
  ok "Source cleanup attempted"
}

stop_source(){
  load_config
  warn "This stops the source VM. Use only after final incremental completed."
  confirm "Destroy/stop source VM $VM_NAME now?" || die "Aborted"
  virsh destroy "$VM_NAME"
}

cmd="${1:-}"
case "$cmd" in
  init) init_config ;;
  discover) discover ;;
  show) show_config ;;
  tunnel) start_tunnel ;;
  attach-target) attach_target ;;
  bitmap) create_bitmap ;;
  full) backup_job full full ;;
  incremental) backup_job incremental inc1 ;;
  final) final_cutover ;;
  watch) watch_jobs ;;
  status) status ;;
  cleanup) cleanup ;;
  stop-source) stop_source ;;
  -h|--help|help|"") usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
