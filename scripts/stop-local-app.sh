#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
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

app_pids="$(app_process_pids)"
if [[ -z "$app_pids" ]]; then
  echo "Nomas Motion app is not running."
  exit 0
fi

echo "Stopping Nomas Motion app..."
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  kill "$pid" 2>/dev/null || true
done <<<"$app_pids"

for _ in 1 2 3 4 5; do
  if [[ -z "$(app_process_pids)" ]]; then
    echo "Nomas Motion app stopped."
    exit 0
  fi
  sleep 1
done

echo "Nomas Motion app did not stop cleanly; forcing stop."
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  kill -9 "$pid" 2>/dev/null || true
done <<<"$(app_process_pids)"
echo "Nomas Motion app stopped."
