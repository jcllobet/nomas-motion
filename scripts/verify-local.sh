#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

repo_root="$(pwd)"
installed_executable="/Applications/Nomas Motion.app/Contents/MacOS/NomasMotion"
debug_executable="$repo_root/.build/debug/NomasMotion"
release_executable="$repo_root/.build/release/NomasMotion"

verify_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nomas-motion-verify.XXXXXX")"
smoke_pids=()

cleanup() {
  for pid in "${smoke_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      stop_process "$pid" "cleanup" || true
    fi
  done
  /bin/rm -rf -- "$verify_tmp"
}
trap cleanup EXIT INT TERM

wait_for_process() {
  local pid="$1"
  local label="$2"
  local timeout_seconds="${3:-5}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if kill -0 "$pid" 2>/dev/null; then
      # Existence is not readiness: allow AppKit to install the app's signal
      # sources before the shutdown assertion below.
      sleep 0.5
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "SMOKE_STARTUP=failed component=$label pid=$pid exited-during-initialization" >&2
        return 1
      fi
      echo "SMOKE_STARTUP=ready component=$label pid=$pid"
      return 0
    fi
    sleep 0.05
  done
  echo "SMOKE_STARTUP=failed component=$label pid=$pid" >&2
  return 1
}

stop_process() {
  local pid="$1"
  local label="$2"

  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      echo "SMOKE_SHUTDOWN=clean component=$label pid=$pid"
      return 0
    fi
    sleep 0.25
  done

  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "SMOKE_SHUTDOWN=forced component=$label pid=$pid"
  return 1
}

require_artifact() {
  local path="$1"
  local kind="$2"
  if [[ ! -s "$path" ]]; then
    echo "Expected non-empty $kind artifact: $path" >&2
    exit 1
  fi

  local description
  description="$(file -b -- "$path")"
  case "$kind" in
    csv)
      [[ "$description" == *text* ]] || {
        echo "Expected text CSV artifact, got '$description': $path" >&2
        exit 1
      }
      head -n 1 "$path" | rg -q ',' || {
        echo "Expected comma-separated CSV header: $path" >&2
        exit 1
      }
      ;;
    json)
      [[ "$description" == *text* || "$description" == *JSON* ]] || {
        echo "Expected JSON text artifact, got '$description': $path" >&2
        exit 1
      }
      if command -v jq >/dev/null 2>&1; then
        jq -e . "$path" >/dev/null || {
          echo "Expected valid JSON artifact: $path" >&2
          exit 1
        }
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$path" || {
          echo "Expected valid JSON artifact: $path" >&2
          exit 1
        }
      else
        echo "Need jq or python3 to validate JSON artifacts" >&2
        exit 1
      fi
      ;;
    png)
      [[ "$description" == *PNG* ]] || {
        echo "Expected PNG artifact, got '$description': $path" >&2
        exit 1
      }
      ;;
    mp4)
      [[ "$description" == *ISO* || "$description" == *MPEG* ]] || {
        echo "Expected MPEG/ISO video artifact, got '$description': $path" >&2
        exit 1
      }
      ;;
    icns)
      [[ "$description" == *Icon* || "$description" == *icon* ]] || {
        echo "Expected ICNS icon artifact, got '$description': $path" >&2
        exit 1
      }
      ;;
    *)
      echo "Unknown artifact type: $kind" >&2
      exit 1
      ;;
  esac
  echo "artifact[$kind]: $path ($description)"
}

echo "==> Script syntax"
bash -n \
  scripts/verify-local.sh \
  scripts/install-privileged-helper.sh \
  scripts/uninstall-privileged-helper.sh \
  scripts/install-local-app.sh \
  scripts/uninstall-local-app.sh \
  scripts/status-local-app.sh \
  scripts/stop-local-app.sh \
  scripts/run-helper-socket-mvp.sh \
  scripts/run-synthetic-overlay-demo.sh \
  scripts/build-app-bundle.sh

echo "==> Script executability"
for script in \
  scripts/verify-local.sh \
  scripts/install-privileged-helper.sh \
  scripts/uninstall-privileged-helper.sh \
  scripts/install-local-app.sh \
  scripts/uninstall-local-app.sh \
  scripts/status-local-app.sh \
  scripts/stop-local-app.sh \
  scripts/run-helper-socket-mvp.sh \
  scripts/run-synthetic-overlay-demo.sh \
  scripts/build-app-bundle.sh
do
  if [[ ! -x "$script" ]]; then
    echo "Expected $script to be executable" >&2
    exit 1
  fi
done

ensure_no_app_processes() {
  local app_pids
  app_pids="$(/bin/ps -axo pid=,args= | /usr/bin/awk \
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
      }')"
  if [[ -n "$app_pids" ]]; then
    echo "Expected no stale NomasMotion app processes. Stop them with scripts/stop-local-app.sh" >&2
    printf '%s\n' "$app_pids" >&2
    exit 1
  fi
}

echo "==> Stale app process check"
ensure_no_app_processes

echo "==> Interactive admin boundary checks"
for admin_script in \
  scripts/install-privileged-helper.sh \
  scripts/uninstall-privileged-helper.sh
do
  admin_output="$("$admin_script" </dev/null 2>&1 || true)"
  printf '%s\n' "$admin_output"
  if [[ "$admin_output" != *"must be run from an interactive terminal"* ]]; then
    echo "Expected $admin_script to fail fast outside an interactive terminal" >&2
    exit 1
  fi
done

echo "==> Generated output ignores"
if ! git check-ignore -q .build; then
  echo "Expected .build/ to be ignored generated output" >&2
  exit 1
fi
if ! git check-ignore -q dist; then
  echo "Expected dist/ to be ignored generated output" >&2
  exit 1
fi

echo "==> Cautious copy"
if rg -n '\b(prevention|prevent|treatment|cure)\b' README.md ARCHITECTURE.md SETTINGS.md STATISTICS.md CONTRIBUTING.md Sources; then
  echo "Found medical-strength wording in active copy/source" >&2
  exit 1
fi

echo "==> Handoff docs"
if ! rg -q 'Auto mode is enabled by default.*15 seconds.*0\.020 g.*vehicle-motion threshold' README.md; then
  echo "Expected README to describe passive auto-mode app behavior" >&2
  exit 1
fi
if ! rg -q 'scripts/install-privileged-helper.sh' README.md ARCHITECTURE.md CONTRIBUTING.md; then
  echo "Expected handoff docs to mention the privileged helper install command" >&2
  exit 1
fi
if ! rg -q 'overlay starts hidden' README.md ARCHITECTURE.md SETTINGS.md STATISTICS.md CONTRIBUTING.md; then
  echo "Expected handoff docs to mention that the overlay starts hidden" >&2
  exit 1
fi

echo "==> Package manifest"
package_manifest="$verify_tmp/package.json"
swift package describe --type json >"$package_manifest"
require_artifact "$package_manifest" json
for target in \
  NomasMotion \
  NomasMotionSensorProbe \
  NomasMotionSensorBridge \
  NomasMotionPrivilegedHelper \
  NomasMotionVerify \
  NomasMotionOverlay \
  NomasMotionCore
do
  if ! rg -q "\"name\" : \"$target\"" "$package_manifest"; then
    echo "Expected SwiftPM target $target in package manifest" >&2
    exit 1
  fi
done
echo "==> Motion freshness boundary"
if rg -n 'currentCue\(\)' Sources/NomasMotion Sources/NomasMotionOverlay; then
  echo "Continuous shipping consumers must use a freshness-bounded cue" >&2
  exit 1
fi

echo "==> Build"
swift build -Xswiftc -warnings-as-errors

echo "==> Unit tests (XCTest)"
xcode_version="$(xcodebuild -version 2>/dev/null || true)"
if [[ "$xcode_version" == Xcode\ * ]]; then
  swift test -Xswiftc -warnings-as-errors
else
  echo "Full Xcode is required: production assertions live in XCTest and may not be skipped." >&2
  exit 1
fi

echo "==> Verification (NomasMotionVerify)"
.build/debug/NomasMotionVerify

echo "==> Overlay snapshot"
dark_snapshot="$verify_tmp/overlay-snapshot-dark.png"
light_snapshot="$verify_tmp/overlay-snapshot-light.png"
right_motion_snapshot="$verify_tmp/overlay-snapshot-right-motion.png"
left_motion_snapshot="$verify_tmp/overlay-snapshot-left-motion.png"
snapshot_output="$(.build/debug/NomasMotionVerify snapshot "$dark_snapshot" dark)"
printf '%s\n' "$snapshot_output"
require_artifact "$dark_snapshot" png
if [[ "$snapshot_output" != *"mode=dark dotPixels="* ]]; then
  echo "Expected dark overlay snapshot to report dot pixels" >&2
  exit 1
fi
snapshot_output="$(.build/debug/NomasMotionVerify snapshot "$light_snapshot" light)"
printf '%s\n' "$snapshot_output"
require_artifact "$light_snapshot" png
if [[ "$snapshot_output" != *"mode=light dotPixels="* ]]; then
  echo "Expected light overlay snapshot to report dot pixels" >&2
  exit 1
fi
snapshot_output="$(.build/debug/NomasMotionVerify snapshot "$right_motion_snapshot" dark 96 -24)"
printf '%s\n' "$snapshot_output"
require_artifact "$right_motion_snapshot" png
snapshot_output="$(.build/debug/NomasMotionVerify snapshot "$left_motion_snapshot" dark -96 24)"
printf '%s\n' "$snapshot_output"
require_artifact "$left_motion_snapshot" png
if cmp -s "$dark_snapshot" "$right_motion_snapshot" || cmp -s "$dark_snapshot" "$left_motion_snapshot"; then
  echo "Expected nonzero phase to change the rendered side rails" >&2
  exit 1
fi

echo "==> App bundle"
bundle_path="$(scripts/build-app-bundle.sh | tail -n 1)"
if [[ ! -x "$bundle_path/Contents/MacOS/NomasMotion" ]]; then
  echo "Expected executable in $bundle_path" >&2
  exit 1
fi
if ! plutil -lint "$bundle_path/Contents/Info.plist"; then
  echo "Expected valid app bundle Info.plist" >&2
  exit 1
fi
if ! plutil -extract LSUIElement raw "$bundle_path/Contents/Info.plist" | rg -q '^true$'; then
  echo "Expected app bundle to be menu-bar-only via LSUIElement" >&2
  exit 1
fi
if ! plutil -extract CFBundleName raw "$bundle_path/Contents/Info.plist" | rg -q '^Nomas Motion$'; then
  echo "Expected app bundle name to be Nomas Motion" >&2
  exit 1
fi
if ! plutil -extract CFBundleIdentifier raw "$bundle_path/Contents/Info.plist" | rg -q '^app.nomas.motion$'; then
  echo "Expected app bundle identifier to be app.nomas.motion" >&2
  exit 1
fi
if ! plutil -extract CFBundleExecutable raw "$bundle_path/Contents/Info.plist" | rg -q '^NomasMotion$'; then
  echo "Expected app bundle executable to be NomasMotion" >&2
  exit 1
fi
if ! plutil -extract CFBundleIconFile raw "$bundle_path/Contents/Info.plist" | rg -q '^AppIcon$'; then
  echo "Expected app bundle icon file to be AppIcon" >&2
  exit 1
fi
require_artifact "$bundle_path/Contents/Resources/AppIcon.icns" icns
if ! plutil -extract CFBundlePackageType raw "$bundle_path/Contents/Info.plist" | rg -q '^APPL$'; then
  echo "Expected app bundle package type to be APPL" >&2
  exit 1
fi
if ! plutil -extract LSMinimumSystemVersion raw "$bundle_path/Contents/Info.plist" | rg -q '^14\.0$'; then
  echo "Expected app bundle minimum macOS version to be 14.0" >&2
  exit 1
fi
if ! plutil -extract NSHighResolutionCapable raw "$bundle_path/Contents/Info.plist" | rg -q '^true$'; then
  echo "Expected app bundle to be high-resolution capable" >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$bundle_path"; then
  echo "Expected app bundle resources and executable to have a valid local signature" >&2
  exit 1
fi
bundle_exec="$bundle_path/Contents/MacOS/NomasMotion"
bundle_smoke_log="$verify_tmp/bundle-smoke.log"
NOMAS_MOTION_SKIP_LOGIN_ITEM=1 "$bundle_exec" >"$bundle_smoke_log" 2>&1 &
bundle_smoke_pid=$!
smoke_pids+=("$bundle_smoke_pid")
wait_for_process "$bundle_smoke_pid" "bundle" 5
echo "SMOKE_INGESTION=not-applicable component=bundle"
stop_process "$bundle_smoke_pid" "bundle"
smoke_pids=()
if [[ -s "$bundle_smoke_log" ]]; then
  cat "$bundle_smoke_log"
fi
ensure_no_app_processes

echo "==> App launch smoke test"
app_smoke_log="$verify_tmp/app-smoke.log"
NOMAS_MOTION_SKIP_LOGIN_ITEM=1 .build/debug/NomasMotion >"$app_smoke_log" 2>&1 &
app_smoke_pid=$!
smoke_pids+=("$app_smoke_pid")
wait_for_process "$app_smoke_pid" "debug-app" 5
echo "SMOKE_INGESTION=not-applicable component=debug-app"
stop_process "$app_smoke_pid" "debug-app"
smoke_pids=()
if [[ -s "$app_smoke_log" ]]; then
  cat "$app_smoke_log"
fi
ensure_no_app_processes

echo "==> Sensor probe should require admin without sudo"
probe_output="$(.build/debug/NomasMotionSensorProbe 1 2>&1 || true)"
printf '%s\n' "$probe_output"
if [[ "$probe_output" != *"accelerometer access requires root/admin privileges"* ]]; then
  echo "Expected non-root sensor probe to report root/admin requirement" >&2
  exit 1
fi
if [[ "$probe_output" != *"Last sensor startup stage:"* ]]; then
  echo "Expected non-root sensor probe to print last startup stage" >&2
  exit 1
fi

echo "==> Sensor bridge should require admin without sudo"
bridge_output="$(.build/debug/NomasMotionSensorBridge 2>&1 || true)"
printf '%s\n' "$bridge_output"
if [[ "$bridge_output" != *"accelerometer access requires root/admin privileges"* ]]; then
  echo "Expected non-root sensor bridge to report root/admin requirement" >&2
  exit 1
fi
if [[ "$bridge_output" != *"Last sensor startup stage:"* ]]; then
  echo "Expected non-root sensor bridge to print last startup stage" >&2
  exit 1
fi

echo "==> Privileged helper should require launchd/root without sudo"
helper_output="$(.build/debug/NomasMotionPrivilegedHelper 2>&1 || true)"
printf '%s\n' "$helper_output"
if [[ "$helper_output" != *"must run as root via launchd"* ]]; then
  echo "Expected non-root privileged helper to report launchd/root requirement" >&2
  exit 1
fi

echo "==> FIFO app path smoke test"
pipe_path="$verify_tmp/sensor.pipe"
log_path="$verify_tmp/fifo-app.log"
mkfifo "$pipe_path"
NOMAS_MOTION_SENSOR_PIPE="$pipe_path" NOMAS_MOTION_SKIP_LOGIN_ITEM=1 .build/debug/NomasMotion >"$log_path" 2>&1 &
app_pid=$!
smoke_pids+=("$app_pid")
wait_for_process "$app_pid" "fifo-app" 5
{
  printf '0 0 65536\n'
  printf '6553 -3276 65536\n'
  sleep 1
} >"$pipe_path" &
writer_pid=$!
echo "SMOKE_INGESTION=sent component=fifo samples=2"
wait "$writer_pid"
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "SMOKE_INGESTION=failed component=fifo process-exited" >&2
  cat "$log_path" >&2 || true
  exit 1
fi
echo "SMOKE_INGESTION=delivered component=fifo samples=2 process-alive=true"
stop_process "$app_pid" "fifo-app"
smoke_pids=()
if [[ -s "$log_path" ]]; then
  cat "$log_path"
fi
ensure_no_app_processes

echo "==> Noninterruptive visual-QA contract"
visible_launch='NOMAS_MOTION_START_''VISIBLE=1'
forced_demo='synthetic_output=.*run-synthetic-overlay-''demo\.sh'
if rg -n "$visible_launch|$forced_demo" scripts/verify-local.sh; then
  echo "Default verification must not launch a forced-visible overlay" >&2
  exit 1
fi

kvc_prefix='K''VC'
serial_word='[Ss]er''ial'
number_word='[Nn]um''ber'
device_id_pattern="${kvc_prefix}|${serial_word}${number_word}|${serial_word}_${number_word}"

echo "==> Repo device identifier leak check"
if rg -n "$device_id_pattern" . -g '!/.build/**' -g '!/.git/**'; then
  echo "Potential device identifier leak found in repo files" >&2
  exit 1
fi

echo "Local verification passed."
