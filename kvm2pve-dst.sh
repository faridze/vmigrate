#!/usr/bin/env bash
# kvm2pve destination-side helper for Proxmox
set -Eeuo pipefail

VERSION="0.2.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info(){ echo "${BLUE}>>${NC} $*"; }
ok(){ echo "${GREEN}OK${NC} $*"; }
warn(){ echo "${YELLOW}WARN${NC} $*"; }
die(){ echo "${RED}ERROR${NC} $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage(){ cat <<EOF
kvm2pve-dst.sh v${VERSION}

Usage:
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

Recommended first run:
  ./kvm2pve-dst.sh quick 2672
EOF
}

ask(){ local var="$1" prompt="$2" def="${3:-}" val; read -r -p "$prompt${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
confirm(){ local prompt="$1" ans; read -r -p "$prompt [yes/no]: " ans; [[ "$ans" == "yes" ]]; }

get_conf(){ local key="$1"; [[ -f "$CONFIG_FILE" ]] || return 0; awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$CONFIG_FILE"; }

load_config(){
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE. Run: ./kvm2pve-dst.sh discover VMID"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${VM_NAME:?}"; : "${PVE_VMID:?}"; : "${PVE_DISK:?}"
  NBD_PORT="${NBD_PORT:-10809}"
  NBD_EXPORT="${NBD_EXPORT:-vm-${PVE_VMID}}"
}

init_config(){
  local vm vmid disk nbd_port nbd_export
  ask vm "Source VM name / display name" "kvm3023"
  ask vmid "Destination Proxmox VMID" "2672"
  ask disk "Destination disk path" "/dev/pve/vm-${vmid}-disk-0"
  ask nbd_port "NBD port" "10809"
  ask nbd_export "NBD export name" "vm-${vmid}"
  cat > "$CONFIG_FILE" <<EOF
VM_NAME=$vm
PVE_VMID=$vmid
PVE_DISK=$disk
NBD_PORT=$nbd_port
NBD_EXPORT=$nbd_export
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config written: $CONFIG_FILE"
}

vm_name_from_qm(){
  local vmid="$1" name
  name="$(qm config "$vmid" 2>/dev/null | awk -F': ' '$1=="name" {print $2; exit}')"
  [[ -n "$name" ]] || name="kvm${vmid}"
  printf '%s' "$name"
}

lvm_path_for_lv(){
  local lv="$1"
  command -v lvs >/dev/null 2>&1 || return 0
  lvs --noheadings -o vg_name,lv_name 2>/dev/null | awk -v lv="$lv" '$2==lv {print "/dev/" $1 "/" $2; exit}'
}

lvm_path_for_vmid(){
  local vmid="$1"
  command -v lvs >/dev/null 2>&1 || return 0
  lvs --noheadings -o vg_name,lv_name 2>/dev/null | awk -v vmid="$vmid" '
    $2 ~ ("^vm-" vmid "-") {print "/dev/" $1 "/" $2; exit}
    $2 ~ vmid {fallback="/dev/" $1 "/" $2}
    END {if (fallback != "") print fallback}'
}

first_disk_from_qm(){
  local vmid="$1" vol disk lv
  vol="$(qm config "$vmid" 2>/dev/null | awk -F': ' '
    $1 ~ /^(scsi|virtio|sata|ide)[0-9]+$/ {
      split($2,a,",");
      print a[1];
      exit
    }')"

  if [[ -n "$vol" ]]; then
    if [[ "$vol" == /* ]]; then
      printf '%s' "$vol"
      return 0
    fi
    if [[ "$vol" == *:* ]]; then
      lv="${vol#*:}"
      disk="$(lvm_path_for_lv "$lv")"
      if [[ -n "$disk" ]]; then
        printf '%s' "$disk"
        return 0
      fi
    fi
  fi

  disk="$(lvm_path_for_vmid "$vmid")"
  if [[ -n "$disk" ]]; then
    printf '%s' "$disk"
    return 0
  fi

  printf '/dev/pve/vm-%s-disk-0' "$vmid"
}

discover_config(){
  local vmid_arg="${1:-}" vmid vm_name disk nbd_port nbd_export
  need qm
  vmid="$vmid_arg"
  [[ -n "$vmid" ]] || ask vmid "Destination Proxmox VMID" "2672"
  qm config "$vmid" >/dev/null 2>&1 || warn "qm config failed for VMID $vmid; continuing with manual/default values"
  vm_name="$(vm_name_from_qm "$vmid")"
  disk="$(first_disk_from_qm "$vmid")"
  nbd_port="$(get_conf NBD_PORT)"; [[ -n "$nbd_port" ]] || nbd_port="10809"
  nbd_export="vm-${vmid}"

  cat <<EOF

Detected destination values
---------------------------
Config file : $CONFIG_FILE
VMID        : $vmid
VM name     : $vm_name
Disk        : $disk
NBD port    : $nbd_port
NBD export  : $nbd_export
EOF

  if confirm "Write these values to destination config?"; then
    cat > "$CONFIG_FILE" <<EOF
VM_NAME=$vm_name
PVE_VMID=$vmid
PVE_DISK=$disk
NBD_PORT=$nbd_port
NBD_EXPORT=$nbd_export
EOF
    chmod 600 "$CONFIG_FILE"
    ok "Config written: $CONFIG_FILE"
  else
    warn "Config not changed"
  fi
}

show_config(){
  load_config
  cat <<EOF
Destination Proxmox
-------------------
VM name/export : $VM_NAME
VMID           : $PVE_VMID
Disk           : $PVE_DISK
NBD            : 127.0.0.1:${NBD_PORT}, export=${NBD_EXPORT}
EOF
}

handoff_token(){
  load_config
  need base64
  {
    printf 'PVE_VMID=%s\n' "$PVE_VMID"
    printf 'PVE_DISK=%s\n' "$PVE_DISK"
    printf 'NBD_PORT=%s\n' "$NBD_PORT"
    printf 'NBD_EXPORT=%s\n' "$NBD_EXPORT"
  } | base64 | tr -d '\r\n' | sed 's/^/KVM2PVE_HANDOFF_V1:/'
}

quick_start(){
  local vmid_arg="${1:-}" token

  if [[ -n "$vmid_arg" || ! -f "$CONFIG_FILE" ]]; then
    discover_config "$vmid_arg"
  else
    info "Using existing destination config: $CONFIG_FILE"
  fi

  load_config
  token="$(handoff_token)"

  cat <<EOF

Destination quick summary
-------------------------
Config file : $CONFIG_FILE
VMID        : $PVE_VMID
Disk        : $PVE_DISK
NBD port    : $NBD_PORT
NBD export  : $NBD_EXPORT

Handoff token
-------------
$token

Recommended quick path
----------------------
1) On source, use the handoff token and let quick discover the source VM:
./kvm2pve-src.sh quick '$token'

2) On destination, start the NBD export:
./kvm2pve-dst.sh preflight
./kvm2pve-dst.sh export

3) On source, continue with the commands printed by quick/next:
./kvm2pve-src.sh tunnel
./kvm2pve-src.sh tunnel-check
./kvm2pve-src.sh attach-target
./kvm2pve-src.sh check-target
./kvm2pve-src.sh bitmap
./kvm2pve-src.sh check-bitmap
./kvm2pve-src.sh full
./kvm2pve-src.sh wait-full
./kvm2pve-src.sh report

4) For cutover, run on source:
./kvm2pve-src.sh cutover-check
./kvm2pve-src.sh final
./kvm2pve-src.sh report
./kvm2pve-src.sh stop-source

5) After source final/stop-source succeeds, run on destination:
./kvm2pve-dst.sh close
./kvm2pve-dst.sh boot
EOF
}

port_in_use(){ ss -lntp | grep -q "127.0.0.1:${NBD_PORT}"; }

preflight(){
  load_config; need qm; need qemu-nbd; need ss
  qm config "$PVE_VMID" >/dev/null 2>&1 || warn "VMID $PVE_VMID not found in qm; disk-only export may still work"
  [[ -b "$PVE_DISK" || -f "$PVE_DISK" ]] || die "Destination disk not found: $PVE_DISK"
  if port_in_use; then die "NBD port already in use: 127.0.0.1:${NBD_PORT}"; fi
  ok "Destination preflight checks passed"
}

status(){
  load_config
  qm status "$PVE_VMID" 2>/dev/null || true
  pgrep -a qemu-nbd || true
  ss -lntp | grep "$NBD_PORT" || true
  [[ -e "$PVE_DISK" ]] && blockdev --getsize64 "$PVE_DISK" 2>/dev/null || true
}

export_disk(){
  load_config; need qemu-nbd; need ss
  [[ -b "$PVE_DISK" || -f "$PVE_DISK" ]] || die "Destination disk not found: $PVE_DISK"
  if qm status "$PVE_VMID" >/dev/null 2>&1; then
    qm stop "$PVE_VMID" >/dev/null 2>&1 || true
  else
    warn "VMID $PVE_VMID not found by qm status; continuing with disk export only"
  fi
  if port_in_use; then
    die "NBD port already in use: 127.0.0.1:${NBD_PORT}"
  fi
  pgrep -a qemu-nbd || true
  info "Starting qemu-nbd on 127.0.0.1:${NBD_PORT} export=${NBD_EXPORT} disk=${PVE_DISK}"
  qemu-nbd -t --fork -b 127.0.0.1 -p "$NBD_PORT" -x "$NBD_EXPORT" -f raw "$PVE_DISK"
  sleep 1
  port_in_use || die "qemu-nbd did not start"
  ok "NBD export is ready"
}

close_export(){
  load_config
  pkill -f "qemu-nbd.*${NBD_PORT}.*${NBD_EXPORT}" >/dev/null 2>&1 || true
  pkill -f "qemu-nbd.*${PVE_DISK}" >/dev/null 2>&1 || true
  sleep 1
  ss -lntp | grep "$NBD_PORT" && warn "Port still appears open" || ok "NBD export closed"
}

boot_vm(){
  load_config
  close_export || true
  qm start "$PVE_VMID"
  ok "Boot command sent for VMID $PVE_VMID"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  discover) discover_config "${1:-}" ;;
  init) init_config ;;
  show) show_config ;;
  handoff) handoff_token ;;
  quick) quick_start "${1:-}" ;;
  preflight) preflight ;;
  export) export_disk ;;
  close) close_export ;;
  boot) boot_vm ;;
  status) status ;;
  -h|--help|help|"") usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
