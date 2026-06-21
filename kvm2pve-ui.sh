#!/usr/bin/env bash
# Optional whiptail terminal UI for kvm2pve.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="${SCRIPT_DIR}/kvm2pve-src.sh"
DST_SCRIPT="${SCRIPT_DIR}/kvm2pve-dst.sh"
VERSION="0.4.0"

LAST_OUTPUT=""

missing_whiptail(){
  cat <<'EOF'
whiptail is required for kvm2pve-ui.sh.

CentOS/RHEL:
  yum install -y newt

Debian/Ubuntu:
  apt install -y whiptail

Packages are not installed automatically.
EOF
}

command -v whiptail >/dev/null 2>&1 || { missing_whiptail; exit 1; }

require_scripts(){
  local missing=0
  if [[ ! -r "$SRC_SCRIPT" ]]; then
    whiptail --title "Missing script" --msgbox "Source script is missing or not readable:\n$SRC_SCRIPT" 10 76 || true
    missing=1
  fi
  if [[ ! -r "$DST_SCRIPT" ]]; then
    whiptail --title "Missing script" --msgbox "Destination script is missing or not readable:\n$DST_SCRIPT" 10 76 || true
    missing=1
  fi
  (( missing == 0 )) || exit 1
}

ask_input(){
  local title="$1" prompt="$2" default="${3:-}" value
  value="$(whiptail --title "$title" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3)" || return 1
  printf '%s' "$value"
}

ask_yesno(){
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 78
}

show_textbox_file(){
  local title="$1" file="$2" lines chars
  lines="$(wc -l < "$file" | awk '{print $1}')"
  chars="$(wc -c < "$file" | awk '{print $1}')"

  if (( lines > 36 || chars > 7000 )); then
    clear || true
    printf '%s\n' "$title"
    printf '%*s\n' "${#title}" '' | tr ' ' '-'
    cat "$file"
    printf '\nPress Enter to continue...'
    read -r _
  else
    whiptail --title "$title" --textbox "$file" 24 100 || true
  fi
}

show_output(){
  local title="$1" file="$2"
  show_textbox_file "$title" "$file"
}

show_error(){
  local title="$1" status="$2"
  whiptail --title "Command failed" --msgbox "${title}\n\nExit code: ${status}\n\nThe workflow stopped. Review the command output before continuing." 12 78 || true
}

capture_output(){
  local tmp="$1"
  LAST_OUTPUT="$(cat "$tmp")"
}

run_command(){
  local title="$1"; shift
  local tmp status
  tmp="$(mktemp)"
  status=0
  (
    cd "$SCRIPT_DIR"
    bash "$@"
  ) >"$tmp" 2>&1 || status=$?
  capture_output "$tmp"
  if (( status != 0 )); then
    show_error "$title" "$status"
    show_output "$title output" "$tmp"
    rm -f "$tmp"
    return "$status"
  fi
  show_output "$title output" "$tmp"
  rm -f "$tmp"
  return 0
}

run_command_with_input(){
  local title="$1" input="$2"; shift 2
  local tmp status
  tmp="$(mktemp)"
  status=0
  (
    cd "$SCRIPT_DIR"
    printf '%b' "$input" | bash "$@"
  ) >"$tmp" 2>&1 || status=$?
  capture_output "$tmp"
  if (( status != 0 )); then
    show_error "$title" "$status"
    show_output "$title output" "$tmp"
    rm -f "$tmp"
    return "$status"
  fi
  show_output "$title output" "$tmp"
  rm -f "$tmp"
  return 0
}

run_command_confirm(){
  local title="$1" prompt="$2"; shift 2
  ask_yesno "$title" "$prompt" || return 1
  run_command "$title" "$@"
}

run_dangerous_confirmed(){
  local title="$1" prompt="$2" input="$3"; shift 3
  ask_yesno "$title" "$prompt" || return 1
  if [[ -n "$input" ]]; then
    run_command_with_input "$title" "$input" "$@"
  else
    run_command "$title" "$@"
  fi
}

run_long_command(){
  local title="$1"; shift
  local status
  clear || true
  printf '%s\n' "$title"
  printf '%*s\n' "${#title}" '' | tr ' ' '-'
  printf 'Running:'
  printf ' %q' "$@"
  printf '\n\n'
  (
    cd "$SCRIPT_DIR"
    bash "$@"
  )
  status=$?
  printf '\nCommand exited with status %s.\n' "$status"
  printf 'Press Enter to continue...'
  read -r _
  if (( status != 0 )); then
    whiptail --title "Command failed" --msgbox "${title}\n\nExit code: ${status}\n\nThe workflow stopped." 10 78 || true
    return "$status"
  fi
  return 0
}

current_conf_value(){
  local key="$1" default="${2:-}" file="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"
  [[ -f "$file" ]] || { printf '%s' "$default"; return 0; }
  awk -F= -v k="$key" -v d="$default" '$1==k {print substr($0, index($0,"=")+1); found=1; exit} END{if(!found) print d}' "$file"
}

main_menu(){
  local choice
  while true; do
    choice="$(whiptail --title "kvm2pve Terminal UI v${VERSION}" --menu "Choose an action." 18 78 8 \
      "start" "Start New Migration" \
      "continue" "Continue Migration" \
      "status" "Migration Status" \
      "advanced" "Advanced Tools" \
      "exit" "Exit" \
      3>&1 1>&2 2>&3)" || exit 0
    case "$choice" in
      start) start_new_migration || true ;;
      continue) continue_migration || true ;;
      status) migration_status || true ;;
      advanced) advanced_tools || true ;;
      exit) exit 0 ;;
    esac
  done
}

start_new_migration(){
  local choice
  choice="$(whiptail --title "Start New Migration" --menu "Choose how to bootstrap this migration." 16 78 5 \
    "source-remote" "Source host - prepare destination over SSH" \
    "destination" "Destination host - manual token flow" \
    "source" "Source host - paste handoff token" \
    "back" "Back" \
    3>&1 1>&2 2>&3)" || return 0
  case "$choice" in
    source-remote) start_source_remote_flow || true ;;
    destination) start_destination_flow || true ;;
    source) start_source_flow || true ;;
  esac
}

start_destination_flow(){
  local vmid token tmp
  vmid="$(ask_input "Destination host" "Destination VMID:" "$(current_conf_value PVE_VMID "")")" || return 0
  [[ -n "$vmid" ]] || return 0

  run_command_with_input "Destination quick" "yes\n" "$DST_SCRIPT" quick "$vmid" || return 1

  token="$(printf '%s\n' "$LAST_OUTPUT" | grep -m1 '^KVM2PVE_HANDOFF_V1:' || true)"
  if [[ -n "$token" ]]; then
    tmp="$(mktemp)"
    {
      printf 'Handoff token\n'
      printf '-------------\n'
      printf '%s\n\n' "$token"
      printf 'Copy this token to the source host.\n\n'
      printf 'Full command output\n'
      printf '-------------------\n'
      printf '%s\n' "$LAST_OUTPUT"
    } > "$tmp"
    show_textbox_file "Handoff token" "$tmp"
    rm -f "$tmp"
  fi

  if run_command_confirm "Export NBD" "Export NBD now?\n\nThis exposes the destination disk for writing." "$DST_SCRIPT" export; then
    whiptail --title "Next step" --msgbox "Destination is ready.\n\nGo to the source host, run kvm2pve-ui.sh, choose Start New Migration > Source host, and paste the handoff token." 12 78 || true
  fi
}

start_source_remote_flow(){
  local vm pve_host pve_vmid ssh_port ssh_user default_vm

  default_vm="$(current_conf_value VM_NAME "kvm3023")"
  vm="$(ask_input "Remote prepare" "Source VM name:" "$default_vm")" || return 0
  [[ -n "$vm" ]] || return 0
  pve_host="$(ask_input "Remote prepare" "Destination Proxmox host/IP reachable from source:" "$(current_conf_value PVE_HOST "CHANGE_ME")")" || return 0
  [[ -n "$pve_host" && "$pve_host" != "CHANGE_ME" ]] || return 0
  pve_vmid="$(ask_input "Remote prepare" "Destination Proxmox VMID:" "$(current_conf_value PVE_VMID "")")" || return 0
  [[ -n "$pve_vmid" ]] || return 0
  ssh_port="$(ask_input "Remote prepare" "Destination Proxmox SSH port:" "$(current_conf_value PVE_SSH_PORT "22")")" || return 0
  [[ -n "$ssh_port" ]] || ssh_port="22"
  ssh_user="$(ask_input "Remote prepare" "Destination Proxmox SSH user:" "$(current_conf_value PVE_SSH_USER "root")")" || return 0
  [[ -n "$ssh_user" ]] || ssh_user="root"

  run_command_with_input "Remote prepare" "yes\n" "$SRC_SCRIPT" remote-prepare "$vm" "$pve_host" "$pve_vmid" "$ssh_port" "$ssh_user" || return 1

  if run_dangerous_confirmed "Remote export" "Start destination NBD export over SSH now?\n\nThis runs destination preflight first, then starts qemu-nbd." "" "$SRC_SCRIPT" remote-export; then
    if ask_yesno "Safe preparation" "Run source tunnel/target/bitmap preparation now?"; then
      run_source_prepare_steps || return 1
    fi
  fi

  whiptail --title "Remote prepare complete" --msgbox "Remote destination preparation is complete.\n\nUse Continue Migration on the source host for full sync, final incremental, and source stop." 12 78 || true
}

start_source_flow(){
  local token vm default_vm pve_host ssh_port input
  token="$(ask_input "Source host" "Paste handoff token:" "")" || return 0
  [[ -n "$token" ]] || return 0

  default_vm="$(current_conf_value VM_NAME "kvm3023")"
  vm="$(ask_input "Source host" "Source VM name:" "$default_vm")" || return 0
  pve_host="$(ask_input "Source host" "Destination Proxmox host/IP reachable from source:" "$(current_conf_value PVE_HOST "CHANGE_ME")")" || return 0
  ssh_port="$(ask_input "Source host" "Destination Proxmox SSH port:" "$(current_conf_value PVE_SSH_PORT "22")")" || return 0
  [[ -n "$ssh_port" ]] || ssh_port="22"

  input="${vm}\n${pve_host}\n${ssh_port}\nyes\nno\n"
  run_command_with_input "Source quick" "$input" "$SRC_SCRIPT" quick "$token" || return 1

  if ask_yesno "Safe preparation" "Run safe preparation steps now?"; then
    run_source_prepare_steps || return 1
  fi

  if run_dangerous_confirmed "Full sync" "Start full sync now?\n\nThe source VM may keep running, but this writes to the destination disk." "" "$SRC_SCRIPT" full; then
    if ask_yesno "Wait for full sync" "Watch and wait for full sync to complete now?"; then
      run_long_command "Waiting for full sync" "$SRC_SCRIPT" wait-full || return 1
      run_command "Source report" "$SRC_SCRIPT" report || return 1
    fi
  else
    return 0
  fi

  if run_command_confirm "Cutover check" "Run cutover-check now?" "$SRC_SCRIPT" cutover-check; then
    if run_dangerous_confirmed "Final incremental" "Run final incremental now?\n\nThis will suspend the source VM." "yes\n" "$SRC_SCRIPT" final; then
      run_command "Source report" "$SRC_SCRIPT" report || return 1
      if run_dangerous_confirmed "Stop source VM" "Stop source VM now?\n\nUse only after final incremental completed." "yes\n" "$SRC_SCRIPT" stop-source; then
        whiptail --title "Source complete" --msgbox "Source side is complete.\n\nGo to destination host, choose Continue Migration, then close NBD and boot destination VM." 12 78 || true
      fi
    fi
  fi
}

run_source_prepare_steps(){
  local cmd
  for cmd in tunnel tunnel-check attach-target check-target bitmap check-bitmap; do
    if ! run_command "Source: ${cmd}" "$SRC_SCRIPT" "$cmd"; then
      if ask_yesno "Preparation failed" "Open Advanced Tools now?"; then
        advanced_tools
      fi
      return 1
    fi
  done
}

continue_migration(){
  local choice
  choice="$(whiptail --title "Continue Migration" --menu "Choose the host you are operating on." 14 78 4 \
    "source" "Source host" \
    "destination" "Destination host" \
    "back" "Back" \
    3>&1 1>&2 2>&3)" || return 0
  case "$choice" in
    source) continue_source || true ;;
    destination) continue_destination || true ;;
  esac
}

continue_source(){
  local full final stopped choice
  run_command "Source report" "$SRC_SCRIPT" report || return 1
  full="$(printf '%s\n' "$LAST_OUTPUT" | awk -F: '/FULL_COMPLETED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  final="$(printf '%s\n' "$LAST_OUTPUT" | awk -F: '/FINAL_COMPLETED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  stopped="$(printf '%s\n' "$LAST_OUTPUT" | awk -F: '/SOURCE_STOPPED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"

  if [[ "$full" != "1" ]]; then
    choice="$(whiptail --title "Source next step" --menu "Full sync is not completed. Recommended next step: run full sync, then wait-full." 16 78 5 \
      "full" "Start full sync" \
      "wait-full" "Watch wait-full" \
      "report" "Show report" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      full) run_dangerous_confirmed "Full sync" "Start full sync now?\n\nThis writes to the destination disk." "" "$SRC_SCRIPT" full || true ;;
      wait-full) run_long_command "Waiting for full sync" "$SRC_SCRIPT" wait-full || true ;;
      report) run_command "Source report" "$SRC_SCRIPT" report || true ;;
    esac
  elif [[ "$final" != "1" ]]; then
    choice="$(whiptail --title "Source next step" --menu "Full sync is completed. Recommended next step: cutover-check, then final incremental." 16 78 5 \
      "cutover-final" "Run cutover-check then final" \
      "cutover" "Run cutover-check only" \
      "report" "Show report" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      cutover-final)
        run_command "Cutover check" "$SRC_SCRIPT" cutover-check || return 1
        run_dangerous_confirmed "Final incremental" "Run final incremental now?\n\nThis will suspend the source VM." "yes\n" "$SRC_SCRIPT" final || true
        ;;
      cutover) run_command "Cutover check" "$SRC_SCRIPT" cutover-check || true ;;
      report) run_command "Source report" "$SRC_SCRIPT" report || true ;;
    esac
  elif [[ "$stopped" != "1" ]]; then
    choice="$(whiptail --title "Source next step" --menu "Final incremental is completed. Recommended next step: stop the source VM." 15 78 4 \
      "stop" "Stop source VM" \
      "report" "Show report" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      stop) run_dangerous_confirmed "Stop source VM" "Stop source VM now?\n\nUse only after final incremental completed." "yes\n" "$SRC_SCRIPT" stop-source || true ;;
      report) run_command "Source report" "$SRC_SCRIPT" report || true ;;
    esac
  else
    whiptail --title "Source complete" --msgbox "Source side is complete.\n\nReturn to the destination host to close NBD and boot the destination VM." 10 78 || true
  fi
}

continue_destination(){
  local choice
  while true; do
    choice="$(whiptail --title "Destination Continue" --menu "Choose a destination action." 16 78 5 \
      "close" "Close NBD" \
      "boot" "Boot destination VM" \
      "status" "Status" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      close) run_dangerous_confirmed "Close NBD" "Close destination NBD export now?" "" "$DST_SCRIPT" close || true ;;
      boot) run_dangerous_confirmed "Boot destination VM" "Boot destination VM now?" "" "$DST_SCRIPT" boot || true ;;
      status) run_command "Destination status" "$DST_SCRIPT" status || true ;;
      back) return 0 ;;
    esac
  done
}

migration_status(){
  local choice tmp status
  choice="$(whiptail --title "Migration Status" --menu "Choose status view." 14 78 4 \
    "source" "Source status" \
    "destination" "Destination status" \
    "back" "Back" \
    3>&1 1>&2 2>&3)" || return 0
  case "$choice" in
    source)
      tmp="$(mktemp)"
      status=0
      (
        cd "$SCRIPT_DIR"
        printf '== Source report ==\n'
        bash "$SRC_SCRIPT" report
        printf '\n== Source status ==\n'
        bash "$SRC_SCRIPT" status
      ) >"$tmp" 2>&1 || status=$?
      capture_output "$tmp"
      (( status == 0 )) || show_error "Source status" "$status"
      show_output "Source status" "$tmp"
      rm -f "$tmp"
      ;;
    destination) run_command "Destination status" "$DST_SCRIPT" status || true ;;
  esac
}

advanced_tools(){
  local choice
  while true; do
    choice="$(whiptail --title "Advanced Tools" --menu "Individual commands are exposed here for operators who need them." 16 78 5 \
      "source" "Source Tools" \
      "destination" "Destination Tools" \
      "recovery" "Recovery" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      source) advanced_source_tools || true ;;
      destination) advanced_destination_tools || true ;;
      recovery) recovery_guidance || true ;;
      back) return 0 ;;
    esac
  done
}

advanced_source_tools(){
  local cmd
  while true; do
    cmd="$(whiptail --title "Source Tools" --menu "Run a source-side command." 28 82 20 \
      "remote-prepare" "Prepare destination over SSH" \
      "remote-export" "Run destination preflight/export/status over SSH" \
      "remote-dst-status" "Show remote destination status" \
      "remote-dst-close" "Close remote destination NBD" \
      "show" "Show config" \
      "next" "Suggested next steps" \
      "preflight" "Run preflight" \
      "tunnel" "Start tunnel" \
      "tunnel-status" "Show tunnel status" \
      "tunnel-check" "Check tunnel" \
      "attach-target" "Attach target" \
      "check-target" "Check target" \
      "bitmap" "Create bitmap" \
      "check-bitmap" "Check bitmap" \
      "full" "Start full sync" \
      "wait-full" "Wait for full sync" \
      "mark-full" "Mark full complete" \
      "report" "Show report" \
      "cutover-check" "Run cutover check" \
      "final" "Run final incremental" \
      "stop-source" "Stop source VM" \
      "status" "Show status" \
      "cleanup" "Cleanup" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$cmd" in
      back) return 0 ;;
      wait-full) run_long_command "Waiting for full sync" "$SRC_SCRIPT" wait-full || true ;;
      full) run_dangerous_confirmed "Full sync" "Start full sync now?\n\nThis writes to the destination disk." "" "$SRC_SCRIPT" full || true ;;
      mark-full) run_dangerous_confirmed "Mark full complete" "Mark full sync as completed now?\n\nUse only after confirming the full sync finished successfully." "" "$SRC_SCRIPT" mark-full || true ;;
      final) run_dangerous_confirmed "Final incremental" "Run final incremental now?\n\nThis will suspend the source VM." "yes\n" "$SRC_SCRIPT" final || true ;;
      stop-source) run_dangerous_confirmed "Stop source VM" "Stop source VM now?\n\nUse only after final incremental completed." "yes\n" "$SRC_SCRIPT" stop-source || true ;;
      remote-prepare) advanced_remote_prepare || true ;;
      remote-export) run_dangerous_confirmed "Remote export" "Start destination NBD export over SSH now?\n\nThis runs destination preflight first, then starts qemu-nbd." "" "$SRC_SCRIPT" remote-export || true ;;
      remote-dst-close) run_dangerous_confirmed "Remote destination close" "Close destination NBD export over SSH now?" "" "$SRC_SCRIPT" remote-dst-close || true ;;
      cleanup) run_dangerous_confirmed "Source cleanup" "Run source cleanup now?\n\nThis removes local migration artifacts such as tunnel processes and dirty bitmap when present." "" "$SRC_SCRIPT" cleanup || true ;;
      *) run_command "Source: ${cmd}" "$SRC_SCRIPT" "$cmd" || true ;;
    esac
  done
}

advanced_remote_prepare(){
  local vm pve_host pve_vmid ssh_port ssh_user

  vm="$(ask_input "Remote prepare" "Source VM name:" "$(current_conf_value VM_NAME "kvm3023")")" || return 0
  [[ -n "$vm" ]] || return 0
  pve_host="$(ask_input "Remote prepare" "Destination Proxmox host/IP:" "$(current_conf_value PVE_HOST "CHANGE_ME")")" || return 0
  [[ -n "$pve_host" && "$pve_host" != "CHANGE_ME" ]] || return 0
  pve_vmid="$(ask_input "Remote prepare" "Destination Proxmox VMID:" "$(current_conf_value PVE_VMID "")")" || return 0
  [[ -n "$pve_vmid" ]] || return 0
  ssh_port="$(ask_input "Remote prepare" "Destination Proxmox SSH port:" "$(current_conf_value PVE_SSH_PORT "22")")" || return 0
  [[ -n "$ssh_port" ]] || ssh_port="22"
  ssh_user="$(ask_input "Remote prepare" "Destination Proxmox SSH user:" "$(current_conf_value PVE_SSH_USER "root")")" || return 0
  [[ -n "$ssh_user" ]] || ssh_user="root"

  run_command_with_input "Remote prepare" "yes\n" "$SRC_SCRIPT" remote-prepare "$vm" "$pve_host" "$pve_vmid" "$ssh_port" "$ssh_user" || true
}

advanced_destination_tools(){
  local cmd vmid
  while true; do
    cmd="$(whiptail --title "Destination Tools" --menu "Run a destination-side command." 20 78 10 \
      "show" "Show config" \
      "preflight" "Run preflight" \
      "export" "Export NBD" \
      "close" "Close NBD" \
      "boot" "Boot VM" \
      "status" "Show status" \
      "handoff" "Show handoff token" \
      "quick" "Run quick setup" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$cmd" in
      back) return 0 ;;
      export) run_dangerous_confirmed "Export NBD" "Export NBD now?\n\nThis exposes the destination disk for writing." "" "$DST_SCRIPT" export || true ;;
      close) run_dangerous_confirmed "Close NBD" "Close destination NBD export now?" "" "$DST_SCRIPT" close || true ;;
      boot) run_dangerous_confirmed "Boot destination VM" "Boot destination VM now?" "" "$DST_SCRIPT" boot || true ;;
      quick)
        vmid="$(ask_input "Destination quick" "Destination VMID:" "$(current_conf_value PVE_VMID "")")" || continue
        if [[ -n "$vmid" ]]; then
          run_command_with_input "Destination quick" "yes\n" "$DST_SCRIPT" quick "$vmid" || true
        fi
        ;;
      *) run_command "Destination: ${cmd}" "$DST_SCRIPT" "$cmd" || true ;;
    esac
  done
}

recovery_guidance(){
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
Full sync failed:
  Do NOT run incremental.
  Close/re-create destination export and start full again.
  resume-full is not implemented.

Final incremental failed:
  Do NOT boot destination VM.
  Keep source VM available.
  Investigate and retry final.

Destination boot problem:
  Stop destination VM.
  Start source VM.
  Restore customer access.
  Investigate migration.
EOF
  show_textbox_file "Recovery guidance" "$tmp"
  rm -f "$tmp"
}

require_scripts
main_menu
