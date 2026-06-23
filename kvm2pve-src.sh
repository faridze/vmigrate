#!/usr/bin/env bash
# kvm2pve source-side helper
set -Eeuo pipefail

VERSION="0.4.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
if [[ -n "${NO_COLOR:-}" ]]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi
info(){ echo "${BLUE}>>${NC} $*"; }
ok(){ echo "${GREEN}OK${NC} $*"; }
warn(){ echo "${YELLOW}WARN${NC} $*"; }
die(){ echo "${RED}ERROR${NC} $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage(){ cat <<EOF
kvm2pve-src.sh v${VERSION}

Usage:
  ./kvm2pve-src.sh discover [VM_NAME] [--yes]
  ./kvm2pve-src.sh init
  ./kvm2pve-src.sh show
  ./kvm2pve-src.sh apply-handoff HANDOFF_TOKEN
  ./kvm2pve-src.sh remote-prepare VM_NAME PVE_VMID PVE_HOST [SSH_PORT] [SSH_USER]
  ./kvm2pve-src.sh migrate VM_NAME PVE_VMID PVE_HOST [SSH_PORT] [SSH_USER]
  ./kvm2pve-src.sh remote-export
  ./kvm2pve-src.sh remote-dst-status
  ./kvm2pve-src.sh remote-dst-close
  ./kvm2pve-src.sh quick [HANDOFF_TOKEN]
  ./kvm2pve-src.sh quick [VM_NAME] [HANDOFF_TOKEN]
  ./kvm2pve-src.sh next
  ./kvm2pve-src.sh preflight
  ./kvm2pve-src.sh tunnel
  ./kvm2pve-src.sh tunnel-stop
  ./kvm2pve-src.sh tunnel-restart
  ./kvm2pve-src.sh tunnel-status
  ./kvm2pve-src.sh tunnel-check
  ./kvm2pve-src.sh attach-target
  ./kvm2pve-src.sh check-target
  ./kvm2pve-src.sh bitmap
  ./kvm2pve-src.sh check-bitmap
  ./kvm2pve-src.sh full
  ./kvm2pve-src.sh wait-full
  ./kvm2pve-src.sh mark-full
  ./kvm2pve-src.sh set-backup-method
  ./kvm2pve-src.sh incremental
  ./kvm2pve-src.sh wait-inc
  ./kvm2pve-src.sh jobs
  ./kvm2pve-src.sh job-dismiss JOB_ID
  ./kvm2pve-src.sh jobs-dismiss-all
  ./kvm2pve-src.sh cutover-check
  ./kvm2pve-src.sh check-paused
  ./kvm2pve-src.sh final
  ./kvm2pve-src.sh watch
  ./kvm2pve-src.sh status
  ./kvm2pve-src.sh report
  ./kvm2pve-src.sh verify-sample
  ./kvm2pve-src.sh cleanup
  ./kvm2pve-src.sh stop-source

Recommended first run:
  ./kvm2pve-src.sh quick HANDOFF_TOKEN
EOF
}

ask(){ local var="$1" prompt="$2" def="${3:-}" val; read -r -p "$prompt${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
confirm(){ local prompt="$1" ans; read -r -p "$prompt [yes/no]: " ans; [[ "$ans" == "yes" ]]; }
ask_exact(){
  local prompt="$1" expected="$2" ans
  read -r -p "$prompt " ans
  [[ "$ans" == "$expected" ]]
}
ask_yes_default(){
  local prompt="$1" ans
  while true; do
    read -r -p "$prompt [Y/n]: " ans
    case "$ans" in
      ""|Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Please answer Y or N." ;;
    esac
  done
}

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
  NBD_EXPORT="${NBD_EXPORT:-vm-${PVE_VMID}}"
  TUNNEL_MODE="${TUNNEL_MODE:-autossh}"
  AUTOSSH_MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20000}"
  BACKUP_METHOD="${BACKUP_METHOD:-drive-backup}"
  QMP_TIMEOUT="${QMP_TIMEOUT:-20}"
  CHECK_TIMEOUT="${CHECK_TIMEOUT:-8}"
  NBD_IO_TIMEOUT="${NBD_IO_TIMEOUT:-20}"
}

get_conf(){ local key="$1"; [[ -f "$CONFIG_FILE" ]] || return 0; awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE"; }
write_key(){
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  [[ -f "$CONFIG_FILE" ]] && grep -v -E "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

now_ts(){ date '+%Y-%m-%d %H:%M:%S %z'; }
config_dir(){ case "$CONFIG_FILE" in */*) printf '%s' "${CONFIG_FILE%/*}" ;; *) printf '.' ;; esac; }
state_file(){
  local vm
  vm="${VM_NAME:-$(get_conf VM_NAME)}"
  [[ -n "$vm" ]] || vm="unknown"
  printf '%s/.kvm2pve-state-%s' "$(config_dir)" "$(sanitize_name "$vm")"
}
state_get(){ local key="$1" file; file="$(state_file)"; [[ -f "$file" ]] || return 0; awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$file"; }
state_write(){
  local key="$1" val="$2" file tmp
  file="$(state_file)"
  tmp="$(mktemp)"
  [[ -f "$file" ]] && grep -v -E "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}
state_sync_identity(){
  state_write VM_NAME "${VM_NAME:-}"
  state_write SRC_DISK "${SRC_DISK:-}"
  state_write PVE_DISK "${PVE_DISK:-}"
  [[ -n "$(state_get FULL_STARTED)" ]] || state_write FULL_STARTED 0
  [[ -n "$(state_get FULL_STARTED_AT)" ]] || state_write FULL_STARTED_AT ""
  [[ -n "$(state_get FULL_JOB_ID)" ]] || state_write FULL_JOB_ID ""
  [[ -n "$(state_get FULL_COMPLETED)" ]] || state_write FULL_COMPLETED 0
  [[ -n "$(state_get FULL_COMPLETED_AT)" ]] || state_write FULL_COMPLETED_AT ""
  [[ -n "$(state_get FINAL_COMPLETED)" ]] || state_write FINAL_COMPLETED 0
  [[ -n "$(state_get FINAL_COMPLETED_AT)" ]] || state_write FINAL_COMPLETED_AT ""
  [[ -n "$(state_get SOURCE_STOPPED)" ]] || state_write SOURCE_STOPPED 0
  [[ -n "$(state_get SOURCE_STOPPED_AT)" ]] || state_write SOURCE_STOPPED_AT ""
}
state_is_full_completed(){ [[ "$(state_get FULL_COMPLETED)" == "1" ]]; }
require_full_completed(){
  state_is_full_completed && return 0
  die "Full sync is not marked as completed. Refusing incremental/final. Run wait-full or mark-full only after confirming full completed successfully."
}
mark_full_completed(){
  load_config
  state_sync_identity
  state_write FULL_COMPLETED 1
  state_write FULL_COMPLETED_AT "$(now_ts)"
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
NBD_EXPORT=vm-${pve_vmid}
TUNNEL_MODE=autossh
AUTOSSH_MONITOR_PORT=20000
BACKUP_METHOD=drive-backup
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
    else
      [[ -n "$(get_conf BITMAP)" ]] || write_key BITMAP "$(default_bitmap "$vm")"
      [[ -n "$(get_conf TARGET_NODE)" ]] || write_key TARGET_NODE "$(default_target_node "$vm")"
      [[ -n "$(get_conf NBD_EXPORT)" ]] || write_key NBD_EXPORT "vm-$(get_conf PVE_VMID)"
    fi

    [[ -n "$(get_conf PVE_SSH_USER)" ]] || write_key PVE_SSH_USER root
    [[ -n "$(get_conf PVE_SSH_PORT)" ]] || write_key PVE_SSH_PORT 22
    [[ -n "$(get_conf NBD_PORT)" ]] || write_key NBD_PORT 10809
    [[ -n "$(get_conf TUNNEL_MODE)" ]] || write_key TUNNEL_MODE autossh
    [[ -n "$(get_conf AUTOSSH_MONITOR_PORT)" ]] || write_key AUTOSSH_MONITOR_PORT 20000
    [[ -n "$(get_conf BACKUP_METHOD)" ]] || write_key BACKUP_METHOD drive-backup
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
NBD_EXPORT=vm-${pve_vmid}
TUNNEL_MODE=autossh
AUTOSSH_MONITOR_PORT=20000
BACKUP_METHOD=drive-backup
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
NBD            : 127.0.0.1:${NBD_PORT}, export=${NBD_EXPORT}
Tunnel mode    : $TUNNEL_MODE
Backup method  : ${BACKUP_METHOD:-drive-backup}
QMP timeout    : ${QMP_TIMEOUT:-20}s
Check timeout  : ${CHECK_TIMEOUT:-8}s
NBD I/O timeout: ${NBD_IO_TIMEOUT:-20}s
EOF
}

apply_handoff(){
  local token="${1:-}" prefix="KVM2PVE_HANDOFF_V1:" payload decoded line key val
  local handoff_pve_vmid="" handoff_pve_disk="" handoff_nbd_port="" handoff_nbd_export=""

  [[ -n "$token" ]] || die "Missing handoff token"
  [[ "$token" == "$prefix"* ]] || die "Invalid handoff token prefix"
  need base64

  payload="${token#"$prefix"}"
  [[ -n "$payload" ]] || die "Missing handoff payload"
  decoded="$(printf '%s' "$payload" | base64 -d 2>/dev/null)" || die "Failed to decode handoff payload"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      PVE_VMID) handoff_pve_vmid="$val" ;;
      PVE_DISK) handoff_pve_disk="$val" ;;
      NBD_PORT) handoff_nbd_port="$val" ;;
      NBD_EXPORT) handoff_nbd_export="$val" ;;
      *) ;;
    esac
  done <<EOF
$decoded
EOF

  [[ -n "$handoff_pve_vmid" ]] || die "Handoff payload missing PVE_VMID"
  [[ -n "$handoff_pve_disk" ]] || die "Handoff payload missing PVE_DISK"
  [[ -n "$handoff_nbd_port" ]] || handoff_nbd_port="10809"
  [[ -n "$handoff_nbd_export" ]] || handoff_nbd_export="vm-${handoff_pve_vmid}"

  write_key PVE_VMID "$handoff_pve_vmid"
  write_key PVE_DISK "$handoff_pve_disk"
  write_key NBD_PORT "$handoff_nbd_port"
  write_key NBD_EXPORT "$handoff_nbd_export"

  cat <<EOF
Applied handoff
---------------
PVE_VMID=$handoff_pve_vmid
PVE_DISK=$handoff_pve_disk
NBD_PORT=$handoff_nbd_port
NBD_EXPORT=$handoff_nbd_export
EOF
}

conf_present(){ [[ -n "$(get_conf "$1")" ]]; }
conf_value(){ local val; val="$(get_conf "$1")"; printf '%s' "${val:-$2}"; }
status_word(){ if "$@"; then printf 'yes'; else printf 'no'; fi; }

prompt_source_vm(){
  local current_vm vm
  current_vm="$(conf_value VM_NAME kvm3023)"
  ask vm "Source VM name" "$current_vm"
  printf '%s' "$vm"
}

prompt_pve_connection(){
  local pve_host ssh_port

  pve_host="$(conf_value PVE_HOST CHANGE_ME)"
  ask pve_host "Proxmox host/IP" "$pve_host"
  write_key PVE_HOST "$pve_host"

  ssh_port="$(conf_value PVE_SSH_PORT 22)"
  ask ssh_port "Proxmox SSH port" "$ssh_port"
  write_key PVE_SSH_PORT "$ssh_port"

  [[ -n "$(get_conf PVE_SSH_USER)" ]] || write_key PVE_SSH_USER root
}

source_discovered(){ conf_present SRC_DISK && conf_present QEMU_DEVICE && conf_present QEMU_NODE; }
handoff_applied(){ conf_present PVE_VMID && conf_present PVE_DISK && conf_present NBD_PORT && conf_present NBD_EXPORT; }
pve_host_set(){ local host; host="$(get_conf PVE_HOST)"; [[ -n "$host" && "$host" != "CHANGE_ME" ]]; }

next_steps(){
  local vm pve_host method effective full_started full_completed final_completed source_stopped bitmap_ok tunnel_ok

  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat <<EOF
Current state
-------------
Config file : missing

Next (recommended):
./kvm2pve-src.sh quick HANDOFF_TOKEN
EOF
    return 0
  fi

  vm="$(conf_value VM_NAME VM_NAME)"
  pve_host="$(conf_value PVE_HOST CHANGE_ME)"
  method="$(conf_value BACKUP_METHOD drive-backup)"
  full_started="$(state_get FULL_STARTED)"; full_started="${full_started:-0}"
  full_completed="$(state_get FULL_COMPLETED)"; full_completed="${full_completed:-0}"
  final_completed="$(state_get FINAL_COMPLETED)"; final_completed="${final_completed:-0}"
  source_stopped="$(state_get SOURCE_STOPPED)"; source_stopped="${source_stopped:-0}"

  if source_discovered && handoff_applied && pve_host_set; then
    load_config
    effective="$(effective_backup_method)"
    if tunnel_health_ok >/dev/null 2>&1; then tunnel_ok="yes"; else tunnel_ok="no"; fi
    if bitmap_exists >/dev/null 2>&1; then bitmap_ok="yes"; else bitmap_ok="no"; fi
  else
    effective="$method"
    tunnel_ok="unknown"
    bitmap_ok="unknown"
  fi

  cat <<EOF
Current state
-------------
Config file       : $CONFIG_FILE
VM name           : $vm
Backup method     : $method
Effective method  : $effective
Source discovered : $(status_word source_discovered)
Handoff applied   : $(status_word handoff_applied)
Proxmox host set  : $(status_word pve_host_set) ($pve_host)
Tunnel healthy    : $tunnel_ok
Bitmap present    : $bitmap_ok
FULL_STARTED      : $full_started
FULL_COMPLETED    : $full_completed
FINAL_COMPLETED   : $final_completed
SOURCE_STOPPED    : $source_stopped

Suggested next
--------------
EOF

  if ! conf_present VM_NAME; then
    echo "./kvm2pve-src.sh discover VM_NAME"
  elif ! source_discovered; then
    echo "./kvm2pve-src.sh discover $vm"
  elif ! handoff_applied; then
    echo "./kvm2pve-src.sh apply-handoff HANDOFF_TOKEN"
  elif ! pve_host_set; then
    echo "Set PVE_HOST in $CONFIG_FILE, then run: ./kvm2pve-src.sh remote-prepare or ./kvm2pve-src.sh preflight"
  elif [[ "$tunnel_ok" != "yes" ]]; then
    echo "./kvm2pve-src.sh remote-export"
    echo "./kvm2pve-src.sh tunnel"
    echo "./kvm2pve-src.sh tunnel-check"
  elif [[ "$bitmap_ok" != "yes" ]]; then
    if [[ "$effective" == "blockdev-backup" ]]; then
      echo "./kvm2pve-src.sh attach-target"
      echo "./kvm2pve-src.sh check-target"
    fi
    echo "./kvm2pve-src.sh bitmap"
    echo "./kvm2pve-src.sh check-bitmap"
  elif [[ "$full_started" != "1" ]]; then
    echo "./kvm2pve-src.sh full"
  elif [[ "$full_completed" != "1" ]]; then
    echo "./kvm2pve-src.sh wait-full"
  elif [[ "$final_completed" != "1" ]]; then
    echo "./kvm2pve-src.sh cutover-check"
    echo "./kvm2pve-src.sh final"
  elif [[ "$source_stopped" != "1" ]]; then
    echo "./kvm2pve-src.sh stop-source"
  else
    echo "./kvm2pve-src.sh remote-dst-close"
  fi
}

quick_start(){
  local vm_arg="${1:-}" token="${2:-}"

  if [[ "$vm_arg" == KVM2PVE_HANDOFF_V1:* && -z "$token" ]]; then
    token="$vm_arg"
    vm_arg=""
  fi

  if [[ -n "$token" ]]; then
    apply_handoff "$token"
    [[ -n "$vm_arg" ]] || vm_arg="$(prompt_source_vm)"
    prompt_pve_connection
    discover "$vm_arg"
  else
    warn "No handoff token supplied; run apply-handoff before preflight if destination values changed"
    discover "$vm_arg"
  fi

  show_config

  if confirm "Run source preflight now?"; then
    preflight
  else
    warn "Preflight skipped"
  fi

  echo
  next_steps
}

remote_dir(){ printf '/root/kvm2pve'; }
remote_ssh(){
  ssh -p "$PVE_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$PVE_SSH_USER@$PVE_HOST" "$@"
}
remote_ssh_batch(){
  remote_ssh "$@"
}

remote_prepare_next_steps(){
  load_config
  local effective
  effective="$(effective_backup_method)"
  cat <<EOF

Destination is prepared remotely.
Now run:

./kvm2pve-src.sh set-backup-method
./kvm2pve-src.sh preflight
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
EOF
  if [[ "$effective" == "blockdev-backup" ]]; then
    cat <<EOF
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
EOF
  fi
  cat <<EOF
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report

Optional monitor in another terminal:
./kvm2pve-src.sh watch
EOF
}

remote_prepare(){
  local vm="${1:-}" pve_host="${2:-}" pve_vmid="${3:-}" ssh_port="${4:-22}" ssh_user="${5:-root}"
  local dst_script rdir token prefix="KVM2PVE_HANDOFF_V1:"

  [[ -n "$vm" && -n "$pve_host" && -n "$pve_vmid" ]] || die "Usage: ./kvm2pve-src.sh remote-prepare VM_NAME PVE_VMID PVE_HOST [SSH_PORT] [SSH_USER]"
  case "$pve_vmid" in *[!0-9]*|'') die "Destination Proxmox VMID must be numeric" ;; esac
  case "$ssh_port" in *[!0-9]*|'') die "SSH port must be numeric" ;; esac
  [[ -f "$SCRIPT_DIR/kvm2pve-src.sh" ]] || die "Source helper missing: $SCRIPT_DIR/kvm2pve-src.sh"
  dst_script="$SCRIPT_DIR/kvm2pve-dst.sh"
  [[ -f "$dst_script" ]] || die "Destination helper missing: $dst_script"

  write_key VM_NAME "$vm"
  write_key PVE_HOST "$pve_host"
  write_key PVE_SSH_USER "$ssh_user"
  write_key PVE_SSH_PORT "$ssh_port"
  write_key PVE_VMID "$pve_vmid"
  [[ -n "$(get_conf BITMAP)" ]] || write_key BITMAP "$(default_bitmap "$vm")"
  [[ -n "$(get_conf TARGET_NODE)" ]] || write_key TARGET_NODE "$(default_target_node "$vm")"
  [[ -n "$(get_conf NBD_PORT)" ]] || write_key NBD_PORT 10809
  write_key NBD_EXPORT "vm-${pve_vmid}"
  [[ -n "$(get_conf TUNNEL_MODE)" ]] || write_key TUNNEL_MODE autossh
  [[ -n "$(get_conf AUTOSSH_MONITOR_PORT)" ]] || write_key AUTOSSH_MONITOR_PORT 20000
  [[ -n "$(get_conf BACKUP_METHOD)" ]] || write_key BACKUP_METHOD drive-backup

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  rdir="$(remote_dir)"

  need ssh
  need scp
  info "Testing SSH connectivity to ${PVE_SSH_USER}@${PVE_HOST}:${PVE_SSH_PORT}"
  remote_ssh_batch true >/dev/null || die "Cannot connect to destination over SSH: ${PVE_SSH_USER}@${PVE_HOST}:${PVE_SSH_PORT}"

  info "Creating remote workspace: $rdir"
  remote_ssh "mkdir -p '$rdir'" || die "Could not create remote workspace: $rdir"

  info "Copying destination helper"
  scp -P "$PVE_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$dst_script" "${PVE_SSH_USER}@${PVE_HOST}:${rdir}/kvm2pve-dst.sh" || die "Could not copy destination helper"
  remote_ssh "chmod +x '$rdir/kvm2pve-dst.sh'" || die "Could not make destination helper executable"

  info "Discovering destination VMID $PVE_VMID"
  remote_ssh "cd '$rdir' && ./kvm2pve-dst.sh discover '$PVE_VMID' --yes" || die "Remote destination discover failed"

  info "Reading destination handoff token"
  token="$(remote_ssh "cd '$rdir' && ./kvm2pve-dst.sh handoff")" || die "Remote destination handoff failed"
  [[ "$token" == "$prefix"* ]] || die "Remote handoff token is invalid"

  apply_handoff "$token"
  info "Running source discovery and writing SRC_DISK/QEMU_DEVICE/QEMU_NODE when unambiguous"
  discover "$VM_NAME" --yes
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  [[ -n "${SRC_DISK:-}" && ( -b "$SRC_DISK" || -f "$SRC_DISK" ) && -n "${QEMU_DEVICE:-}" && -n "${QEMU_NODE:-}" ]] || die "Source discovery did not write valid SRC_DISK/QEMU_DEVICE/QEMU_NODE. Run: ./kvm2pve-src.sh discover $VM_NAME"
  show_config
  remote_prepare_next_steps
}

remote_export(){
  load_config
  need ssh
  remote_ssh "cd '$(remote_dir)' && ./kvm2pve-dst.sh preflight && ./kvm2pve-dst.sh export && ./kvm2pve-dst.sh status"
}

remote_dst_status(){
  load_config
  need ssh
  remote_ssh "cd '$(remote_dir)' && ./kvm2pve-dst.sh status"
}

remote_dst_close(){
  load_config
  need ssh
  remote_ssh "cd '$(remote_dir)' && ./kvm2pve-dst.sh close"
}

qmp(){ local json="$1"; timeout "${QMP_TIMEOUT:-20}" virsh qemu-monitor-command "$VM_NAME" --pretty "$json"; }

parse_info_block(){
  awk '
    /^[^[:space:]:]+[[:space:]]+\(#block[0-9]+\):/ {
      device=$1
      node=$2; gsub(/[():]/,"",node)
      disk=$0; sub(/^[^:]+:[[:space:]]*/,"",disk); sub(/[[:space:]]+\([^)]+\).*$/,"",disk)
      print device "\t" node "\t" disk
    }
  '
}

block_jobs_json(){ load_config; qmp '{"execute":"query-block-jobs"}'; }
block_jobs_empty(){
  local out
  out="$(block_jobs_json 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -q '"error"'; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  ! printf '%s\n' "$out" | grep -q '"type"'
}
block_jobs_query_ok_empty(){
  local out
  out="$(block_jobs_json 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -q '"error"'; then
    printf '%s\n' "$out"
    return 1
  fi
  ! printf '%s\n' "$out" | grep -q '"type"'
}
block_job_ids_from_json(){ awk -F'"' '/"device"/ {print $4}'; }
block_jobs_summary(){
  awk -F'[:,]' '
    /"device"/ {gsub(/[ "]/,"",$2); device=$2}
    /"status"/ {gsub(/[ "]/,"",$2); status=$2}
    /"offset"/ {gsub(/[^0-9]/,"",$2); offset=$2}
    /"len"/ {gsub(/[^0-9]/,"",$2); len=$2}
    /}/ {
      if (device != "") {
        pct="n/a"; if (len > 0) pct=int((offset*100)/len) "%"
        printf "Job %s: status=%s progress=%s offset=%s len=%s\n", device, status, pct, offset, len
      }
      device=""; status=""; offset=""; len=""
    }'
}

progress_line(){
  local offset="${1:-0}" len="${2:-0}" status="${3:-running}" width=30 pct filled empty bar
  if [[ "$len" =~ ^[0-9]+$ && "$offset" =~ ^[0-9]+$ && "$len" -gt 0 ]]; then
    pct=$(( offset * 100 / len ))
    (( pct > 100 )) && pct=100
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
  else
    pct=0
    filled=0
    empty=$width
  fi
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  printf '[%s] %d%% | %s | %s / %s' "$bar" "$pct" "$status" "${offset:-0}" "${len:-0}"
}

progress_from_jobs_json(){
  awk '
    /"offset"/ {gsub(/[^0-9]/,"",$2); offset=$2}
    /"len"/ {gsub(/[^0-9]/,"",$2); len=$2}
    /"status"/ {gsub(/[",]/,"",$2); status=$2}
    END {printf "%s\t%s\t%s\n", offset, len, status}'
}
wait_jobs_empty(){
  load_config
  local out job status parsed_status progress offset len compact=0 compact_printed=0
  if [[ -t 1 && "${DEBUG:-0}" != "1" ]]; then
    compact=1
  fi
  while true; do
    out="$(block_jobs_json)" || {
      (( compact_printed )) && printf '\n'
      die "QMP query timed out or failed while waiting for block jobs"
    }
    if printf '%s\n' "$out" | grep -q '"error"'; then
      (( compact_printed )) && printf '\n'
      printf '%s\n' "$out"
      die "Block job ended with an error"
    fi
    if ! printf '%s\n' "$out" | grep -q '"type"'; then
      (( compact_printed )) && printf '\n'
      ok "No active block job"
      return 0
    fi
    status="$(printf '%s\n' "$out" | awk -F'"' '/"status"/ {print $4; exit}')"
    job="$(printf '%s\n' "$out" | awk -F'"' '/"device"/ {print $4; exit}')"
    IFS=$'\t' read -r offset len parsed_status <<< "$(printf '%s\n' "$out" | progress_from_jobs_json)"
    [[ -n "$parsed_status" ]] && status="$parsed_status"
    progress="$(progress_line "$offset" "$len" "${status:-running}")"
    if (( compact )); then
      printf '\r%s' "$progress"
      compact_printed=1
    else
      printf '%s\n' "$progress"
    fi
    if [[ "$status" == "concluded" ]]; then
      (( compact_printed )) && printf '\n'
      if [[ -n "$job" ]]; then
        job_dismiss "$job" || warn "Could not dismiss concluded job: $job"
      fi
      ok "Block job concluded"
      return 0
    fi
    sleep 2
  done
}

bitmap_exists(){ load_config; qmp '{"execute":"query-block"}' 2>/dev/null | grep -q "\"name\": \"$BITMAP\""; }
target_node_exists(){ load_config; qmp '{"execute":"query-named-block-nodes"}' 2>/dev/null | grep -q "\"node-name\": \"$TARGET_NODE\""; }

verify_target_node(){
  load_config

  if ! target_node_exists; then
    die "Target node verification failed: $TARGET_NODE not found"
  fi

  ok "Target node verified: $TARGET_NODE"
}

verify_bitmap(){
  load_config

  if ! bitmap_exists; then
    die "Bitmap verification failed: $BITMAP not found on $QEMU_NODE"
  fi

  ok "Bitmap verified: $BITMAP"
}

check_target(){
  load_config
  verify_target_node
}

check_bitmap(){
  load_config
  verify_bitmap
}

vm_state(){
  virsh domstate "$VM_NAME" | tr '[:upper:]' '[:lower:]' | awk '{print $1}'
}

wait_vm_paused(){
  load_config

  local state i

  for i in 1 2 3 4 5 6 7 8 9 10; do
    state="$(vm_state || true)"

    case "$state" in
      paused|pmsuspended)
        ok "VM paused successfully: $state"
        return 0
        ;;
    esac

    sleep 1
  done

  state="$(vm_state || true)"
  die "VM is not paused. Refusing final cutover. Current state: ${state:-unknown}"
}

check_paused(){
  load_config
  wait_vm_paused
}

discover(){
  local vm_arg="" assume_yes=0 existing_disk out detected count chosen device node disk size arg

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --yes|-y)
        assume_yes=1
        ;;
      "")
        ;;
      *)
        [[ -z "$vm_arg" ]] || die "Usage: ./kvm2pve-src.sh discover [VM_NAME] [--yes]"
        vm_arg="$arg"
        ;;
    esac
    shift
  done

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
  [[ -n "$disk" && ( -b "$disk" || -f "$disk" ) ]] || die "Detected SRC_DISK is missing or invalid: ${disk:-empty}"
  if (( assume_yes )) && [[ "$count" != "1" && -z "$existing_disk" ]]; then
    die "Multiple source block devices found. Refusing --yes without an existing SRC_DISK. Run: ./kvm2pve-src.sh discover $VM_NAME"
  fi
  size="$(blockdev --getsize64 "$disk" 2>/dev/null || stat -c %s "$disk" 2>/dev/null || echo unknown)"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  BITMAP="${BITMAP:-$(default_bitmap "$VM_NAME")}"; TARGET_NODE="${TARGET_NODE:-$(default_target_node "$VM_NAME")}"; NBD_EXPORT="${NBD_EXPORT:-vm-${PVE_VMID}}"
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
  if (( assume_yes )) || confirm "Write these detected values to config and continue with this VM?"; then
    write_key SRC_DISK "$disk"
    write_key QEMU_DEVICE "$device"
    write_key QEMU_NODE "$node"
    write_key BITMAP "$BITMAP"
    write_key TARGET_NODE "$TARGET_NODE"
    write_key NBD_EXPORT "$NBD_EXPORT"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    state_sync_identity
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

tunnel_listener_exists(){ ss -lntp | grep "127.0.0.1:${NBD_PORT}" >/dev/null; }

tunnel_pids_for_forward(){
  pgrep -af '(^|/)(autossh|ssh)( |$)' 2>/dev/null | awk -v fwd="${NBD_PORT}:127.0.0.1:${NBD_PORT}" '
    index($0, fwd) {print $1}
  '
}

tunnel_pids(){
  pgrep -af '(^|/)(autossh|ssh)( |$)' 2>/dev/null | awk -v fwd="${NBD_PORT}:127.0.0.1:${NBD_PORT}" -v host="$PVE_HOST" '
    index($0, fwd) && index($0, host) {print $1}
  '
}

tunnel_kill_pids(){
  local pids="$1" pid found=0
  if [[ -z "$pids" ]]; then
    return 1
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    found=1
  done <<EOF
$pids
EOF
  (( found ))
}

tunnel_stop(){
  load_config; need pgrep
  local pids
  pids="$(tunnel_pids || true)"
  if tunnel_kill_pids "$pids"; then
    ok "Tunnel stopped"
  else
    warn "No tunnel process found."
  fi
}

start_tunnel(){
  load_config; need ssh; need ss
  [[ "$PVE_HOST" != "CHANGE_ME" ]] || die "Set PVE_HOST in $CONFIG_FILE"
  if [[ "$TUNNEL_MODE" == "direct" ]]; then warn "Direct mode selected; no SSH tunnel started"; return; fi
  if tunnel_listener_exists; then
    warn "Tunnel listener already exists on 127.0.0.1:${NBD_PORT}"
    echo "Run: ./kvm2pve-src.sh tunnel-check"
    echo "If stale, run: ./kvm2pve-src.sh tunnel-restart"
    return 0
  fi
  if [[ "$TUNNEL_MODE" == "autossh" ]]; then need autossh; fi
  local args=(-f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" -p "$PVE_SSH_PORT" "${PVE_SSH_USER}@${PVE_HOST}")
  if [[ "$TUNNEL_MODE" == "autossh" ]]; then
    autossh -M "${AUTOSSH_MONITOR_PORT:-0}" "${args[@]}"
  else
    ssh "${args[@]}"
  fi

  local i
  for i in $(seq 1 "${CHECK_TIMEOUT:-8}"); do
    if tunnel_listener_exists; then
      ok "Tunnel listener is ready on 127.0.0.1:${NBD_PORT}"
      echo "Run next: ./kvm2pve-src.sh tunnel-check"
      return 0
    fi
    sleep 1
  done

  ss -lntp | grep "${NBD_PORT}" || true
  pgrep -af "(${NBD_PORT}:127.0.0.1:${NBD_PORT}|${PVE_HOST})" || true
  die "Tunnel command was sent, but no local listener appeared on 127.0.0.1:${NBD_PORT}"
}

tunnel_restart(){
  load_config; need pgrep
  local pids
  pids="$(tunnel_pids_for_forward || true)"
  if tunnel_kill_pids "$pids"; then
    ok "Tunnel stopped"
  else
    warn "No tunnel process found."
  fi
  sleep 2
  start_tunnel
}

nbd_failure_message(){
  cat <<EOF
ERROR NBD metadata did not respond within ${CHECK_TIMEOUT:-8}s.
Try:
./kvm2pve-src.sh tunnel-restart
./kvm2pve-src.sh tunnel-check
If still failing:
./kvm2pve-src.sh remote-dst-close
./kvm2pve-src.sh remote-export
./kvm2pve-src.sh tunnel-restart
./kvm2pve-src.sh tunnel-check
EOF
}

nbd_read_sample_warning(){
  warn "NBD metadata is reachable, but read sample failed/timed out."
  warn "Continuing is possible, but if full hangs, restart tunnel/export."
}

tunnel_health_ok(){
  load_config
  command -v ss >/dev/null 2>&1 || return 1
  command -v qemu-img >/dev/null 2>&1 || return 1
  ss -lntp | grep "127.0.0.1:${NBD_PORT}" >/dev/null || return 1
  timeout "${CHECK_TIMEOUT:-8}" qemu-img info "nbd:127.0.0.1:${NBD_PORT}:exportname=${NBD_EXPORT}" >/dev/null || return 1
}

tunnel_check(){
  load_config; need ss; need qemu-img; need timeout
  ss -lntp | grep "127.0.0.1:${NBD_PORT}" >/dev/null || die "No local tunnel listener on 127.0.0.1:${NBD_PORT}"
  if ! timeout "${CHECK_TIMEOUT:-8}" qemu-img info "nbd:127.0.0.1:${NBD_PORT}:exportname=${NBD_EXPORT}"; then
    nbd_failure_message >&2
    return 1
  fi
  ok "NBD metadata reachable"
  if ! command -v qemu-io >/dev/null 2>&1; then
    nbd_read_sample_warning
    warn "qemu-io not found; skipped read sample."
    return 0
  fi
  local i
  for i in 1 2 3; do
    if timeout "${NBD_IO_TIMEOUT:-20}" qemu-io -f raw -c "read 0 4k" "nbd://127.0.0.1:${NBD_PORT}/${NBD_EXPORT}"; then
      ok "NBD read sample succeeded"
      return 0
    fi
    warn "NBD read sample attempt $i failed/timed out"
    sleep 2
  done

  nbd_read_sample_warning
}

tunnel_status(){
  load_config
  echo "Expected local listener: 127.0.0.1:${NBD_PORT}"
  ss -lntp | grep "${NBD_PORT}" || true
  echo
  echo "Manual check command:"
  echo "qemu-img info \"nbd:127.0.0.1:${NBD_PORT}:exportname=${NBD_EXPORT}\""
}

attach_target(){
  load_config
  need virsh

  if target_node_exists; then
    ok "Target node already exists: $TARGET_NODE"
    verify_target_node
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
      "server":{
        "type":"inet",
        "host":"127.0.0.1",
        "port":"'"$NBD_PORT"'"
      },
      "export":"'"$NBD_EXPORT"'"
    }
  }
}')"

  printf '%s\n' "$out"

  if printf '%s\n' "$out" | grep -q '"error"'; then
    die "blockdev-add failed"
  fi

  verify_target_node
}

create_bitmap(){
  load_config

  [[ -n "$QEMU_NODE" ]] || die "QEMU_NODE is empty. Run discover first."

  if bitmap_exists; then
    ok "Bitmap already exists: $BITMAP"
    verify_bitmap
    return 0
  fi

  local out

  out="$(qmp '{"execute":"block-dirty-bitmap-add","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}')"

  printf '%s\n' "$out"

  if printf '%s\n' "$out" | grep -q '"error"'; then
    die "block-dirty-bitmap-add failed"
  fi

  verify_bitmap
}


select_backup_method(){
  load_config
  echo
  echo "Select backup method:"
  echo
  echo "1) drive-backup      Recommended for CentOS 7 / old QEMU"
  echo "2) blockdev-backup   Modern QEMU block graph method"
  echo "3) auto              Currently chooses drive-backup"
  echo
  local c method
  read -r -p "Choice [${BACKUP_METHOD:-drive-backup}]: " c
  case "$c" in
    ""|1|drive-backup) method="drive-backup" ;;
    2|blockdev-backup) method="blockdev-backup" ;;
    3|auto) method="auto" ;;
    *) die "Invalid backup method choice: $c" ;;
  esac
  write_key BACKUP_METHOD "$method"
  ok "BACKUP_METHOD=$method"
}

effective_backup_method(){
  case "${BACKUP_METHOD:-drive-backup}" in
    drive-backup) printf 'drive-backup' ;;
    blockdev-backup) printf 'blockdev-backup' ;;
    auto) printf 'drive-backup' ;;
    *) printf 'drive-backup' ;;
  esac
}

job_dismiss(){
  local job="$1" out
  out="$(qmp '{"execute":"job-dismiss","arguments":{"id":"'"$job"'"}}' 2>/dev/null)" || return 1
  printf '%s\n' "$out" | grep -q '"error"' && return 2
  return 0
}

jobs_cmd(){
  load_config
  local out
  if ! out="$(block_jobs_json 2>/dev/null)"; then
    warn "QMP query timed out"
    return 1
  fi
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q '"type"'; then
    echo
    echo "Summary:"
    printf '%s\n' "$out" | block_jobs_summary
  else
    echo
    echo "Summary: no block jobs"
  fi
}

job_dismiss_cmd(){
  load_config
  local job="${1:-}" out
  [[ -n "$job" ]] || die "Usage: ./kvm2pve-src.sh job-dismiss JOB_ID"
  if ! out="$(qmp '{"execute":"job-dismiss","arguments":{"id":"'"$job"'"}}' 2>/dev/null)"; then
    die "QMP job-dismiss timed out or failed"
  fi
  if printf '%s\n' "$out" | grep -q '"error"'; then
    printf '%s\n' "$out"
    warn "not found or already dismissed: $job"
    return 0
  fi
  printf '%s\n' "$out"
  ok "dismissed: $job"
}

jobs_dismiss_all(){
  load_config
  local out job rc any=0
  if ! out="$(block_jobs_json 2>/dev/null)"; then
    die "QMP query timed out"
  fi
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    any=1
    echo "Dismissing job: $job"
    set +e
    job_dismiss "$job"
    rc=$?
    set -e
    case "$rc" in
      0) ok "dismissed" ;;
      2) warn "not found" ;;
      *) die "QMP job-dismiss timed out or failed for $job" ;;
    esac
  done < <(printf '%s\n' "$out" | block_job_ids_from_json)
  (( any )) || echo "No jobs to dismiss"
}

backup_job(){
  local sync="$1" job="$2" extra="" out method target_url

  load_config
  [[ -n "$QEMU_DEVICE" ]] || die "QEMU_DEVICE is empty. Run discover first."

  if [[ "$sync" == "incremental" ]]; then
    require_full_completed
    extra=',"bitmap":"'"$BITMAP"'"'
  fi

  if ! block_jobs_empty; then
    die "A block job is already present. Run watch/status first."
  fi

  method="$(effective_backup_method)"
  ok "Using backup method: $method"

  case "$method" in
    drive-backup)
      target_url="nbd://127.0.0.1:${NBD_PORT}/${NBD_EXPORT}"
      out="$(qmp '{
  "execute":"drive-backup",
  "arguments":{
    "device":"'"$QEMU_DEVICE"'",
    "target":"'"$target_url"'",
    "format":"raw",
    "sync":"'"$sync"'"'"$extra"',
    "job-id":"'"$job"'",
    "mode":"existing",
    "auto-finalize":true,
    "auto-dismiss":false
  }
}')"
      ;;
    blockdev-backup)
      out="$(qmp '{
  "execute":"blockdev-backup",
  "arguments":{
    "device":"'"$QEMU_DEVICE"'",
    "target":"'"$TARGET_NODE"'",
    "sync":"'"$sync"'"'"$extra"',
    "job-id":"'"$job"'",
    "auto-finalize":true,
    "auto-dismiss":false
  }
}')"
      ;;
    *)
      die "Unsupported BACKUP_METHOD: $method"
      ;;
  esac

  printf '%s\n' "$out"

  if printf '%s\n' "$out" | grep -q '"error"'; then
    die "$method failed"
  fi
}

full_sync(){
  load_config
  state_sync_identity
  backup_job full full
  state_write FULL_STARTED 1
  state_write FULL_STARTED_AT "$(now_ts)"
  state_write FULL_JOB_ID full
  state_write FULL_COMPLETED 0
  state_write FULL_COMPLETED_AT ""
  ok "Full sync job submitted. Run: ./kvm2pve-src.sh wait-full"
}

mark_full(){
  load_config
  if ! block_jobs_query_ok_empty; then
    die "A block job is active or QMP returned an error. Refusing to mark full completed."
  fi
  mark_full_completed
  ok "Full sync manually marked completed: $(state_file)"
}

wait_full(){
  load_config
  if [[ "$(state_get FULL_STARTED)" != "1" || "$(state_get FULL_JOB_ID)" != "full" ]]; then
    die "Full job was not started by this state file. Refusing to mark completed automatically. If you are sure full completed successfully, run mark-full."
  fi
  wait_jobs_empty
  mark_full_completed
  ok "Full sync marked completed: $(state_file)"
}

incremental_sync(){
  backup_job incremental inc1
  ok "Incremental sync job submitted. Run: ./kvm2pve-src.sh wait-inc"
}

wait_inc(){
  load_config
  wait_jobs_empty
  ok "Incremental sync completed"
}

report(){
  load_config
  state_sync_identity
  local out
  cat <<EOF
Migration report
----------------
VM name              : $VM_NAME
Source disk          : ${SRC_DISK:-not set}
Proxmox VMID         : $PVE_VMID
Destination disk     : $PVE_DISK
Bitmap               : $BITMAP
Target node          : $TARGET_NODE
Backup method        : ${BACKUP_METHOD:-drive-backup}
Effective method     : $(effective_backup_method)
State file           : $(state_file)
FULL_STARTED         : $(state_get FULL_STARTED)
FULL_STARTED_AT      : $(state_get FULL_STARTED_AT)
FULL_JOB_ID          : $(state_get FULL_JOB_ID)
FULL_COMPLETED       : $(state_get FULL_COMPLETED)
FULL_COMPLETED_AT    : $(state_get FULL_COMPLETED_AT)
FINAL_COMPLETED      : $(state_get FINAL_COMPLETED)
FINAL_COMPLETED_AT   : $(state_get FINAL_COMPLETED_AT)
SOURCE_STOPPED       : $(state_get SOURCE_STOPPED)
SOURCE_STOPPED_AT    : $(state_get SOURCE_STOPPED_AT)
EOF
  if command -v virsh >/dev/null 2>&1; then
    echo "VM state             : $(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
  else
    echo "VM state             : virsh not found"
  fi
  echo "Active block jobs    :"
  if out="$(block_jobs_json 2>/dev/null)"; then
    if printf '%s\n' "$out" | grep -q '"type"'; then
      printf '%s\n' "$out"
      printf '%s\n' "$out" | block_jobs_summary
    elif printf '%s\n' "$out" | grep -q '"error"'; then
      printf '%s\n' "$out"
    else
      echo "none"
    fi
  else
    warn "QMP query timed out"
  fi
}

cutover_check(){
  load_config
  local failed=0 state method
  method="$(effective_backup_method)"
  check_ok(){ printf 'OK   %s\n' "$1"; }
  check_fail(){ printf 'FAIL %s\n' "$1"; failed=1; }

  if command -v virsh >/dev/null 2>&1 && virsh list --all | awk '{print $2}' | grep -qx "$VM_NAME"; then check_ok "VM exists in virsh"; else check_fail "VM exists in virsh"; fi

  state="$(virsh domstate "$VM_NAME" 2>/dev/null | tr '[:upper:]' '[:lower:]' | awk '{print $1}' || true)"
  case "$state" in running|paused|pmsuspended) check_ok "VM is running or paused ($state)" ;; *) check_fail "VM is running or paused (${state:-unknown})" ;; esac

  if block_jobs_query_ok_empty >/dev/null; then check_ok "No active block job"; else check_fail "No active block job"; fi
  if [[ "$method" == "blockdev-backup" ]]; then
    if target_node_exists; then check_ok "Target node exists"; else check_fail "Target node exists"; fi
  else
    check_ok "Target node not required for drive-backup"
  fi
  if bitmap_exists; then check_ok "Bitmap exists"; else check_fail "Bitmap exists"; fi
  if command -v ss >/dev/null 2>&1 && ss -lntp | grep "127.0.0.1:${NBD_PORT}" >/dev/null; then check_ok "Local tunnel listener 127.0.0.1:${NBD_PORT}"; else check_fail "Local tunnel listener 127.0.0.1:${NBD_PORT}"; fi
  if tunnel_health_ok >/dev/null 2>&1; then check_ok "NBD export reachable"; else check_fail "NBD export reachable"; fi
  if state_is_full_completed; then check_ok "FULL_COMPLETED=1"; else check_fail "FULL_COMPLETED=1"; fi

  return "$failed"
}

verify_sample(){
  cat <<EOF
verify-sample is not implemented yet.

A safe implementation should compare read-only samples from SRC_DISK and the
NBD export without writing to either side. This placeholder is intentional to
avoid adding risky disk sampling logic without production testing.
EOF
  return 1
}

watch_jobs(){
  load_config
  local out job status parsed_status offset len progress

  while true; do
    clear || true

    echo "kvm2pve watch"
    echo "------------"
    echo "VM            : $VM_NAME"
    echo "Backup method : $(effective_backup_method)"
    echo "State         : $(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    echo

    if ! out="$(block_jobs_json 2>/dev/null)"; then
      warn "QMP query timed out"
      echo
      echo "Retrying every 2 seconds..."
      sleep 2
      continue
    fi

    if printf '%s\n' "$out" | grep -q '"error"'; then
      warn "QMP returned an error"
      printf '%s\n' "$out"
      sleep 2
      continue
    fi

    if ! printf '%s\n' "$out" | grep -q '"type"'; then
      echo "No active block job."
      echo
      echo "Tip: use wait-full or wait-inc after submitting a job."
      sleep 2
      continue
    fi

    job="$(printf '%s\n' "$out" | awk -F'"' '/"device"/ {print $4; exit}')"
    status="$(printf '%s\n' "$out" | awk -F'"' '/"status"/ {print $4; exit}')"
    IFS=$'\t' read -r offset len parsed_status <<< "$(printf '%s\n' "$out" | progress_from_jobs_json)"
    [[ -n "$parsed_status" ]] && status="$parsed_status"

    echo "Job           : ${job:-unknown}"
    progress="$(progress_line "$offset" "$len" "${status:-running}")"
    echo "$progress"

    if printf '%s\n' "$out" | grep -q '"error"'; then
      echo
      printf '%s\n' "$out" | grep '"error"' || true
    fi

    if [[ "$status" == "concluded" ]]; then
      echo
      echo "Job concluded."
      echo "Run: ./kvm2pve-src.sh jobs-dismiss-all"
      echo
      echo "Note: watch is read-only and will not dismiss jobs."
    fi

    sleep 2
  done
}

status(){
  load_config
  local out
  virsh domstate "$VM_NAME" || true
  if out="$(qmp '{"execute":"query-block-jobs"}' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    warn "QMP query timed out"
  fi
  if out="$(qmp '{"execute":"query-block"}' 2>/dev/null)"; then
    printf '%s\n' "$out" | grep -A20 -B5 "$BITMAP" || true
  else
    warn "QMP query timed out"
  fi
}

final_cutover_run(){
  virsh suspend "$VM_NAME" || die "virsh suspend failed"
  wait_vm_paused
  backup_job incremental final
  wait_jobs_empty
  state_sync_identity
  state_write FINAL_COMPLETED 1
  state_write FINAL_COMPLETED_AT "$(now_ts)"
  ok "Final incremental completed"
}

final_cutover(){
  load_config
  require_full_completed
  warn "Before final cutover, lock customer/Virtualizor panel controls."
  confirm "Suspend source VM and run FINAL incremental now?" || die "Aborted"
  final_cutover_run
}

cleanup(){
  load_config
  pkill -f "${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  if bitmap_exists; then
    qmp '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"'"$QEMU_NODE"'","name":"'"$BITMAP"'"}}' || true
  fi
  ok "Source cleanup attempted"
}

stop_source_run(){
  load_config
  if ! block_jobs_empty; then
    block_jobs_json
    die "Refusing to stop source VM while a block job is still present"
  fi
  virsh destroy "$VM_NAME"
  state_sync_identity
  state_write SOURCE_STOPPED 1
  state_write SOURCE_STOPPED_AT "$(now_ts)"
  ok "Source VM stopped and state updated"
}

stop_source(){
  load_config
  warn "This stops the source VM. Use only after final incremental completed."
  confirm "Destroy/stop source VM $VM_NAME now?" || die "Aborted"
  stop_source_run
}


migration_active_tunnels(){
  local nbd_port old_host
  nbd_port="$(get_conf NBD_PORT)"
  nbd_port="${nbd_port:-10809}"
  old_host="$(get_conf PVE_HOST)"
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -af '(^|/)(autossh|ssh)( |$)' 2>/dev/null | awk -v fwd="${nbd_port}:127.0.0.1:${nbd_port}" -v host="$old_host" '
    index($0, fwd) && (host == "" || index($0, host)) {print}
  '
}

migration_block_jobs_summary(){
  local old_vm qmp_timeout out
  old_vm="$(get_conf VM_NAME)"
  [[ -n "$old_vm" ]] || return 1
  command -v virsh >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  qmp_timeout="$(get_conf QMP_TIMEOUT)"
  qmp_timeout="${qmp_timeout:-20}"
  if out="$(timeout "$qmp_timeout" virsh qemu-monitor-command "$old_vm" --pretty '{"execute":"query-block-jobs"}' 2>/dev/null)"; then
    if printf '%s\n' "$out" | grep -q '"type"'; then
      echo "VM $old_vm:"
      printf '%s\n' "$out" | block_jobs_summary
      return 0
    fi
  fi
  return 1
}

migration_state_files_for_other_vm(){
  local vm="$1" wanted dir f base found=0
  wanted=".kvm2pve-state-$(sanitize_name "$vm")"
  dir="$(config_dir)"
  shopt -s nullglob
  for f in "$dir"/.kvm2pve-state-*; do
    base="${f##*/}"
    [[ "$base" == "$wanted" ]] && continue
    printf '%s\n' "$f"
    found=1
  done
  shopt -u nullglob
  (( found ))
}

migrate_preparation_guard(){
  local vm="$1" tunnels jobs states found=0
  tunnels="$(migration_active_tunnels || true)"
  jobs="$(migration_block_jobs_summary || true)"
  states="$(migration_state_files_for_other_vm "$vm" || true)"

  [[ -n "$tunnels" ]] && found=1
  [[ -n "$jobs" ]] && found=1
  [[ -n "$states" ]] && found=1
  (( found )) || return 0

  cat <<EOF

Previous migration artifacts detected:
EOF
  if [[ -n "$tunnels" ]]; then
    cat <<EOF

Active SSH/autossh tunnel(s):
$tunnels
EOF
  fi
  if [[ -n "$jobs" ]]; then
    cat <<EOF

Active qemu block job(s):
$jobs
EOF
  fi
  if [[ -n "$states" ]]; then
    cat <<EOF

State file(s) for another VM:
$states
EOF
  fi

  echo
  echo "A previous migration session appears to exist."
  if ! ask_yes_default "Clean migration artifacts and continue?"; then
    die "Aborted"
  fi

  [[ -f "$CONFIG_FILE" ]] || die "Cannot clean migration artifacts because config is missing: $CONFIG_FILE"
  tunnel_stop || warn "No local tunnel stopped or tunnel-stop failed."
  remote_dst_close || warn "No remote NBD export closed or remote close failed."
  jobs_dismiss_all
}

migrate_workflow(){
  local vm="$1" pve_vmid="$2" pve_host="$3" ssh_port="${4:-22}" ssh_user="${5:-root}"

  [[ -n "$vm" && -n "$pve_vmid" && -n "$pve_host" ]] || die "Usage: ./kvm2pve-src.sh migrate VM_NAME PVE_VMID PVE_HOST [SSH_PORT] [SSH_USER]"
  case "$pve_vmid" in *[!0-9]*|'') die "Destination Proxmox VMID must be numeric" ;; esac
  case "$ssh_port" in *[!0-9]*|'') die "SSH port must be numeric" ;; esac
  [[ -n "$ssh_user" ]] || die "SSH user must not be empty"

  cat <<EOF
kvm2pve migration
-----------------
Source VM        : $vm
Destination VMID : $pve_vmid
Destination Host : $pve_host
SSH              : ${ssh_user}@${pve_host}:${ssh_port}
Backup method    : drive-backup
EOF

  migrate_preparation_guard "$vm"
  ask_exact "Continue with preparation? Type YES:" "YES" || die "Aborted"

  # remote_prepare internal signature is: VM_NAME PVE_HOST PVE_VMID SSH_PORT SSH_USER
  remote_prepare "$vm" "$pve_host" "$pve_vmid" "$ssh_port" "$ssh_user"
  preflight

  write_key BACKUP_METHOD drive-backup
  load_config

  remote_export
  start_tunnel
  tunnel_check || die "NBD metadata check failed. Fix tunnel/export before migration."

  create_bitmap
  check_bitmap
  report

  if ! block_jobs_empty; then
    warn "Existing block job found before FULL sync."
    jobs_cmd
    warn "Trying to dismiss concluded/stale jobs before FULL sync."
    jobs_dismiss_all
    if ! block_jobs_empty; then
      jobs_cmd
      die "A block job is still present. Resolve it before starting FULL sync."
    fi
  fi

  cat <<EOF

Preparation completed.
Ready to start FULL sync.
EOF
  if ! ask_exact "Start FULL sync now? Type FULL:" "FULL"; then
    cat <<EOF
Full sync not started.
Resume manually:
  ./kvm2pve-src.sh full
  ./kvm2pve-src.sh wait-full
EOF
    return 0
  fi

  full_sync
  wait_full
  report

  cat <<EOF

FULL sync completed.
Cutover will suspend the source VM and run final incremental.
Lock customer/Virtualizor controls before continuing.
EOF
  if ! ask_exact "Start CUTOVER now? Type CUTOVER:" "CUTOVER"; then
    cat <<EOF
Cutover not started.
Resume manually:
  ./kvm2pve-src.sh cutover-check
  ./kvm2pve-src.sh final
  ./kvm2pve-src.sh report
EOF
    return 0
  fi

  if ask_yes_default "Run pre-cutover incremental sync first?"; then
    cat <<EOF

Starting pre-cutover incremental sync while source VM remains running...
EOF
    incremental_sync
    wait_inc

    echo
    report

    cat <<EOF

Pre-cutover incremental completed.
Source VM is still running.
EOF
  fi

  cutover_check
  final_cutover_run
  report

  cat <<EOF

Cutover completed.
Destination VM can now be booted from Proxmox.
Source VM still exists unless stopped.
EOF
  if ask_exact "Stop source VM now? Type STOP:" "STOP"; then
    stop_source_run
  else
    cat <<EOF
Source VM was not stopped.
You can stop later:
  ./kvm2pve-src.sh stop-source
EOF
  fi

  if ask_exact "Close destination NBD export and local tunnel now? Type CLEAN:" "CLEAN"; then
    tunnel_stop || warn "Tunnel stop failed or no tunnel found."
    remote_dst_close || warn "Remote NBD close failed or no export found."
    ok "Cleanup completed"
  else
    cat <<EOF
Cleanup skipped.
You can clean later:
  ./kvm2pve-src.sh tunnel-stop
  ./kvm2pve-src.sh remote-dst-close
EOF
  fi

  cat <<EOF
Migration workflow finished.
Review:
  ./kvm2pve-src.sh report
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init) init_config ;;
  discover) discover "$@" ;;
  show) show_config ;;
  apply-handoff) apply_handoff "${1:-}" ;;
  remote-prepare|migrate-prepare) remote_prepare "${1:-}" "${3:-}" "${2:-}" "${4:-22}" "${5:-root}" ;;
  migrate) migrate_workflow "${1:-}" "${2:-}" "${3:-}" "${4:-22}" "${5:-root}" ;;
  remote-export) remote_export ;;
  remote-dst-status) remote_dst_status ;;
  remote-dst-close) remote_dst_close ;;
  quick) quick_start "${1:-}" "${2:-}" ;;
  next) next_steps ;;
  preflight) preflight ;;
  tunnel) start_tunnel ;;
  tunnel-stop) tunnel_stop ;;
  tunnel-restart) tunnel_restart ;;
  tunnel-status) tunnel_status ;;
  tunnel-check) tunnel_check ;;
  attach-target) attach_target ;;
  check-target) check_target ;;
  bitmap) create_bitmap ;;
  check-bitmap) check_bitmap ;;
  full) full_sync ;;
  wait-full) wait_full ;;
  mark-full) mark_full ;;
  set-backup-method) select_backup_method ;;
  incremental) incremental_sync ;;
  wait-inc) wait_inc ;;
  jobs) jobs_cmd ;;
  job-dismiss) job_dismiss_cmd "${1:-}" ;;
  jobs-dismiss-all) jobs_dismiss_all ;;
  cutover-check) cutover_check ;;
  check-paused) check_paused ;;
  final) final_cutover ;;
  watch) watch_jobs ;;
  status) status ;;
  report) report ;;
  verify-sample) verify_sample ;;
  cleanup) cleanup ;;
  stop-source) stop_source ;;
  -h|--help|help|"") usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
