#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${KVM2PVE_CONFIG:-${SCRIPT_DIR}/kvm2pve.env}"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Config not found: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
NBD_PORT="${NBD_PORT:-10809}"
NBD_EXPORT="${NBD_EXPORT:?NBD_EXPORT is not set}"
echo "Expected local listener: 127.0.0.1:${NBD_PORT}"
ss -lntp | grep "127.0.0.1:${NBD_PORT}" || true
echo
echo "Run this manual NBD check:"
echo "qemu-img info \"nbd:127.0.0.1:${NBD_PORT}:exportname=${NBD_EXPORT}\""
