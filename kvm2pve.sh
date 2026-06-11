#!/usr/bin/env bash
# kvm2pve - KVM/libvirt to Proxmox disk migration helper
# WARNING: test on a non-production VM first.
set -Eeuo pipefail

VERSION="0.1.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/config.txt}"
LOG_DIR="${SCRIPT_DIR}/logs"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info(){ echo "${BLUE}>>${NC} $*"; }
ok(){ echo "${GREEN}OK${NC} $*"; }
warn(){ echo "${YELLOW}WARN${NC} $*"; }
die(){ echo "${RED}ERROR${NC} $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage(){ cat <<EOF
kvm2pve v${VERSION}
Usage:
  ./kvm2pve.sh init [config-file]
  ./kvm2pve.sh show [config-file]
  ./kvm2pve.sh preflight [config-file]
  ./kvm2pve.sh migrate [config-file]
  ./kvm2pve.sh cleanup-source [config-file]
EOF
}

ask(){ local v="$1" p="$2" d="${3:-}" x; read -r -p "$p${d:+ [$d]}: " x; printf -v "$v" '%s' "${x:-$d}"; }
askyn(){ local v="$1" p="$2" d="${3:-no}" x; while true; do read -r -p "$p [$d]: " x; x="${x:-$d}"; case "$x" in y|Y|yes) printf -v "$v" yes; return;; n|N|no) printf -v "$v" no; return;; *) echo "yes/no";; esac; done; }

load_config(){
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE. Run ./kvm2pve.sh init"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${SRC_VM_NAME:?}"; : "${SRC_DISK:?}"; : "${PVE_HOST:?}"; : "${PVE_SSH_USER:?}"; : "${PVE_TARGET_DISK:?}"; : "${PVE_VMID:?}"; : "${PVE_VM_NAME:?}"; : "${PVE_RAM_MB:?}"; : "${PVE_CORES:?}"
  SSH_PORT="${SSH_PORT:-22}"; SSH_KEY="${SSH_KEY:-}"; SSH_OPTS="${SSH_OPTS:-}"
  NBD_PORT="${NBD_PORT:-10809}"; TUNNEL_MODE="${TUNNEL_MODE:-autossh}"; AUTOSSH_MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20000}"
  PVE_ATTACH_MODE="${PVE_ATTACH_MODE:-direct}"; PVE_DISK_REF="${PVE_DISK_REF:-$PVE_TARGET_DISK}"
  PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"; PVE_NET_MODEL="${PVE_NET_MODEL:-virtio}"; PVE_MAC="${PVE_MAC:-}"; PVE_OS_TYPE="${PVE_OS_TYPE:-l26}"; PVE_SCSI_HW="${PVE_SCSI_HW:-virtio-scsi-pci}"; PVE_BOOT_DISK="${PVE_BOOT_DISK:-scsi0}"
  CREATE_PVE_VM="${CREATE_PVE_VM:-yes}"; START_PVE_VM="${START_PVE_VM:-yes}"; INSTALL_PACKAGES="${INSTALL_PACKAGES:-yes}"; AUTO_CLEANUP_TUNNEL="${AUTO_CLEANUP_TUNNEL:-yes}"; AUTO_STOP_NBD="${AUTO_STOP_NBD:-yes}"
  BLOCKCOPY_REUSE_EXTERNAL="${BLOCKCOPY_REUSE_EXTERNAL:-yes}"; BLOCKCOPY_BLOCKDEV="${BLOCKCOPY_BLOCKDEV:-yes}"; BLOCKCOPY_FORMAT="${BLOCKCOPY_FORMAT:-raw}"; BLOCKCOPY_BANDWIDTH="${BLOCKCOPY_BANDWIDTH:-}"
}

ssh_cmd(){ SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 -o ServerAliveCountMax=6); [[ -n "$SSH_KEY" ]] && SSH_CMD+=(-i "$SSH_KEY"); if [[ -n "$SSH_OPTS" ]]; then # shellcheck disable=SC2206
local e=( $SSH_OPTS ); SSH_CMD+=("${e[@]}"); fi; SSH_CMD+=("${PVE_SSH_USER}@${PVE_HOST}"); }
remote(){ ssh_cmd; "${SSH_CMD[@]}" "$@"; }

summary(){ cat <<EOF

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
Blockcopy          : reuse_external=${BLOCKCOPY_REUSE_EXTERNAL}, blockdev=${BLOCKCOPY_BLOCKDEV}, format=${BLOCKCOPY_FORMAT}, bandwidth=${BLOCKCOPY_BANDWIDTH:-unlimited}
EOF
}

init_config(){
  local target="${1:-$CONFIG_FILE}" src_vm src_disk pve_host pve_user ssh_port pve_disk pve_vmid pve_name ram cores nbd tunnel mon attach disk_ref bridge net mac create_vm start_vm
  mkdir -p "$(dirname "$target")"
  ask src_vm "Source VM name in virsh" "kvm3023"; ask src_disk "Source disk path" "/dev/centos/kvm3023_img"
  ask pve_host "Proxmox host/IP" "1.2.168.2"; ask pve_user "Proxmox SSH user" "root"; ask ssh_port "Proxmox SSH port" "22"
  ask pve_disk "Target disk/LV path on Proxmox" "/dev/volgroup/test-kvm3023"; ask pve_vmid "Proxmox VMID" "3023"; ask pve_name "Proxmox VM name" "$src_vm"; ask ram "RAM MB" "4096"; ask cores "vCPU cores" "2"
  ask nbd "NBD local port" "10809"; ask tunnel "Tunnel mode (autossh|ssh|direct)" "autossh"; ask mon "autossh monitor port" "20000"
  ask attach "Attach mode (direct|volume|args)" "direct"; ask disk_ref "Disk reference for attach" "$pve_disk"; ask bridge "Proxmox bridge" "vmbr0"; ask net "Network model" "virtio"; ask mac "MAC address (empty=auto)" ""
  askyn create_vm "Create Proxmox VM automatically?" "yes"; askyn start_vm "Start Proxmox VM automatically?" "yes"
  cat > "$target" <<EOF
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
PVE_NET_MODEL=${net}
PVE_MAC=${mac}
PVE_OS_TYPE=l26
PVE_SCSI_HW=virtio-scsi-pci
PVE_BOOT_DISK=scsi0
PVE_ATTACH_MODE=${attach}
PVE_DISK_REF=${disk_ref}
CREATE_PVE_VM=${create_vm}
START_PVE_VM=${start_vm}
TUNNEL_MODE=${tunnel}
NBD_PORT=${nbd}
AUTOSSH_MONITOR_PORT=${mon}
BLOCKCOPY_REUSE_EXTERNAL=yes
BLOCKCOPY_BLOCKDEV=yes
BLOCKCOPY_FORMAT=raw
BLOCKCOPY_BANDWIDTH=
INSTALL_PACKAGES=yes
AUTO_CLEANUP_TUNNEL=yes
AUTO_STOP_NBD=yes
EOF
  chmod 600 "$target"; ok "Config written: $target"
}

size_local(){ blockdev --getsize64 "$SRC_DISK" 2>/dev/null || stat -c %s "$SRC_DISK"; }
size_remote(){ remote "blockdev --getsize64 '$PVE_TARGET_DISK' 2>/dev/null || stat -c %s '$PVE_TARGET_DISK'"; }

preflight(){
  load_config; summary; need virsh; need ssh; [[ "$TUNNEL_MODE" == autossh ]] && need autossh
  virsh list --all | awk '{print $2}' | grep -qx "$SRC_VM_NAME" || die "Source VM not found: $SRC_VM_NAME"
  [[ -b "$SRC_DISK" || -f "$SRC_DISK" ]] || die "Source disk missing: $SRC_DISK"
  virsh domblklist "$SRC_VM_NAME" | grep -qF "$SRC_DISK" || warn "SRC_DISK was not found in domblklist; verify manually"
  remote "echo connected" >/dev/null; remote "command -v qm >/dev/null" || die "qm not found on Proxmox"
  remote "test -b '$PVE_TARGET_DISK' -o -f '$PVE_TARGET_DISK'" || die "Target disk missing: $PVE_TARGET_DISK"
  local s d; s="$(size_local)"; d="$(size_remote)"; ok "Source size: $s"; ok "Target size: $d"; [[ "$s" == "$d" ]] || die "Source and target sizes differ"
  if [[ "$CREATE_PVE_VM" == yes ]] && remote "qm status '$PVE_VMID' >/dev/null 2>&1"; then die "Proxmox VMID already exists: $PVE_VMID"; fi
  remote "ss -ltn | grep -q '127.0.0.1:${NBD_PORT}'" && die "NBD port already in use on Proxmox" || true
  ok "Preflight completed"
}

install_deps(){
  load_config; [[ "$INSTALL_PACKAGES" == yes ]] || return
  if [[ "$TUNNEL_MODE" == autossh ]] && ! command -v autossh >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y autossh; elif command -v yum >/dev/null 2>&1; then yum install -y epel-release || true; yum install -y autossh; elif command -v dnf >/dev/null 2>&1; then dnf install -y autossh; else die "Install autossh manually"; fi
  fi
  remote "if ! command -v qemu-nbd >/dev/null 2>&1; then apt-get update -y && apt-get install -y qemu-utils; fi; modprobe nbd max_part=16 || true"
}

prepare_nbd(){ load_config; info "Starting qemu-nbd on Proxmox 127.0.0.1:${NBD_PORT}"; remote "pkill -f 'qemu-nbd.*--export-name=${SRC_VM_NAME}.*${PVE_TARGET_DISK}' >/dev/null 2>&1 || true; nohup qemu-nbd --listen=127.0.0.1:${NBD_PORT} --export-name=${SRC_VM_NAME} '${PVE_TARGET_DISK}' >/tmp/kvm2pve-qemu-nbd-${SRC_VM_NAME}.log 2>&1 &"; sleep 1; remote "ss -ltn | grep -q '127.0.0.1:${NBD_PORT}'" || die "qemu-nbd did not start"; }
start_tunnel(){ load_config; [[ "$TUNNEL_MODE" == direct ]] && { warn "Direct NBD mode"; return; }; pkill -f "ssh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true; pkill -f "autossh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true; local a=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 -o ServerAliveCountMax=6); [[ -n "$SSH_KEY" ]] && a+=(-i "$SSH_KEY"); if [[ "$TUNNEL_MODE" == autossh ]]; then autossh -M "$AUTOSSH_MONITOR_PORT" -f -N -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" "${a[@]}" "${PVE_SSH_USER}@${PVE_HOST}"; else ssh -f -N -L "${NBD_PORT}:127.0.0.1:${NBD_PORT}" "${a[@]}" "${PVE_SSH_USER}@${PVE_HOST}"; fi; ok "Tunnel started"; }
stop_tunnel(){ load_config; [[ "$TUNNEL_MODE" == direct ]] && return; pkill -f "ssh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true; pkill -f "autossh .*${NBD_PORT}:127.0.0.1:${NBD_PORT}.*${PVE_HOST}" >/dev/null 2>&1 || true; }
stop_nbd(){ load_config; remote "pkill -f 'qemu-nbd.*--export-name=${SRC_VM_NAME}.*${PVE_TARGET_DISK}' >/dev/null 2>&1 || true"; }

blockcopy(){
  load_config; local dest args; [[ "$TUNNEL_MODE" == direct ]] && dest="nbd:${PVE_HOST}:${NBD_PORT}:exportname=${SRC_VM_NAME}" || dest="nbd:localhost:${NBD_PORT}:exportname=${SRC_VM_NAME}"
  args=(blockcopy "$SRC_VM_NAME" --path "$SRC_DISK" --dest "$dest" --wait --verbose)
  [[ "$BLOCKCOPY_REUSE_EXTERNAL" == yes ]] && args+=(--reuse-external)
  [[ "$BLOCKCOPY_BLOCKDEV" == yes ]] && args+=(--blockdev)
  [[ -n "$BLOCKCOPY_FORMAT" ]] && args+=(--format "$BLOCKCOPY_FORMAT")
  [[ -n "$BLOCKCOPY_BANDWIDTH" ]] && args+=(--bandwidth "$BLOCKCOPY_BANDWIDTH")
  info "Running: virsh ${args[*]}"
  virsh "${args[@]}"
}

suspend_pivot(){ load_config; local st; st="$(virsh domstate "$SRC_VM_NAME")"; [[ "$st" != running ]] && { warn "VM not running; starting it"; virsh start "$SRC_VM_NAME"; sleep 3; }; virsh suspend "$SRC_VM_NAME"; virsh blockjob "$SRC_VM_NAME" "$SRC_DISK" --pivot; ok "Pivot complete; source VM is suspended"; }
create_pve(){ load_config; [[ "$CREATE_PVE_VM" == yes ]] || return; local net="${PVE_NET_MODEL},bridge=${PVE_BRIDGE}"; [[ -n "$PVE_MAC" ]] && net="${net},macaddr=${PVE_MAC}"; remote "qm create '$PVE_VMID' --name '$PVE_VM_NAME' --memory '$PVE_RAM_MB' --cores '$PVE_CORES' --ostype '$PVE_OS_TYPE' --net0 '$net'"; case "$PVE_ATTACH_MODE" in direct|volume) remote "qm set '$PVE_VMID' --scsihw '$PVE_SCSI_HW' --scsi0 '$PVE_DISK_REF'"; remote "qm set '$PVE_VMID' --boot order='$PVE_BOOT_DISK'";; args) remote "qm set '$PVE_VMID' --scsihw '$PVE_SCSI_HW' --args '-drive file=${PVE_DISK_REF},if=none,id=drive-scsi0,format=raw -device scsi-hd,drive=drive-scsi0'";; *) die "Unknown PVE_ATTACH_MODE";; esac; [[ "$START_PVE_VM" == yes ]] && remote "qm start '$PVE_VMID'"; }

migrate(){ load_config; mkdir -p "$LOG_DIR"; exec > >(tee -a "${LOG_DIR}/${SRC_VM_NAME}-$(date +%Y%m%d-%H%M%S).log") 2>&1; summary; read -r -p "Type '${SRC_VM_NAME}' to start migration: " c; [[ "$c" == "$SRC_VM_NAME" ]] || die "Aborted"; install_deps; preflight; prepare_nbd; start_tunnel; if ! blockcopy; then [[ "$AUTO_CLEANUP_TUNNEL" == yes ]] && stop_tunnel || true; [[ "$AUTO_STOP_NBD" == yes ]] && stop_nbd || true; die "blockcopy failed"; fi; suspend_pivot; [[ "$AUTO_CLEANUP_TUNNEL" == yes ]] && stop_tunnel || true; [[ "$AUTO_STOP_NBD" == yes ]] && stop_nbd || true; create_pve; ok "Migration flow finished. Verify Proxmox VM before cleanup-source."; }
cleanup_source(){ load_config; summary; warn "This destroys/undefines source VM and removes source disk."; read -r -p "Type 'DELETE ${SRC_VM_NAME}' to continue: " c; [[ "$c" == "DELETE ${SRC_VM_NAME}" ]] || die "Aborted"; virsh destroy "$SRC_VM_NAME" >/dev/null 2>&1 || true; virsh undefine "$SRC_VM_NAME" || true; [[ -b "$SRC_DISK" ]] && lvremove -y "$SRC_DISK" || rm -i "$SRC_DISK"; }
show(){ load_config; summary; }

cmd="${1:-help}"; [[ -n "${2:-}" ]] && CONFIG_FILE="$2"
case "$cmd" in init) init_config "${2:-$CONFIG_FILE}";; show) show;; preflight) preflight;; migrate) migrate;; cleanup-source) cleanup_source;; help|-h|--help|*) usage;; esac
