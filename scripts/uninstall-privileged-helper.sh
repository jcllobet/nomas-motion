#!/usr/bin/env bash
set -euo pipefail

label="app.nomas.motion.sensor-helper"
helper_dest="/Library/PrivilegedHelperTools/$label"
plist_dest="/Library/LaunchDaemons/$label.plist"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"
requested_socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-$canonical_socket_path}"
socket_path="$canonical_socket_path"
stdout_log="/var/log/nomas-motion-privileged-helper.out.log"
stderr_log="/var/log/nomas-motion-privileged-helper.err.log"

if [[ "$requested_socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

validate_socket_path() {
  local byte_count
  if [[ -z "$socket_path" || "$socket_path" != /* || "$socket_path" == "/" ]]; then
    echo "NOMAS_MOTION_SENSOR_SOCKET must be a non-root absolute path: $socket_path" >&2
    exit 1
  fi
  if [[ "$socket_path" == */../* || "$socket_path" == */.. || "$socket_path" == */./* || "$socket_path" == */. || "$socket_path" == */ ]]; then
    echo "NOMAS_MOTION_SENSOR_SOCKET contains an unsafe path component: $socket_path" >&2
    exit 1
  fi
  if [[ "$socket_path" == *$'\n'* || "$socket_path" == *$'\r'* || "$socket_path" == *$'\t'* ]]; then
    echo "NOMAS_MOTION_SENSOR_SOCKET contains a control character" >&2
    exit 1
  fi
  byte_count="$(LC_ALL=C printf '%s' "$socket_path" | /usr/bin/wc -c | tr -d '[:space:]')"
  if (( byte_count > 103 )); then
    echo "NOMAS_MOTION_SENSOR_SOCKET is too long for a Unix socket ($byte_count bytes)" >&2
    exit 1
  fi
  if [[ -e "$socket_path" && ! -S "$socket_path" ]]; then
    echo "Refusing to remove non-socket at $socket_path" >&2
    exit 1
  fi
}

validate_helper_plist() {
  if [[ -L "$plist_dest" ]]; then
    echo "Refusing to remove symlink at $plist_dest" >&2
    exit 1
  fi
  if [[ ! -e "$plist_dest" ]]; then
    return 0
  fi
  local installed_label
  installed_label="$(plutil -extract Label raw "$plist_dest" 2>/dev/null || true)"
  if [[ "$installed_label" != "$label" ]]; then
    echo "Refusing to remove LaunchDaemon with unexpected label at $plist_dest: ${installed_label:-unknown}" >&2
    exit 1
  fi
}

bootout_helper() {
  local helper_pids
  sudo launchctl bootout "system/$label" >/dev/null 2>&1 || true
  sudo launchctl bootout system "$plist_dest" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if sudo launchctl print "system/$label" >/dev/null 2>&1; then
      sleep 0.25
      continue
    fi
    # Re-scan by executable path after bootout instead of trusting a PID
    # captured before bootout, which can become stale or be reused.
    helper_pids="$(/bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v helper="$helper_dest" '$2 == helper || index($2, helper " ") == 1 { print $1 }' || true)"
    if [[ -z "$helper_pids" ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "LaunchDaemon $label process did not stop after bootout" >&2
  return 1
}

if [[ ! -t 0 ]]; then
  cat >&2 <<'ERROR'
scripts/uninstall-privileged-helper.sh must be run from an interactive terminal.

It asks sudo for the admin password while removing the LaunchDaemon.
Run it directly in Terminal from the repository root:

  scripts/uninstall-privileged-helper.sh
ERROR
  exit 1
fi

validate_socket_path
validate_helper_plist

echo "==> Stop helper"
bootout_helper

echo "==> Remove helper files"
sudo /bin/rm -f "$plist_dest" "$helper_dest"
sudo /bin/rm -f "$socket_path"
sudo /bin/rm -f "$stdout_log" "$stderr_log"

echo "Privileged helper uninstalled."
