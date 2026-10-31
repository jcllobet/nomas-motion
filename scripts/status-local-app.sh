#!/usr/bin/env bash
set -euo pipefail

label="app.nomas.motion.sensor-helper"
app_path="/Applications/Nomas Motion.app"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installed_executable="$app_path/Contents/MacOS/NomasMotion"
debug_executable="$repo_root/.build/debug/NomasMotion"
release_executable="$repo_root/.build/release/NomasMotion"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"
requested_socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-$canonical_socket_path}"
socket_path="$canonical_socket_path"

if [[ "$requested_socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

app_process_pids() {
  /bin/ps -axo pid=,args= | /usr/bin/awk \
    -v installed="$installed_executable" \
    -v debug="$debug_executable" \
    -v release="$release_executable" \
    '
      {
        command = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
        if (matches(command, installed) || matches(command, debug) || matches(command, release) ||
            matches(command, ".build/debug/NomasMotion") || matches(command, "./.build/debug/NomasMotion") ||
            matches(command, ".build/release/NomasMotion") || matches(command, "./.build/release/NomasMotion")) {
          print $1
        }
      }
      function matches(command, path) {
        return index(command, path) == 1 &&
          (length(command) == length(path) || substr(command, length(path) + 1, 1) == " ")
      }'
}

app_pids="$(app_process_pids)"
if [[ -n "$app_pids" ]]; then
  echo "App: running (pid ${app_pids//$'\n'/, })"
else
  echo "App: stopped"
fi

if launchctl print "system/$label" >/dev/null 2>&1; then
  echo "Helper: loaded"
else
  echo "Helper: not loaded"
fi

if [[ -S "$socket_path" ]]; then
  echo "Socket: present ($socket_path)"
else
  echo "Socket: missing ($socket_path)"
fi

if [[ -d "$app_path" ]]; then
  echo "Bundle: installed ($app_path)"
else
  echo "Bundle: not installed"
fi
