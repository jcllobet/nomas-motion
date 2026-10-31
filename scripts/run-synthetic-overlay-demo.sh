#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pipe_path="${NOMAS_MOTION_SENSOR_PIPE:-/tmp/nomas-motion-synthetic.pipe}"
app_log="${NOMAS_MOTION_APP_LOG:-/tmp/nomas-motion-synthetic-app.log}"
duration="${1:-20}"
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
  /bin/rm -f "$pipe_path"
  if [[ -s "$app_log" ]]; then
    echo
    echo "==> Nomas Motion synthetic app log: $app_log"
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

echo "==> Build"
swift build -Xswiftc -warnings-as-errors

echo "==> Prepare FIFO: $pipe_path"
/bin/rm -f "$pipe_path"
mkfifo "$pipe_path"

echo "==> Launch Nomas Motion with overlay already visible"
NOMAS_MOTION_SENSOR_PIPE="$pipe_path" NOMAS_MOTION_START_VISIBLE=1 NOMAS_MOTION_SKIP_LOGIN_ITEM=1 .build/debug/NomasMotion >"$app_log" 2>&1 &
app_pid=$!
sleep 1
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "Nomas Motion exited before synthetic samples were sent. See $app_log" >&2
  exit 1
fi

echo "==> Feed synthetic motion for ${duration}s"
echo "Watch the dot overlay move. This does not test the real accelerometer."
{
  end=$((SECONDS + duration))
  while [[ "$SECONDS" -lt "$end" ]]; do
    printf '0 0 65536\n'
    printf '12000 -8000 65536\n'
    printf '22000 -16000 65536\n'
    printf '12000 -8000 65536\n'
    printf '0 0 65536\n'
    printf -- '-12000 8000 65536\n'
    printf -- '-22000 16000 65536\n'
    printf -- '-12000 8000 65536\n'
    sleep 1
  done
} >"$pipe_path"

echo "Synthetic overlay demo complete. App log: $app_log"
