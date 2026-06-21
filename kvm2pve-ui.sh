#!/usr/bin/env bash
# Optional whiptail terminal UI for kvm2pve.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="${SCRIPT_DIR}/kvm2pve-src.sh"
DST_SCRIPT="${SCRIPT_DIR}/kvm2pve-dst.sh"
VERSION="0.4.0"

LAST_OUTPUT=""
LAST_ACTION="none"
LAST_STATUS="not started"
PREVIOUS_ACTION="none"
SUGGESTED_ACTION="preflight"

WORKFLOW_ORDER="preflight remote-export tunnel tunnel-check attach-target bitmap full wait-full report cutover-check final stop-source remote-dst-close"

missing_whiptail(){
  cat <<'EOF'
whiptail is required for kvm2pve-ui.sh.

Use the CLI remote workflow directly if whiptail is not available:
  ./kvm2pve-src.sh remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]
  ./kvm2pve-src.sh next

CentOS/RHEL:
  yum install -y newt

Debian/Ubuntu:
  apt install -y whiptail

Packages are not installed automatically.
EOF
}

command -v whiptail >/dev/null 2>&1 || { missing_whiptail; exit 1; }

strip_ansi(){ sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

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

whiptail_supports_form(){
  whiptail --help 2>&1 | grep -q -- '--form'
}

ask_exact(){
  local title="$1" prompt="$2" expected="$3" value
  value="$(whiptail --title "$title" --inputbox "$prompt\n\nType exactly: $expected" 14 82 "" 3>&1 1>&2 2>&3)" || return 1
  [[ "$value" == "$expected" ]]
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

show_file_then_details(){
  local title="$1" summary_file="$2" details_file="$3"
  show_textbox_file "$title" "$summary_file"
  if ask_yesno "Details" "Show full command output?"; then
    show_textbox_file "$title details" "$details_file"
  fi
}

capture_output(){
  local tmp="$1"
  LAST_OUTPUT="$(cat "$tmp")"
}

current_conf_value(){
  local key="$1" default="${2:-}" file="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"
  [[ -f "$file" ]] || { printf '%s' "$default"; return 0; }
  awk -F= -v k="$key" -v d="$default" '$1==k {print substr($0, index($0,"=")+1); found=1; exit} END{if(!found) print d}' "$file"
}

next_for(){
  case "$1" in
    preflight) printf 'remote-export' ;;
    remote-export) printf 'tunnel' ;;
    tunnel) printf 'tunnel-check' ;;
    tunnel-check) printf 'attach-target' ;;
    attach-target) printf 'bitmap' ;;
    bitmap) printf 'full' ;;
    full) printf 'wait-full' ;;
    wait-full) printf 'report' ;;
    report) printf 'cutover-check' ;;
    cutover-check) printf 'final' ;;
    final) printf 'stop-source' ;;
    stop-source) printf 'remote-dst-close' ;;
    remote-dst-close) printf 'exit' ;;
    *) printf 'preflight' ;;
  esac
}

set_step_status(){
  local action="$1" status="$2"
  PREVIOUS_ACTION="$LAST_ACTION"
  LAST_ACTION="$action"
  LAST_STATUS="$status"
  if [[ "$status" == "success" ]]; then
    SUGGESTED_ACTION="$(next_for "$action")"
  else
    SUGGESTED_ACTION="$action"
  fi
}

workflow_header(){
  local current next
  current="$SUGGESTED_ACTION"
  next="$(next_for "$current")"
  cat <<EOF
Previous : $PREVIOUS_ACTION
Last     : $LAST_ACTION ($LAST_STATUS)
Current  : $current
Next     : $next
EOF
}

run_cli_capture(){
  local tmp raw status
  raw="$(mktemp)"
  tmp="$(mktemp)"
  status=0
  (
    cd "$SCRIPT_DIR"
    NO_COLOR=1 bash "$@"
  ) >"$raw" 2>&1 || status=$?
  strip_ansi < "$raw" > "$tmp"
  rm -f "$raw"
  capture_output "$tmp"
  printf '%s' "$tmp"
  return "$status"
}

run_cli_capture_with_input(){
  local input="$1" tmp raw status
  shift
  raw="$(mktemp)"
  tmp="$(mktemp)"
  status=0
  (
    cd "$SCRIPT_DIR"
    printf '%b' "$input" | NO_COLOR=1 bash "$@"
  ) >"$raw" 2>&1 || status=$?
  strip_ansi < "$raw" > "$tmp"
  rm -f "$raw"
  capture_output "$tmp"
  printf '%s' "$tmp"
  return "$status"
}

run_cli_interactive(){
  local title="$1"; shift
  local tmp status
  tmp="$(mktemp)"
  clear || true
  printf '%s\n' "$title"
  printf '%*s\n' "${#title}" '' | tr ' ' '-'
  printf 'Running:'
  printf ' %q' "$@"
  printf '\n\n'
  status=0
  (
    cd "$SCRIPT_DIR"
    NO_COLOR=1 bash "$@"
  ) 2>&1 | strip_ansi | tee "$tmp" || status=${PIPESTATUS[0]}
  capture_output "$tmp"
  printf '\nCommand exited with status %s.\n' "$status"
  printf 'Press Enter to continue...'
  read -r _
  rm -f "$tmp"
  return "$status"
}

append_if_match(){
  local out="$1" pattern="$2" line="$3"
  if printf '%s\n' "$out" | grep -Eiq "$pattern"; then
    printf '%s\n' "$line"
  fi
}

summarize_output(){
  local action="$1" status="$2" out="$3" vm vmid nbd_port nbd_export disk bitmap
  vm="$(current_conf_value VM_NAME unknown)"
  vmid="$(current_conf_value PVE_VMID unknown)"
  nbd_port="$(current_conf_value NBD_PORT 10809)"
  nbd_export="$(current_conf_value NBD_EXPORT "vm-${vmid}")"
  disk="$(current_conf_value PVE_DISK unknown)"
  bitmap="$(current_conf_value BITMAP unknown)"

  if (( status == 0 )); then
    printf '[OK] %s completed\n\n' "$action"
  else
    printf '[FAIL] %s failed with exit code %s\n\n' "$action" "$status"
  fi

  case "$action" in
    preflight)
      append_if_match "$out" 'Preflight checks passed' '[OK] Source checks passed'
      printf '[OK] Config loaded for VM: %s\n' "$vm"
      printf '[OK] Destination SSH target: %s@%s:%s\n' "$(current_conf_value PVE_SSH_USER root)" "$(current_conf_value PVE_HOST unknown)" "$(current_conf_value PVE_SSH_PORT 22)"
      ;;
    remote-export)
      append_if_match "$out" 'Destination preflight checks passed' '[OK] Destination preflight passed'
      append_if_match "$out" 'NBD export is ready|qemu-nbd.*ready' '[OK] qemu-nbd export started'
      printf 'Export name : %s\n' "$nbd_export"
      printf 'Port        : %s\n' "$nbd_port"
      printf 'Disk        : %s\n' "$disk"
      ;;
    tunnel)
      append_if_match "$out" 'Tunnel command sent|Direct mode selected' '[OK] Tunnel command accepted'
      printf 'Expected local NBD listener: 127.0.0.1:%s\n' "$nbd_port"
      ;;
    tunnel-check)
      append_if_match "$out" 'Tunnel and NBD export are reachable|image:' '[OK] Export reachable through tunnel'
      printf 'Export name : %s\n' "$nbd_export"
      ;;
    attach-target)
      append_if_match "$out" 'Target node verified|Target node already exists' '[OK] Target attached and verified'
      printf 'Target node : %s\n' "$(current_conf_value TARGET_NODE unknown)"
      ;;
    bitmap)
      append_if_match "$out" 'Bitmap verified|Bitmap already exists' '[OK] Bitmap created/verified'
      printf 'Bitmap      : %s\n' "$bitmap"
      ;;
    full)
      append_if_match "$out" 'Full sync job submitted|blockdev-backup' '[OK] Full sync submitted'
      printf '%s\n' "$out" | awk '
        /"offset"/ {gsub(/[^0-9]/,"",$2); offset=$2}
        /"len"/ {gsub(/[^0-9]/,"",$2); len=$2}
        /"status"/ {gsub(/[",]/,"",$2); state=$2}
        END {
          if (len > 0) {
            printf "Current job status : %s\n", (state != "" ? state : "running")
            printf "Bytes transferred  : %s / %s\n", offset, len
            printf "Percent complete   : %d%%\n", int((offset*100)/len)
          } else {
            print "Current job status : see details or run wait-full/status"
          }
        }'
      printf 'Last report time    : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
      ;;
    wait-full)
      append_if_match "$out" 'Full sync marked completed|No active block job' '[OK] Full sync completed marker updated'
      ;;
    report|status-report)
      build_dashboard_text "$out"
      ;;
    cutover-check)
      append_if_match "$out" '^OK' '[OK] Cutover checks reported OK items'
      ;;
    final)
      append_if_match "$out" 'Final incremental completed' '[OK] Final sync completed'
      ;;
    stop-source)
      append_if_match "$out" 'Source VM stopped' '[OK] Source VM stopped'
      ;;
    remote-dst-close)
      append_if_match "$out" 'NBD export closed|closed' '[OK] Remote destination export closed'
      ;;
    next)
      printf '%s\n' "$out"
      ;;
    *)
      printf 'Review details for command output.\n'
      ;;
  esac
}

build_dashboard_text(){
  local out="$1" vm vmid full final stopped tunnel bitmap export last
  vm="$(current_conf_value VM_NAME unknown)"
  vmid="$(current_conf_value PVE_VMID unknown)"
  full="$(printf '%s\n' "$out" | awk -F: '/FULL_COMPLETED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  final="$(printf '%s\n' "$out" | awk -F: '/FINAL_COMPLETED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  stopped="$(printf '%s\n' "$out" | awk -F: '/SOURCE_STOPPED[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  printf '%s\n' "$out" | grep -Eq '127\.0\.0\.1:|LISTEN' && tunnel="seen" || tunnel="unknown"
  printf '%s\n' "$out" | grep -Eiq 'bitmap|Bitmap' && bitmap="seen" || bitmap="unknown"
  printf '%s\n' "$out" | grep -Eiq 'qemu-nbd|NBD|10809' && export="seen" || export="unknown"
  last="$LAST_ACTION ($LAST_STATUS)"

  printf 'Source VM            : %s\n' "$vm"
  printf 'Destination VMID     : %s\n' "$vmid"
  printf 'Full sync completed  : %s\n' "${full:-unknown}"
  printf 'Final completed      : %s\n' "${final:-unknown}"
  printf 'Source stopped       : %s\n' "${stopped:-unknown}"
  printf 'Tunnel               : %s\n' "$tunnel"
  printf 'Bitmap               : %s\n' "$bitmap"
  printf 'Export               : %s\n' "$export"
  printf 'Last action          : %s\n' "$last"
}

show_command_result(){
  local title="$1" action="$2" status="$3" details_file="$4" summary_file out
  summary_file="$(mktemp)"
  out="$(cat "$details_file")"
  summarize_output "$action" "$status" "$out" > "$summary_file"
  show_file_then_details "$title" "$summary_file" "$details_file"
  rm -f "$summary_file" "$details_file"
}

run_step(){
  local action="$1" title="$2"; shift 2
  local out status status_out
  status=0
  out="$(run_cli_capture "$@")" || status=$?
  if [[ "$action" == "full" && "$status" == "0" ]]; then
    status_out="$(run_cli_capture "$SRC_SCRIPT" status)" || true
    {
      cat "$out"
      printf '\n== Current job status ==\n'
      cat "$status_out"
    } >> "$out.combined"
    rm -f "$out" "$status_out"
    out="$out.combined"
    capture_output "$out"
  fi
  show_command_result "$title" "$action" "$status" "$out"
  if (( status == 0 )); then set_step_status "$action" success; else set_step_status "$action" failed; fi
  return "$status"
}

run_step_with_input(){
  local action="$1" title="$2" input="$3"
  shift 3
  local out status
  status=0
  out="$(run_cli_capture_with_input "$input" "$@")" || status=$?
  show_command_result "$title" "$action" "$status" "$out"
  if (( status == 0 )); then set_step_status "$action" success; else set_step_status "$action" failed; fi
  return "$status"
}

run_combined_step(){
  local action="$1" title="$2" first_title="$3"; shift 3
  local tmp one status cmd_count cmd
  tmp="$(mktemp)"
  status=0
  cmd_count=0
  for cmd in "$@"; do
    cmd_count=$((cmd_count + 1))
    printf '== %s %s ==\n' "$first_title" "$cmd_count" >> "$tmp"
    one="$(run_cli_capture "$SRC_SCRIPT" "$cmd")" || status=$?
    cat "$one" >> "$tmp"
    rm -f "$one"
    printf '\n' >> "$tmp"
    (( status == 0 )) || break
  done
  capture_output "$tmp"
  show_command_result "$title" "$action" "$status" "$tmp"
  if (( status == 0 )); then set_step_status "$action" success; else set_step_status "$action" failed; fi
  return "$status"
}

run_status_report(){
  local tmp one status
  tmp="$(mktemp)"
  status=0
  printf '== Source report ==\n' >> "$tmp"
  one="$(run_cli_capture "$SRC_SCRIPT" report)" || status=$?
  cat "$one" >> "$tmp"; rm -f "$one"
  printf '\n== Source status ==\n' >> "$tmp"
  one="$(run_cli_capture "$SRC_SCRIPT" status)" || status=$?
  cat "$one" >> "$tmp"; rm -f "$one"
  printf '\n== Remote destination status ==\n' >> "$tmp"
  one="$(run_cli_capture "$SRC_SCRIPT" remote-dst-status)" || status=$?
  cat "$one" >> "$tmp"; rm -f "$one"
  capture_output "$tmp"
  show_command_result "Status / Report" status-report "$status" "$tmp"
  return "$status"
}

run_next_suggested(){
  run_step next "Next Suggested Step" "$SRC_SCRIPT" next || true
}

confirm_final(){
  ask_exact "WARNING" "This will suspend the source VM and perform the final incremental sync." "YES"
}

confirm_stop_source(){
  ask_exact "WARNING" "This will stop the source VM.\n\nIt does NOT:\n* delete disks\n* undefine VM\n* remove storage" "STOP"
}

run_final_sync(){
  confirm_final || return 1
  run_step_with_input final "Final sync" "yes\n" "$SRC_SCRIPT" final
}

run_stop_source(){
  confirm_stop_source || return 1
  run_step_with_input stop-source "Stop source" "yes\n" "$SRC_SCRIPT" stop-source
}

ask_remote_prepare_form(){
  local values file default_vm default_host default_vmid default_user default_port
  local vm host vmid user port

  default_vm="$(current_conf_value VM_NAME kvm3023)"
  default_host="$(current_conf_value PVE_HOST CHANGE_ME)"
  default_vmid="$(current_conf_value PVE_VMID '')"
  default_user="$(current_conf_value PVE_SSH_USER root)"
  default_port="$(current_conf_value PVE_SSH_PORT 22)"
  file="$(mktemp)"

  if whiptail_supports_form; then
    values="$(whiptail --title "New Migration" --form "Enter values on this SOURCE host." 16 78 6 \
      "Source VM:" 1 1 "$default_vm" 1 22 36 128 \
      "Destination Host:" 2 1 "$default_host" 2 22 36 128 \
      "Destination VMID:" 3 1 "$default_vmid" 3 22 36 32 \
      "SSH User:" 4 1 "$default_user" 4 22 36 64 \
      "SSH Port:" 5 1 "$default_port" 5 22 36 16 \
      3>&1 1>&2 2>&3)" || { rm -f "$file"; return 1; }
    printf '%s\n' "$values" > "$file"
  else
    whiptail --title "New Migration" --msgbox "This whiptail build does not support --form.\n\nThe UI will ask the same five values one by one." 10 78 || true
    vm="$(ask_input "New Migration" "Source VM:" "$default_vm")" || { rm -f "$file"; return 1; }
    host="$(ask_input "New Migration" "Destination Host:" "$default_host")" || { rm -f "$file"; return 1; }
    vmid="$(ask_input "New Migration" "Destination VMID:" "$default_vmid")" || { rm -f "$file"; return 1; }
    user="$(ask_input "New Migration" "SSH User:" "$default_user")" || { rm -f "$file"; return 1; }
    port="$(ask_input "New Migration" "SSH Port:" "$default_port")" || { rm -f "$file"; return 1; }
    printf '%s\n%s\n%s\n%s\n%s\n' "$vm" "$host" "$vmid" "$user" "$port" > "$file"
  fi

  printf '%s' "$file"
}


confirm_remote_prepare_summary(){
  local vm="$1" host="$2" vmid="$3" user="$4" port="$5"
  whiptail --title "Confirm Remote Migration" --yesno "Source VM: $vm\nDestination Host: $host\nDestination VMID: $vmid\nSSH User: $user\nSSH Port: $port\n\nRun remote-prepare from this SOURCE host now?" 15 78
}

main_menu(){
  local choice
  while true; do
    choice="$(whiptail --title "kvm2pve Terminal UI v${VERSION}" --menu "Choose an action." 20 78 10 \
      "start" "New Migration - source remote wizard" \
      "continue" "Continue Migration" \
      "status-report" "Status / Report" \
      "next" "Next Suggested Step" \
      "advanced" "Advanced / Legacy" \
      "exit" "Exit" \
      3>&1 1>&2 2>&3)" || exit 0
    case "$choice" in
      start) start_new_migration || true ;;
      continue) remote_workflow_menu || true ;;
      status-report) run_status_report || true ;;
      next) run_next_suggested || true ;;
      advanced) advanced_tools || true ;;
      exit) exit 0 ;;
    esac
  done
}

start_new_migration(){
  local file vm host vmid user port
  if ! file="$(ask_remote_prepare_form)"; then
    whiptail --title "New Migration" --msgbox "New Migration was cancelled.

You can also use the CLI remote workflow:
./kvm2pve-src.sh remote-prepare VM_NAME PVE_HOST PVE_VMID [SSH_PORT] [SSH_USER]" 11 78 || true
    return 0
  fi
  vm="$(sed -n '1p' "$file")"
  host="$(sed -n '2p' "$file")"
  vmid="$(sed -n '3p' "$file")"
  user="$(sed -n '4p' "$file")"
  port="$(sed -n '5p' "$file")"
  rm -f "$file"
  [[ -n "$vm" && -n "$host" && -n "$vmid" ]] || return 0
  [[ -n "$user" ]] || user="root"
  [[ -n "$port" ]] || port="22"
  confirm_remote_prepare_summary "$vm" "$host" "$vmid" "$user" "$port" || return 0
  if run_cli_interactive "Remote prepare" "$SRC_SCRIPT" remote-prepare "$vm" "$host" "$vmid" "$port" "$user"; then
    set_step_status remote-prepare success
    SUGGESTED_ACTION="preflight"
    remote_workflow_menu
  else
    set_step_status remote-prepare failed
  fi
}

remote_workflow_menu(){
  local choice header
  while true; do
    header="$(workflow_header)"
    choice="$(whiptail --title "Source Remote Workflow" --default-item "$SUGGESTED_ACTION" --menu "$header" 24 78 16 \
      "prep" "=== Safe Preparation ===" \
      "preflight" "Run preflight" \
      "remote-export" "Run remote export" \
      "tunnel" "Start tunnel" \
      "tunnel-check" "Check tunnel" \
      "attach-target" "Attach target and check" \
      "bitmap" "Create and check bitmap" \
      "sync" "=== Full Sync ===" \
      "full" "Start full sync" \
      "wait-full" "Wait full sync" \
      "report" "Show report" \
      "status-report" "Status dashboard" \
      "next" "Next Suggested Step" \
      "danger" "=== Cutover / Danger Zone ===" \
      "cutover-check" "Cutover check" \
      "final" "Final sync" \
      "stop-source" "Stop source" \
      "remote-dst-close" "Close remote destination export" \
      "exit" "Exit" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      prep|sync|danger) ;;
      preflight) run_step preflight "Run preflight" "$SRC_SCRIPT" preflight || true ;;
      remote-export) run_step remote-export "Run remote export" "$SRC_SCRIPT" remote-export || true ;;
      tunnel) run_step tunnel "Start tunnel" "$SRC_SCRIPT" tunnel || true ;;
      tunnel-check) run_step tunnel-check "Check tunnel" "$SRC_SCRIPT" tunnel-check || true ;;
      attach-target) run_combined_step attach-target "Attach target" "target" attach-target check-target || true ;;
      bitmap) run_combined_step bitmap "Create bitmap" "bitmap" bitmap check-bitmap || true ;;
      full) run_step full "Start full sync" "$SRC_SCRIPT" full || true ;;
      wait-full) run_step wait-full "Wait full sync" "$SRC_SCRIPT" wait-full || true ;;
      report) run_step report "Show report" "$SRC_SCRIPT" report || true ;;
      status-report) run_status_report || true ;;
      next) run_next_suggested || true ;;
      cutover-check) run_step cutover-check "Cutover check" "$SRC_SCRIPT" cutover-check || true ;;
      final) run_final_sync || true ;;
      stop-source) run_stop_source || true ;;
      remote-dst-close) run_step remote-dst-close "Close remote destination export" "$SRC_SCRIPT" remote-dst-close || true ;;
      exit) return 0 ;;
    esac
  done
}

manual_handoff_workflow(){
  local choice
  choice="$(whiptail --title "Manual Handoff Workflow" --menu "Legacy/manual path for hosts where source cannot SSH to destination." 16 82 5 \
    "destination" "Destination Host - generate handoff token" \
    "source" "Source Host - paste handoff token" \
    "back" "Back" \
    3>&1 1>&2 2>&3)" || return 0
  case "$choice" in
    destination) start_destination_flow || true ;;
    source) start_source_flow || true ;;
  esac
}

start_destination_flow(){
  local vmid token tmp
  vmid="$(ask_input "Destination Host" "Destination VMID:" "$(current_conf_value PVE_VMID '')")" || return 0
  [[ -n "$vmid" ]] || return 0
  run_command_with_input "Destination quick" "yes\n" "$DST_SCRIPT" quick "$vmid" || return 1
  token="$(printf '%s\n' "$LAST_OUTPUT" | grep -m1 '^KVM2PVE_HANDOFF_V1:' || true)"
  if [[ -n "$token" ]]; then
    tmp="$(mktemp)"
    {
      printf 'Handoff token\n-------------\n%s\n\n' "$token"
      printf 'Copy this token to the source host.\n\nFull command output\n-------------------\n%s\n' "$LAST_OUTPUT"
    } > "$tmp"
    show_textbox_file "Handoff token" "$tmp"
    rm -f "$tmp"
  fi
  run_command_confirm "Export NBD" "Export NBD now?\n\nThis exposes the destination disk for writing." "$DST_SCRIPT" export || true
}

start_source_flow(){
  local token vm host port input
  token="$(ask_input "Source Host" "Paste handoff token:" '')" || return 0
  [[ -n "$token" ]] || return 0
  vm="$(ask_input "Source Host" "Source VM:" "$(current_conf_value VM_NAME kvm3023)")" || return 0
  host="$(ask_input "Source Host" "Destination Host:" "$(current_conf_value PVE_HOST CHANGE_ME)")" || return 0
  port="$(ask_input "Source Host" "SSH Port:" "$(current_conf_value PVE_SSH_PORT 22)")" || return 0
  [[ -n "$port" ]] || port="22"
  input="${vm}\n${host}\n${port}\nyes\nno\n"
  run_command_with_input "Source quick" "$input" "$SRC_SCRIPT" quick "$token" || return 1
  remote_workflow_menu
}

run_command_with_input(){
  local title="$1" input="$2"; shift 2
  local tmp raw status summary
  raw="$(mktemp)"
  tmp="$(mktemp)"
  status=0
  (
    cd "$SCRIPT_DIR"
    printf '%b' "$input" | NO_COLOR=1 bash "$@"
  ) >"$raw" 2>&1 || status=$?
  strip_ansi < "$raw" > "$tmp"
  rm -f "$raw"
  capture_output "$tmp"
  summary="$(mktemp)"
  summarize_output "$title" "$status" "$LAST_OUTPUT" > "$summary"
  show_file_then_details "$title" "$summary" "$tmp"
  rm -f "$summary" "$tmp"
  return "$status"
}

run_command_confirm(){
  local title="$1" prompt="$2"; shift 2
  ask_yesno "$title" "$prompt" || return 1
  run_step "$title" "$title" "$@"
}

advanced_tools(){
  local choice
  while true; do
    choice="$(whiptail --title "Advanced / Legacy" --menu "Individual commands are exposed here for operators who need them." 18 82 6 \
      "source" "Source tools" \
      "destination" "Destination tools" \
      "manual" "Manual handoff workflow" \
      "recovery" "Recovery guidance" \
      "back" "Back" \
      3>&1 1>&2 2>&3)" || return 0
    case "$choice" in
      source) advanced_source_tools || true ;;
      destination) advanced_destination_tools || true ;;
      manual) manual_handoff_workflow || true ;;
      recovery) recovery_guidance || true ;;
      back) return 0 ;;
    esac
  done
}

advanced_source_tools(){
  local cmd
  while true; do
    cmd="$(whiptail --title "Source Tools" --menu "Run a source-side command." 28 82 20 \
      "remote-prepare" "Prepare Destination Host over SSH" \
      "remote-export" "Run Destination preflight/export/status over SSH" \
      "remote-dst-status" "Show remote Destination status" \
      "remote-dst-close" "Close remote Destination NBD" \
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
      remote-prepare) start_new_migration || true ;;
      wait-full) run_step wait-full "Wait full sync" "$SRC_SCRIPT" wait-full || true ;;
      full) run_step full "Start full sync" "$SRC_SCRIPT" full || true ;;
      mark-full) run_step mark-full "Mark full complete" "$SRC_SCRIPT" mark-full || true ;;
      final) run_final_sync || true ;;
      stop-source) run_stop_source || true ;;
      remote-export) run_step remote-export "Remote export" "$SRC_SCRIPT" remote-export || true ;;
      remote-dst-close) run_step remote-dst-close "Remote destination close" "$SRC_SCRIPT" remote-dst-close || true ;;
      cleanup) run_step cleanup "Source cleanup" "$SRC_SCRIPT" cleanup || true ;;
      *) run_step "$cmd" "Source: $cmd" "$SRC_SCRIPT" "$cmd" || true ;;
    esac
  done
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
      export) run_step export "Destination export" "$DST_SCRIPT" export || true ;;
      close) run_step close "Destination close" "$DST_SCRIPT" close || true ;;
      boot) run_step boot "Destination boot" "$DST_SCRIPT" boot || true ;;
      quick)
        vmid="$(ask_input "Destination quick" "Destination VMID:" "$(current_conf_value PVE_VMID '')")" || continue
        [[ -n "$vmid" ]] && run_command_with_input "Destination quick" "yes\n" "$DST_SCRIPT" quick "$vmid" || true
        ;;
      *) run_step "$cmd" "Destination: $cmd" "$DST_SCRIPT" "$cmd" || true ;;
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
