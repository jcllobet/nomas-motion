#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-/var/run/nomas-motion-sensor.sock}"
app_log="${NOMAS_MOTION_APP_LOG:-/tmp/nomas-motion-app.log}"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"

if [[ "$socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

repo_root="$(pwd)"
installed_executable="/Applications/Nomas Motion.app/Contents/MacOS/NomasMotion"
debug_executable="$repo_root/.build/debug/NomasMotion"
release_executable="$repo_root/.build/release/NomasMotion"

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

cleanup() {
  if [[ -n "${app_pid:-}" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -s "$app_log" ]]; then
    echo
    echo "==> Nomas Motion app log: $app_log"
    cat "$app_log"
  fi
}
trap cleanup EXIT INT TERM

if [[ -n "$(app_process_pids)" ]]; then
  cat >&2 <<'ERROR'
Nomas Motion is already running.

Stop it first:

  scripts/stop-local-app.sh
ERROR
  exit 1
fi

if [[ ! -S "$socket_path" ]]; then
  cat >&2 <<ERROR
Nomas Motion privileged helper is not running.

Install it once first from the repository root:

  scripts/install-privileged-helper.sh

Expected helper socket:
  $socket_path
ERROR
  exit 1
fi

echo "==> Build app"
swift build -Xswiftc -warnings-as-errors

echo "==> Launch Nomas Motion as current user"
echo "Sensor socket: $socket_path"
NOMAS_MOTION_SENSOR_SOCKET="$socket_path" .build/debug/NomasMotion >"$app_log" 2>&1 &
app_pid=$!
sleep 1
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "Nomas Motion exited during launch. See $app_log" >&2
  exit 1
fi

echo "Nomas Motion is running with the installed privileged helper."
echo "Press Ctrl+C to stop the app. The helper remains installed."
while kill -0 "$app_pid" 2>/dev/null; do
  sleep 1
done
