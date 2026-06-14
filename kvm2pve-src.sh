#!/usr/bin/env bash
# kvm2pve source-side helper
set -Eeuo pipefail

VERSION="0.2.4"
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
  ./kvm2pve-src.sh discover [VM_NAME]
  ./kvm2pve-src.sh init
  ./kvm2pve-src.sh show
  ./kvm2pve-src.sh preflight
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

Recommended first run:
  ./kvm2pve-src.sh discover kvm3023
EOF
}

ask(){ local var="$1" prompt="$2" def="${3:-}" val; read -r -p "$prompt${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
confirm(){ local prompt="$1" ans; read -r -p "$prompt [yes/no]: " ans; [[ "$ans" == "yes" ]]; }

sanitize_name(){ printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'; }
default_bitmap(){ printf 'kvm2pve-bitmap-%s' "$(sanitize_name "$1")"; }
default_target_node(){ printf 'kvm2pve-target-%s' "$(sanitize_name "$1")"; }

load_config(){
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE. Run: ./kvm2pve-src.sh discover VM_NAME"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${VM_NAME:?}"; : "${PVE_HOST:?}"; : "${PVE_SSH_USER:=root}"; : "${PVE_SSH_PORT:=22}"; : "${PVE_VMID:?}"; : "${PVE_DISK:?}"
  SRC_DISK="${SRC_DISK:-}"
  QEMU_DEVICE="${QEMU_DEVICE:-}"
  QEMU_NODE="${QEMU_NODE:-}"
  BITMAP="${BITMAP:-$(default_bitmap "$VM_NAME")}"
  TARGET_NODE="${TARGET_NODE:-$(default_target_node "$VM_NAME")}"
  NBD_PORT="${NBD_PORT:-10809}"
  NBD_EXPORT="${NBD_EXPORT:-$VM_NAME}"
  TUNNEL_MODE="${TUNNEL_MODE:-autossh}"
  AUTOSSH_MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20000}"
}

get_conf(){ local key="$1"; [[ -f "$CONFIG_FILE" ]] || return 0; awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE"; }
write_key(){
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  [[ -f "$CONFIG_FILE" ]] && grep -v -E "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

init_config(){
  local vm pve_host pve_vmid pve_disk ssh_port src_disk
  ask vm "Source VM name" "kvm3023"
  ask pve_host "Proxmox host/IP" "CHANGE_ME"
  ask ssh_port "Proxmox SSH port" "22"
  ask pve_vmid "Destination Proxmox VMID" "2672"
  ask pve_disk "Destination disk path" "/dev/pve/vm-${pve_vmid}-disk-0"
  ask src_disk "Source disk path, empty=auto-discover" ""
  cat > "$CONFIG_FILE" <<EOF
VM_NAME=$vm
SRC_DISK=$src_disk
QEMU_DEVICE=
QEMU_NODE=
BITMAP=$(default_bitmap "$vm")
TARGET_NODE=$(default_target_node "$vm")
PVE_HOST=$pve_host
PVE_SSH_USER=root
PVE_SSH_PORT=$ssh_port
PVE_VMID=$pve_vmid
PVE_DISK=$pve_disk
NBD_PORT=10809
NBD_EXPORT=$vm
TUNNEL_MODE=autossh
AUTOSSH_MONITOR_PORT=20000
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config written: $CONFIG_FILE"
}

ensure_base_config(){
  local vm_arg="${1:-}" vm old_vm pve_host pve_vmid pve_disk ssh_port
  if [[ -f "$CONFIG_FILE" ]]; then
    old_vm="$(get_conf VM_NAME)"
    vm="${vm_arg:-$old_vm}"
    [[ -n "$vm" ]] || ask vm "Source VM name" "kvm3023"
    write_key VM_NAME "$vm"

    if [[ -n "$old_vm" && "$vm" != "$old_vm" ]]; then
      warn "VM changed from $old_vm to $vm; regenerating VM-specific values"
      write_key SRC_DISK ""
      write_key QEMU_DEVICE ""
      write_key QEMU_NODE ""
      write_key BITMAP "$(default_bitmap "$vm")"
      write_key TARGET_NODE "$(default_target_node "$vm")"
      write_key NBD_EXPORT "$vm"
    else
      [[ -n "$(get_conf BITMAP)" ]] || write_key BITMAP "$(default_bitmap "$vm")"
      [[ -n "$(get_conf TARGET_NODE)" ]] || write_key TARGET_NODE "$(default_target_node "$vm")"
      [[ -n "$(get_conf NBD_EXPORT)" ]] || write_key NBD_EXPORT "$vm"
    fi

    [[ -n "$(get_conf PVE_SSH_USER)" ]] || write_key PVE_SSH_USER root
    [[ -n "$(get_conf PVE_SSH_PORT)" ]] || write_key PVE_SSH_PORT 22
    [[ -n "$(get_conf NBD_PORT)" ]] || write_key NBD_PORT 10809
    [[ -n "$(get_conf TUNNEL_MODE)" ]] || write_key TUNNEL_MODE autossh
    [[ -n "$(get_conf AUTOSSH_MONITOR_PORT)" ]] || write_key AUTOSSH_MONITOR_PORT 20000
  else
    vm="$vm_arg"
    [[ -n "$vm" ]] || ask vm "Source VM name" "kvm3023"
    ask pve_host "Proxmox host/IP" "CHANGE_ME"
    ask ssh_port "Proxmox SSH port" "22"
    ask pve_vmid "Destination Proxmox VMID" "2672"
    ask pve_disk "Destination disk path" "/dev/pve/vm-${pve_vmid}-disk-0"
    cat > "$CONFIG_FILE" <<EOF
VM_NAME=$vm
SRC_DISK=
QEMU_DEVICE=
QEMU_NODE=
BITMAP=$(default_bitmap "$vm")
TARGET_NODE=$(default_target_node "$vm")
PVE_HOST=$pve_host
PVE_SSH_USER=root
PVE_SSH_PORT=$ssh_port
PVE_VMID=$pve_vmid
PVE_DISK=$pve_disk
NBD_PORT=10809
NBD_EXPORT=$vm
TUNNEL_MODE=autossh
AUTOSSH_MONITOR_PORT=20000
EOF
    chmod 600 "$CONFIG_FILE"
  fi
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

block_jobs_json(){ load_config; qmp '{"execute":"query-block-jobs"}'; }
block_jobs_empty(){ ! block_jobs_json | grep -q '"type"'; }
wait_jobs_empty(){
  load_config
  local out
  while true; do
    out="$(block_jobs_json)"
    if ! printf '%s\n' "$out" | grep -q '"type"'; then
      ok "No active block job"
      return 0
    fi
    if printf '%s\n' "$out" | grep -q '"error"'; then
      printf '%s\n' "$out"
      die "Block job ended with an error"
    fi
    printf '%s\n' "$out" | awk '
      /"offset"/ {gsub(/[^0-9]/,"",$2); offset=$2}
      /"len"/ {gsub(/[^0-9]/,"",$2); len=$2}
      /"status"/ {gsub(/[",]/,"",$2); status=$2}
      END { if (len > 0) printf "Progress: %d%% | %s / %s | Status: %s\n", int((offset*100)/len), offset, len, status; else print "Block job running" }'
    sleep 2
  done
}

bitmap_exists(){ load_config; qmp '{"execute":"query-block"}' | grep -q "\"name\": \"$BITMAP\""; }
target_node_exists(){ load_config; qmp '{"execute":"query-named-block-nodes"}' 2>/dev/null | grep -q "\"node-name\": \"$TARGET_NODE\""; }

discover(){
  local vm_arg="${1:-}" existing_disk out detected count chosen device node disk size
  need virsh; need awk
  ensure_base_config "$vm_arg"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  existing_disk="${SRC_DISK:-}"
  info "Reading QEMU info block for $VM_NAME"
  out="$(virsh qemu-monitor-command "$VM_NAME" --hmp "info block")"
  echo "$out"
  detected="$(printf '%s\n' "$out" | parse_info_block)"
  [[ -n "$detected" ]] || die "Could not parse info block output"
  count="$(printf '%s\n' "$detected" | wc -l | awk '{print $1}')"
  if [[ -n "$existing_disk" ]]; then
    chosen="$(printf '%s\n' "$detected" | awk -F '\t' -v d="$existing_disk" '$3==d {print; exit}')"
    [[ -n "$chosen" ]] || chosen="$(printf '%s\n' "$detected" | head -n1)"
  else
    chosen="$(printf '%s\n' "$detected" | head -n1)"
  fi
  device="$(printf '%s' "$chosen" | awk -F '\t' '{print $1}')"
  node="$(printf '%s' "$chosen" | awk -F '\t' '{print $2}')"
  disk="$(printf '%s' "$chosen" | awk -F '\t' '{print $3}')"
  size="$(blockdev --getsize64 "$disk" 2>/dev/null || stat -c %s "$disk" 2>/dev/null || echo unknown)"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  BITMAP="${BITMAP:-$(default_bitmap "$VM_NAME")}"; TARGET_NODE="${TARGET_NODE:-$(default_target_node "$VM_NAME")}"; NBD_EXPORT="${NBD_EXPORT:-$VM_NAME}"
  cat <<EOF

Detected values
---------------
Config file         : $CONFIG_FILE
VM name             : $VM_NAME
Block devices found : $count
Selected disk       : $disk
QEMU device         : $device
QEMU node           : $node
Disk size           : $size
Bitmap              : $BITMAP
Target node         : $TARGET_NODE
Proxmox             : ${PVE_SSH_USER}@${PVE_HOST}:${PVE_SSH_PORT}
Proxmox VMID        : $PVE_VMID
Proxmox disk        : $PVE_DISK
NBD port/export     : ${NBD_PORT}/${NBD_EXPORT}
EOF
  if confirm "Write these detected values to config and continue with this VM?"; then
    write_key SRC_DISK "$disk"
    write_key QEMU_DEVICE "$device"
    write_key QEMU_NODE "$node"
    write_key BITMAP "$BITMAP"
    write_key TARGET_NODE "$TARGET_NODE"
    write_key NBD_EXPORT "$NBD_EXPORT"
    ok "Config updated: $CONFIG_FILE"
  else
    warn "Config not changed"
  fi
}

preflight(){
  load_config; need virsh; need ssh
  [[ "$TUNNEL_MODE" != "autossh" ]] || need autossh
  virsh list --all | awk '{print $2}' | grep -qx "$VM_NAME" || die "VM not found in virsh: $VM_NAME"
  virsh domstate "$VM_NAME" | grep -qE 'running|paused' || die "VM is not running/paused"
  [[ -n "$SRC_DISK" && ( -b "$SRC_DISK" || -f "$SRC_DISK" ) ]] || die "SRC_DISK missing or invalid. Run discover."
  [[ -n "$QEMU_DEVICE" && -n "$QEMU_NODE" ]] || die "QEMU_DEVICE/QEMU_NODE missing. Run discover."
  [[ "$PVE_HOST" != "CHANGE_ME" ]] || die "Set PVE_HOST in $CONFIG_FILE"
  ssh -p "$PVE_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "${PVE_SSH_USER}@${PVE_HOST}" "test -e '$PVE_DISK' && echo connected" >/dev/null || die "Cannot verify destination disk over SSH"
  ok "Preflight checks passed"
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
  if target_node_exists; then
    ok "Target node already exists: $TARGET_NODE"
    return 0
  fi
  local out
  out="$(qmp '{
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
}')"
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q '"error"'; then die "blockdev-add failed"; fi
}

create_bitmap(){
  load_config; [[ -n "$QEMU_NODE" ]] || die "QEMU_NODE is empty. Run discover first."
  if bitmap_exists; then
    ok "Bitmap already exists: $BITMAP"
    return 0
  fi
  local out
  out="$(qmp '{"execute":"block-dirty-bitmap-add","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}')"
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q '"error"'; then die "block-dirty-bitmap-add failed"; fi
}

backup_job(){
  local sync="$1" job="$2" extra=""
  load_config; [[ -n "$QEMU_DEVICE" ]] || die "QEMU_DEVICE is empty. Run discover first."
  if ! block_jobs_empty; then die "A block job is already present. Run watch/status first."; fi
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
  wait_jobs_empty
  ok "Final incremental completed"
}

cleanup(){
  load_config
  pkill -f "${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  if bitmap_exists; then
    qmp '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}' || true
  fi
  ok "Source cleanup attempted"
}

stop_source(){
  load_config
  warn "This stops the source VM. Use only after final incremental completed."
  if ! block_jobs_empty; then
    block_jobs_json
    die "Refusing to stop source VM while a block job is still present"
  fi
  confirm "Destroy/stop source VM $VM_NAME now?" || die "Aborted"
  virsh destroy "$VM_NAME"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init) init_config ;;
  discover) discover "${1:-}" ;;
  show) show_config ;;
  preflight) preflight ;;
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
