#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

app_dest="/Applications/Nomas Motion.app"
bundle_id="app.nomas.motion"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"
requested_socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-$canonical_socket_path}"
socket_path="$canonical_socket_path"
log_path="/tmp/nomas-motion-uninstall.log"
current_step="initializing"

if [[ "$requested_socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

fail() {
  local status="$?"
  echo
  echo "Uninstall failed during: $current_step" >&2
  echo "Log: $log_path" >&2
  if [[ -s "$log_path" ]]; then
    echo >&2
    tail -n 80 "$log_path" >&2 || true
  fi
  exit "$status"
}
trap fail ERR

if [[ ! -t 0 ]]; then
  cat >&2 <<'ERROR'
scripts/uninstall-local-app.sh must be run from an interactive terminal.

It asks sudo for the admin password while removing /Applications/Nomas Motion.app
and the sensor LaunchDaemon. Run it directly in Terminal from the repository root:

  scripts/uninstall-local-app.sh
ERROR
  exit 1
fi

: >"$log_path"

run_logged() {
  "$@" >>"$log_path" 2>&1
}

run_sudo_logged() {
  sudo "$@" 2>&1 | /usr/bin/tee -a "$log_path" >/dev/null
}

unregister_login_item() {
  local executable="$1"
  NOMAS_MOTION_SKIP_LOGIN_ITEM=1 "$executable" --unregister-login-item >>"$log_path" 2>&1 &
  local pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return 0
    fi
    sleep 0.25
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "Installed app did not complete login-item unregister; refusing to leave a stale Login Item." >&2
  return 1
}

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

validate_app_bundle() {
  if [[ -L "$app_dest" ]]; then
    echo "Refusing to remove symlink at $app_dest" >&2
    exit 1
  fi
  if [[ ! -e "$app_dest" ]]; then
    return 0
  fi
  if [[ ! -d "$app_dest" ]]; then
    echo "Refusing to remove non-directory at $app_dest" >&2
    exit 1
  fi
  local existing_bundle_id
  existing_bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_dest/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "$bundle_id" ]]; then
    echo "Refusing to remove app with different bundle id at $app_dest: ${existing_bundle_id:-unknown}" >&2
    exit 1
  fi
}

validate_socket_path
validate_app_bundle

echo "==> Stop app"
current_step="stopping NomasMotion processes"
run_logged scripts/stop-local-app.sh

if [[ -x "$app_dest/Contents/MacOS/NomasMotion" ]]; then
  echo "==> Unregister launch-at-login item"
  current_step="unregistering launch-at-login item"
  unregister_login_item "$app_dest/Contents/MacOS/NomasMotion"
fi

echo "==> Remove sensor helper"
current_step="removing privileged helper"
run_logged scripts/uninstall-privileged-helper.sh

echo "==> Remove app bundle"
current_step="removing ${app_dest}"
run_sudo_logged /bin/rm -rf "$app_dest"
run_sudo_logged /bin/rm -f "$socket_path"

trap - ERR

cat <<DONE
Nomas Motion uninstalled.

Removed:
  $app_dest
  app.nomas.motion.sensor-helper
DONE
