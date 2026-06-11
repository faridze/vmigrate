#!/usr/bin/env bash
# kvm2pve - KVM/libvirt to Proxmox live disk migration helper
#
# Workflow:
#   1) Export the target Proxmox block device with qemu-nbd on 127.0.0.1
#   2) Create an SSH/autossh tunnel from source to destination
#   3) Run virsh blockcopy from source disk to the tunneled NBD export
#   4) Suspend the source VM and pivot its disk to the copied destination
#   5) Create a Proxmox VM config and attach the migrated disk
#
# IMPORTANT:
#   Test on a small non-production VM first.
#   This tool moves only the disk. It does not live-migrate RAM/CPU state.

set -Eeuo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/config.txt"
CONFIG_FILE="${KVM2PVE_CONFIG:-$DEFAULT_CONFIG}"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE=""

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

usage() {
  cat <<EOF
kvm2pve v${VERSION}

Usage:
  ./kvm2pve.sh init [config-file]
  ./kvm2pve.sh preflight [config-file]
  ./kvm2pve.sh migrate [config-file]
  ./kvm2pve.sh cleanup-source [config-file]
  ./kvm2pve.sh show [config-file]

Default config:
  ${DEFAULT_CONFIG}

Typical first run:
  ./kvm2pve.sh init
  ./kvm2pve.sh preflight
  ./kvm2pve.sh migrate

EOF
}

info() { echo "${BLUE}>>${NC} $*"; }
ok() { echo "${GREEN}OK${NC} $*"; }
warn() { echo "${YELLOW}WARN${NC} $*"; }
die() { echo "${RED}ERROR${NC} $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ask() {
  local var="$1"
  local prompt="$2"
  local def="${3:-}"
  local val
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " val
    val="${val:-$def}"
  else
    read -r -p "$prompt: " val
  fi
  printf -v "$var" '%s' "$val"
}

ask_yes_no() {
  local var="$1"
  local prompt="$2"
  local def="${3:-no}"
  local val
  while true; do
    read -r -p "$prompt [$def]: " val
    val="${val:-$def}"
    case "$val" in
      yes|y|Y) printf -v "$var" "yes"; return ;;
      no|n|N) printf -v "$var" "no"; return ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE. Run: ./kvm2pve.sh init"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${SRC_VM_NAME:?Missing SRC_VM_NAME in config}"
  : "${SRC_DISK:?Missing SRC_DISK in config}"
  : "${PVE_HOST:?Missing PVE_HOST in config}"
  : "${PVE_SSH_USER:?Missing PVE_SSH_USER in config}"
  : "${PVE_TARGET_DISK:?Missing PVE_TARGET_DISK in config}"
  : "${PVE_VMID:?Missing PVE_VMID in config}"
  : "${PVE_VM_NAME:?Missing PVE_VM_NAME in config}"
  : "${PVE_RAM_MB:?Missing PVE_RAM_MB in config}"
  : "${PVE_CORES:?Missing PVE_CORES in config}"

  NBD_PORT="${NBD_PORT:-10809}"
  TUNNEL_MODE="${TUNNEL_MODE:-autossh}"       # autossh | ssh | direct
  AUTOSSH_MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20000}"
  SSH_PORT="${SSH_PORT:-22}"
  SSH_KEY="${SSH_KEY:-}"
  SSH_OPTS="${SSH_OPTS:-}"
  PVE_ATTACH_MODE="${PVE_ATTACH_MODE:-direct}" # direct | volume | args
  PVE_DISK_REF="${PVE_DISK_REF:-$PVE_TARGET_DISK}"
  PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"
  PVE_NET_MODEL="${PVE_NET_MODEL:-virtio}"
  PVE_MAC="${PVE_MAC:-}"
  PVE_OS_TYPE="${PVE_OS_TYPE:-l26}"
  PVE_SCSI_HW="${PVE_SCSI_HW:-virtio-scsi-pci}"
  PVE_BOOT_DISK="${PVE_BOOT_DISK:-scsi0}"
  CREATE_PVE_VM="${CREATE_PVE_VM:-yes}"
  START_PVE_VM="${START_PVE_VM:-yes}"
  INSTALL_PACKAGES="${INSTALL_PACKAGES:-yes}"
  AUTO_CLEANUP_TUNNEL="${AUTO_CLEANUP_TUNNEL:-yes}"
  AUTO_STOP_NBD="${AUTO_STOP_NBD:-yes}"
}

ssh_base() {
  local args=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 -o ServerAliveCountMax=6)
  if [[ -n "$SSH_KEY" ]]; then
    args+=(-i "$SSH_KEY")
  fi
  if [[ -n "$SSH_OPTS" ]]; then
    # shellcheck disable=SC2206
    local extra=( $SSH_OPTS )
    args+=("${extra[@]}")
  fi
  printf '%q ' ssh "${args[@]}" "${PVE_SSH_USER}@${PVE_HOST}"
}

run_remote() {
  local base
  base="$(ssh_base)"
  # shellcheck disable=SC2086
  eval "$base" -- "$@"
}

remote_script() {
  local base
  base="$(ssh_base)"
  # shellcheck disable=SC2086
  eval "$base" 'bash -s'
}

confirm_config() {
  cat <<EOF

Migration summary
-----------------
Source VM          : ${SRC_VM_NAME}
Source disk        : ${SRC_DISK}

Proxmox host       : ${PVE_SSH_USER}@${PVE_HOST}:${SSH_PORT}
Proxmox target disk: ${PVE_TARGET_DISK}
Proxmox VMID/name  : ${PVE_VMID} / ${PVE_VM_NAME}
RAM / cores        : ${PVE_RAM_MB} MB / ${PVE_CORES}

NBD port           : ${NBD_PORT}
Tunnel mode        : ${TUNNEL_MODE}
Attach mode        : ${PVE_ATTACH_MODE}
Disk reference     : ${PVE_DISK_REF}

EOF
}

init_config() {
  local target="${1:-$CONFIG_FILE}"
  mkdir -p "$(dirname "$target")"

  local src_vm src_disk pve_host pve_user ssh_port pve_disk pve_vmid pve_name ram cores
  local nbd_port tunnel autossh_port attach_mode disk_ref bridge net_model mac create_vm start_vm

  echo "This wizard creates a config file: $target"
  ask src_vm "Source VM name in virsh" "vm2365"
  ask src_disk "Source disk path" "/dev/volgroup/kvm2365_img"
  ask pve_host "Proxmox host/IP" "1.2.168.2"
  ask pve_user "Proxmox SSH user" "root"
  ask ssh_port "Proxmox SSH port" "22"
  ask pve_disk "Target disk/LV path on Proxmox" "/dev/volgroup/vsv2365-lv"
  ask pve_vmid "Proxmox VMID" "2365"
  ask pve_name "Proxmox VM name" "$src_vm"
  ask ram "Proxmox RAM MB" "4096"
  ask cores "Proxmox vCPU cores" "2"
  ask nbd_port "Local NBD port" "10809"

  echo
  echo "Tunnel mode:"
  echo "  autossh = recommended for remote datacenters"
  echo "  ssh     = normal SSH tunnel"
  echo "  direct  = no tunnel, LAN-only and insecure unless firewalled"
  ask tunnel "Tunnel mode" "autossh"
  ask autossh_port "autossh monitor port" "20000"

  echo
  echo "Proxmox disk attach mode:"
  echo "  direct = qm set VMID --scsi0 /dev/..."
  echo "  volume = qm set VMID --scsi0 storage:volume"
  echo "  args   = qm set VMID --args '-drive file=/dev/...'"
  ask attach_mode "Attach mode" "direct"
  ask disk_ref "Proxmox disk reference for attach" "$pve_disk"
  ask bridge "Proxmox bridge" "vmbr0"
  ask net_model "Network model" "virtio"
  ask mac "MAC address (empty to let Proxmox generate)" ""
  ask_yes_no create_vm "Create Proxmox VM config automatically?" "yes"
  ask_yes_no start_vm "Start VM on Proxmox automatically?" "yes"

  cat > "$target" <<EOF
# kvm2pve config
# Generated by ./kvm2pve.sh init

SRC_VM_NAME=${src_vm}
SRC_DISK=${src_disk}

PVE_HOST=${pve_host}
PVE_SSH_USER=${pve_user}
SSH_PORT=${ssh_port}
SSH_KEY=
SSH_OPTS=

PVE_TARGET_DISK=${pve_disk}
PVE_VMID=${pve_vmid}
PVE_VM_NAME=${pve_name}
PVE_RAM_MB=${ram}
PVE_CORES=${cores}
PVE_BRIDGE=${bridge}
PVE_NET_MODEL=${net_model}
PVE_MAC=${mac}
PVE_OS_TYPE=l26
PVE_SCSI_HW=virtio-scsi-pci
PVE_BOOT_DISK=scsi0

# direct | volume | args
PVE_ATTACH_MODE=${attach_mode}
PVE_DISK_REF=${disk_ref}

# yes | no
CREATE_PVE_VM=${create_vm}
START_PVE_VM=${start_vm}

# autossh | ssh | direct
TUNNEL_MODE=${tunnel}
NBD_PORT=${nbd_port}
AUTOSSH_MONITOR_PORT=${autossh_port}

INSTALL_PACKAGES=yes
AUTO_CLEANUP_TUNNEL=yes
AUTO_STOP_NBD=yes
EOF

  chmod 600 "$target"
  ok "Config written: $target"
}

preflight() {
  load_config
  confirm_config

  info "Checking local commands..."
  need_cmd virsh
  need_cmd ssh
  if [[ "$TUNNEL_MODE" == "autossh" ]]; then
    need_cmd autossh
  fi
  ok "Local command checks passed"

  info "Checking source VM exists..."
  virsh list --all | grep -qE "^[[:space:]-]*[0-9-]*[[:space:]]+${SRC_VM_NAME}[[:space:]]" || die "Source VM not found in virsh: $SRC_VM_NAME"
  ok "Source VM exists"

  info "Checking source disk..."
  [[ -b "$SRC_DISK" || -f "$SRC_DISK" ]] || die "Source disk is not a block device or file: $SRC_DISK"
  local src_size
  src_size="$(blockdev --getsize64 "$SRC_DISK" 2>/dev/null || stat -c %s "$SRC_DISK")"
  ok "Source disk size: $src_size bytes"

  info "Checking SSH to Proxmox..."
  run_remote "echo connected" >/dev/null
  ok "SSH works"

  info "Checking Proxmox commands and target disk..."
  run_remote "command -v qm >/dev/null" || die "qm not found on Proxmox host"
  run_remote "test -b '$PVE_TARGET_DISK' -o -f '$PVE_TARGET_DISK'" || die "Target disk does not exist on Proxmox: $PVE_TARGET_DISK"
  local dst_size
  dst_size="$(run_remote "blockdev --getsize64 '$PVE_TARGET_DISK' 2>/dev/null || stat -c %s '$PVE_TARGET_DISK'")"
  ok "Target disk size: $dst_size bytes"

  if [[ "$src_size" != "$dst_size" ]]; then
    warn "Source and target disk sizes differ."
    warn "Source: $src_size bytes"
    warn "Target: $dst_size bytes"
    die "Refusing to continue. Target disk should match source disk size exactly."
  fi

  info "Checking VMID availability on Proxmox..."
  if run_remote "qm status '$PVE_VMID' >/dev/null 2>&1"; then
    die "Proxmox VMID already exists: $PVE_VMID"
  fi
  ok "VMID is free"

  info "Checking NBD port availability on Proxmox localhost..."
  if run_remote "ss -ltn | grep -q ':${NBD_PORT} '"; then
    die "NBD port already in use on Proxmox: $NBD_PORT"
  fi
  ok "NBD port is free"

  ok "Preflight completed successfully"
}

install_deps() {
  load_config
  if [[ "$INSTALL_PACKAGES" != "yes" ]]; then
    warn "INSTALL_PACKAGES=no, skipping package installation"
    return
  fi

  info "Installing local dependencies if needed..."
  if [[ "$TUNNEL_MODE" == "autossh" && ! "$(command -v autossh || true)" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y autossh
    elif command -v yum >/dev/null 2>&1; then
      yum install -y epel-release || true
      yum install -y autossh
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y autossh
    else
      die "Cannot install autossh automatically. Install it manually."
    fi
  fi

  info "Installing qemu-utils on Proxmox if needed..."
  run_remote "if ! command -v qemu-nbd >/dev/null 2>&1; then apt-get update -y && apt-get install -y qemu-utils; fi"
  run_remote "modprobe nbd max_part=16 || true"
  ok "Dependency setup done"
}

prepare_nbd() {
  load_config
  info "Starting qemu-nbd on Proxmox localhost:${NBD_PORT}"

  run_remote "pkill -f 'qemu-nbd.*--export-name=${SRC_VM_NAME}.*${PVE_TARGET_DISK}' >/dev/null 2>&1 || true"
  run_remote "nohup qemu-nbd --listen=127.0.0.1:${NBD_PORT} --export-name=${SRC_VM_NAME} '${PVE_TARGET_DISK}' >/tmp/kvm2pve-qemu-nbd-${SRC_VM_NAME}.log 2>&1 &"

  sleep 1
  run_remote "ss -ltn | grep -q '127.0.0.1:${NBD_PORT}'" || die "qemu-nbd did not start. Check /tmp/kvm2pve-qemu-nbd-${SRC_VM_NAME}.log on Proxmox."
  ok "NBD export is listening on Proxmox localhost:${NBD_PORT}"
}

start_tunnel() {
  load_config
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    warn "Direct NBD mode selected. No SSH tunnel will be created."
    return
  fi

  info "Starting ${TUNNEL_MODE} tunnel localhost:${NBD_PORT} -> Proxmox localhost:${NBD_PORT}"

  # Kill previous local tunnel for this port, if any.
  pkill -f "ssh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  pkill -f "autossh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true

  local ssh_args=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 -o ServerAliveCountMax=6)
  if [[ -n "$SSH_KEY" ]]; then ssh_args+=(-i "$SSH_KEY"); fi

  if [[ "$TUNNEL_MODE" == "autossh" ]]; then
    autossh -M "$AUTOSSH_MONITOR_PORT" -f -N -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" "${ssh_args[@]}" "${PVE_SSH_USER}@${PVE_HOST}"
  else
    ssh -f -N -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" "${ssh_args[@]}" "${PVE_SSH_USER}@${PVE_HOST}"
  fi

  sleep 1
  ok "Tunnel started"
}

stop_tunnel() {
  load_config
  if [[ "$TUNNEL_MODE" == "direct" ]]; then return; fi
  info "Stopping local SSH/autossh tunnel"
  pkill -f "ssh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  pkill -f "autossh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true
  ok "Tunnel stopped"
}

stop_nbd() {
  load_config
  info "Stopping qemu-nbd export on Proxmox"
  run_remote "pkill -f 'qemu-nbd.*--export-name=${SRC_VM_NAME}.*${PVE_TARGET_DISK}' >/dev/null 2>&1 || true"
  ok "NBD stopped"
}

blockcopy() {
  load_config
  local dest_uri
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    dest_uri="nbd:${PVE_HOST}:${NBD_PORT}:exportname=${SRC_VM_NAME}"
  else
    dest_uri="nbd:localhost:${NBD_PORT}:exportname=${SRC_VM_NAME}"
  fi

  info "Starting virsh blockcopy"
  info "Destination URI: ${dest_uri}"

  virsh blockcopy "$SRC_VM_NAME" \
    --path "$SRC_DISK" \
    --dest "$dest_uri" \
    --verbose \
    --wait

  ok "blockcopy completed"
}

suspend_and_pivot() {
  load_config
  info "Checking VM state"
  local state
  state="$(virsh domstate "$SRC_VM_NAME")"
  info "Current state: $state"

  if [[ "$state" != "running" ]]; then
    warn "VM is not running. Starting it so QEMU blockjob context is valid."
    virsh start "$SRC_VM_NAME"
    sleep 3
  fi

  info "Suspending source VM"
  virsh suspend "$SRC_VM_NAME"

  info "Pivoting source VM disk to the copied destination"
  virsh blockjob "$SRC_VM_NAME" --pivot

  ok "Pivot completed. Source VM is suspended."
}

create_pve_vm() {
  load_config
  if [[ "$CREATE_PVE_VM" != "yes" ]]; then
    warn "CREATE_PVE_VM=no, skipping Proxmox VM creation"
    return
  fi

  info "Creating Proxmox VM ${PVE_VMID}"

  if run_remote "qm status '$PVE_VMID' >/dev/null 2>&1"; then
    die "Refusing to overwrite existing Proxmox VMID: $PVE_VMID"
  fi

  local net_arg="${PVE_NET_MODEL},bridge=${PVE_BRIDGE}"
  if [[ -n "$PVE_MAC" ]]; then
    net_arg="${net_arg},macaddr=${PVE_MAC}"
  fi

  run_remote "qm create '$PVE_VMID' --name '$PVE_VM_NAME' --memory '$PVE_RAM_MB' --cores '$PVE_CORES' --ostype '$PVE_OS_TYPE' --net0 '$net_arg'"

  case "$PVE_ATTACH_MODE" in
    direct)
      run_remote "qm set '$PVE_VMID' --scsihw '$PVE_SCSI_HW' --scsi0 '$PVE_DISK_REF'"
      ;;
    volume)
      run_remote "qm set '$PVE_VMID' --scsihw '$PVE_SCSI_HW' --scsi0 '$PVE_DISK_REF'"
      ;;
    args)
      run_remote "qm set '$PVE_VMID' --scsihw '$PVE_SCSI_HW' --args '-drive file=${PVE_DISK_REF},if=none,id=drive-scsi0,format=raw -device scsi-hd,drive=drive-scsi0'"
      ;;
    *)
      die "Unknown PVE_ATTACH_MODE: $PVE_ATTACH_MODE"
      ;;
  esac

  if [[ "$PVE_ATTACH_MODE" != "args" ]]; then
    run_remote "qm set '$PVE_VMID' --boot order='$PVE_BOOT_DISK'"
  else
    warn "Attach mode args selected. Boot order may need manual adjustment in Proxmox."
  fi

  if [[ "$START_PVE_VM" == "yes" ]]; then
    info "Starting Proxmox VM ${PVE_VMID}"
    run_remote "qm start '$PVE_VMID'"
  else
    warn "START_PVE_VM=no, VM created but not started"
  fi

  ok "Proxmox VM creation step done"
}

migrate() {
  load_config
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/${SRC_VM_NAME}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1

  confirm_config
  echo
  read -r -p "Type '${SRC_VM_NAME}' to start migration: " confirm
  [[ "$confirm" == "$SRC_VM_NAME" ]] || die "Confirmation mismatch. Aborted."

  install_deps
  preflight
  prepare_nbd
  start_tunnel

  set +e
  blockcopy
  local bc_status=$?
  set -e

  if [[ $bc_status -ne 0 ]]; then
    warn "blockcopy failed. Cleaning tunnel/NBD."
    [[ "$AUTO_CLEANUP_TUNNEL" == "yes" ]] && stop_tunnel || true
    [[ "$AUTO_STOP_NBD" == "yes" ]] && stop_nbd || true
    die "blockcopy failed"
  fi

  suspend_and_pivot

  [[ "$AUTO_CLEANUP_TUNNEL" == "yes" ]] && stop_tunnel || true
  [[ "$AUTO_STOP_NBD" == "yes" ]] && stop_nbd || true

  create_pve_vm

  cat <<EOF

Migration finished.

Important:
  - Source VM '${SRC_VM_NAME}' is still suspended.
  - Verify the VM on Proxmox carefully.
  - Only then run:
      ./kvm2pve.sh cleanup-source ${CONFIG_FILE}

Log file:
  ${LOG_FILE}

EOF
}

cleanup_source() {
  load_config
  confirm_config
  echo
  warn "This removes the libvirt definition and source disk."
  warn "Only do this after the Proxmox VM is verified."
  read -r -p "Type 'DELETE ${SRC_VM_NAME}' to continue: " confirm
  [[ "$confirm" == "DELETE ${SRC_VM_NAME}" ]] || die "Cleanup confirmation mismatch. Aborted."

  virsh destroy "$SRC_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$SRC_VM_NAME" || true

  if [[ -b "$SRC_DISK" || -f "$SRC_DISK" ]]; then
    warn "Removing source disk: $SRC_DISK"
    if [[ -b "$SRC_DISK" ]]; then
      lvremove -y "$SRC_DISK"
    else
      rm -i "$SRC_DISK"
    fi
  fi

  ok "Source cleanup completed"
}

show_config() {
  load_config
  confirm_config
}

cmd="${1:-}"
if [[ -n "${2:-}" ]]; then
  CONFIG_FILE="$2"
fi

case "$cmd" in
  init) init_config "${2:-$CONFIG_FILE}" ;;
  preflight) preflight ;;
  migrate) migrate ;;
  cleanup-source) cleanup_source ;;
  show) show_config ;;
  ""|-h|--help|help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
