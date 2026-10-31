#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if (( EUID == 0 )); then
  echo "Run this installer as the logged-in user, without sudo; it requests elevation only for privileged steps." >&2
  exit 1
fi

app_name="Nomas Motion"
app_dest="/Applications/${app_name}.app"
bundle_id="app.nomas.motion"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"
requested_socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-$canonical_socket_path}"
log_path="/tmp/nomas-motion-install.log"
started_at="$SECONDS"
current_step="initializing"
install_as_root=0
install_stage_dir=""
install_backup_path=""
install_backup_ready=0
installed_new_bundle=0
install_transaction_committed=0
parent_signal_status=0
helper_rollback_unverified=0
rollback_failure_status=125
rollback_failed=0
failure_status_override=0

if [[ "$requested_socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

fail() {
  local status="$?"
  if (( failure_status_override != 0 )); then
    status="$failure_status_override"
  fi
  trap - ERR
  set +e
  echo
  echo "Install failed during: $current_step" >&2
  echo "Log: $log_path" >&2
  if [[ -s "$log_path" ]]; then
    echo >&2
    tail -n 80 "$log_path" >&2 || true
  fi
  exit "$status"
}
trap fail ERR

cleanup_on_exit() {
  local status="$?"
  # Do not let a second interrupt abort restoration midway through a failed
  # install. After helper commit, app/helper already form one valid version.
  trap '' INT TERM
  trap - EXIT ERR
  set +e
  if (( helper_rollback_unverified )); then
    echo "Privileged helper rollback is unverified; preserving the new app and recovery artifacts." >&2
    echo "App: $app_dest" >&2
    echo "App backup: ${install_backup_path:-none}" >&2
    echo "App staging: ${install_stage_dir:-none}" >&2
    status="$rollback_failure_status"
  elif (( status != 0 && ! install_transaction_committed )); then
    if ! rollback_install; then
      status="$rollback_failure_status"
      echo "App rollback incomplete; recovery artifacts were preserved." >&2
      echo "App backup: ${install_backup_path:-none}" >&2
      echo "App staging: ${install_stage_dir:-none}" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rollback_install() {
  rollback_failed=0

  if [[ -n "$install_stage_dir" ]]; then
    if (( install_as_root )); then
      sudo /bin/rm -rf "$install_stage_dir" >/dev/null 2>&1 || rollback_failed=1
    else
      /bin/rm -rf "$install_stage_dir" >/dev/null 2>&1 || rollback_failed=1
    fi
  fi
  if (( install_backup_ready )) && [[ -n "$install_backup_path" && ( -e "$install_backup_path" || -L "$install_backup_path" ) ]]; then
    app_dest_removed=1
    if [[ -e "$app_dest" || -L "$app_dest" ]]; then
      if (( install_as_root )); then
        sudo /bin/rm -rf "$app_dest" >/dev/null 2>&1 || app_dest_removed=0
      else
        /bin/rm -rf "$app_dest" >/dev/null 2>&1 || app_dest_removed=0
      fi
    fi
    if (( app_dest_removed )); then
      if (( install_as_root )); then
        sudo /bin/mv "$install_backup_path" "$app_dest" >/dev/null 2>&1 || rollback_failed=1
      else
        /bin/mv "$install_backup_path" "$app_dest" >/dev/null 2>&1 || rollback_failed=1
      fi
    else
      rollback_failed=1
    fi
  elif [[ -n "$install_backup_path" && ( -e "$install_backup_path" || -L "$install_backup_path" ) ]]; then
    echo "Warning: preserving unexpected app backup: $install_backup_path" >&2
    rollback_failed=1
  elif (( installed_new_bundle )) && [[ -e "$app_dest" ]]; then
    if (( install_as_root )); then
      sudo /bin/rm -rf "$app_dest" >/dev/null 2>&1 || rollback_failed=1
    else
      /bin/rm -rf "$app_dest" >/dev/null 2>&1 || rollback_failed=1
    fi
  fi

  return "$rollback_failed"
}

require_interactive_admin() {
  local reason="$1"
  if [[ -t 0 ]]; then
    return 0
  fi
  cat >&2 <<ERROR
scripts/install-local-app.sh must be run from an interactive terminal.

This install needs sudo for: $reason

Run it directly in Terminal from the repository root:

  scripts/install-local-app.sh
ERROR
  exit 1
}

: >"$log_path"

run_logged() {
  "$@" >>"$log_path" 2>&1
}

run_sudo_logged() {
  sudo "$@" 2>&1 | /usr/bin/tee -a "$log_path" >/dev/null
}

require_interactive_admin "synchronizing the sensor LaunchDaemon"

if [[ -L "$app_dest" ]]; then
  echo "Refusing to operate on symlink at $app_dest" >&2
  exit 1
fi
if [[ -e "$app_dest" && ! -d "$app_dest" ]]; then
  echo "Refusing to overwrite non-directory at $app_dest" >&2
  exit 1
fi
if [[ -d "$app_dest" ]]; then
  existing_bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_dest/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "$bundle_id" ]]; then
    echo "Refusing to overwrite existing app with different bundle id at $app_dest: ${existing_bundle_id:-unknown}" >&2
    exit 1
  fi
fi

if [[ ! -w /Applications || ( -e "$app_dest" && ! -w "$app_dest" ) ]]; then
  install_as_root=1
  require_interactive_admin "installing ${app_dest}"
fi

echo "==> Stop stale app processes"
current_step="stopping stale NomasMotion processes"
run_logged scripts/stop-local-app.sh

echo "==> Building app bundle"
current_step="building app bundle"
run_logged scripts/build-app-bundle.sh
bundle_path="dist/${app_name}.app"

echo "==> Installing app to /Applications"
current_step="installing ${app_dest}"
if (( install_as_root )); then
  install_stage_dir="$(sudo mktemp -d '/Applications/.nomas-motion-install.XXXXXX')"
else
  install_stage_dir="$(mktemp -d '/Applications/.nomas-motion-install.XXXXXX')"
fi
staged_bundle="$install_stage_dir/$app_name.app"
install_backup_path="$install_stage_dir.backup"
if (( install_as_root )); then
  run_sudo_logged /usr/bin/ditto "$bundle_path" "$staged_bundle"
else
  run_logged /usr/bin/ditto "$bundle_path" "$staged_bundle"
fi
staged_bundle_id="$(plutil -extract CFBundleIdentifier raw "$staged_bundle/Contents/Info.plist")"
if [[ "$staged_bundle_id" != "$bundle_id" ]]; then
  echo "Built bundle has unexpected identifier: ${staged_bundle_id:-unknown}" >&2
  false
fi
/usr/bin/codesign --verify --deep --strict "$staged_bundle"

if [[ -d "$app_dest" ]]; then
  echo "==> Atomically swapping the existing app bundle"
  if [[ -e "$install_backup_path" || -L "$install_backup_path" ]]; then
    echo "Refusing to reuse existing install backup path: $install_backup_path" >&2
    false
  fi
  # Mark the backup as potentially present before mv. A signal can arrive
  # after the filesystem mutation but before the command returns.
  install_backup_ready=1
  if (( install_as_root )); then
    run_sudo_logged /bin/mv "$app_dest" "$install_backup_path"
    run_sudo_logged /bin/mv "$staged_bundle" "$app_dest"
  else
    run_logged /bin/mv "$app_dest" "$install_backup_path"
    run_logged /bin/mv "$staged_bundle" "$app_dest"
  fi
else
  echo "==> Staging new app bundle"
  # Likewise, rollback must treat the destination as ours before mv starts.
  installed_new_bundle=1
  if (( install_as_root )); then
    run_sudo_logged /bin/mv "$staged_bundle" "$app_dest"
  else
    run_logged /bin/mv "$staged_bundle" "$app_dest"
  fi
fi
/usr/bin/codesign --verify --deep --strict "$app_dest"
installed_bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_dest/Contents/Info.plist")"
if [[ "$installed_bundle_id" != "$bundle_id" ]]; then
  echo "Installed bundle has unexpected identifier: ${installed_bundle_id:-unknown}" >&2
  false
fi
echo "==> Synchronizing sensor helper"
current_step="synchronizing privileged helper"
# Defer parent signals across the child install's verified commit and this
# transaction marker. The child retains its own signal-aware rollback.
trap 'parent_signal_status=130' INT
trap 'parent_signal_status=143' TERM
helper_status=0
run_logged scripts/install-privileged-helper.sh || helper_status=$?
if (( helper_status != 0 )); then
  if (( helper_status == rollback_failure_status )); then
    helper_rollback_unverified=1
  fi
  failure_status_override="$helper_status"
  false
fi

# The app/helper transaction is committed. Cleanup is best-effort so a stale
# backup cannot trigger ERR rollback and restore the old app after the helper
# has been updated.
install_transaction_committed=1
install_backup_ready=0
installed_new_bundle=0
if [[ -e "$install_backup_path" || -L "$install_backup_path" ]]; then
  if (( install_as_root )); then
    run_sudo_logged /bin/rm -rf "$install_backup_path" || true
  else
    run_logged /bin/rm -rf "$install_backup_path" || true
  fi
fi
install_backup_path=""
if (( install_as_root )); then
  run_sudo_logged /bin/rm -rf "$install_stage_dir" || true
else
  run_logged /bin/rm -rf "$install_stage_dir" || true
fi
install_stage_dir=""

elapsed=$((SECONDS - started_at))

cat <<READY
==> Ready (${elapsed}s)

Installed:
  $app_dest

Next:
  open -a "Nomas Motion"
READY

# A signal sent only to this parent is deferred until app and helper are a
# consistent pair, then surfaced to the caller instead of being swallowed.
trap '' INT TERM
final_status="$parent_signal_status"
trap - EXIT ERR
if (( final_status != 0 )); then
  echo "Install committed safely; a signal was deferred until the transaction completed." >&2
  exit "$final_status"
fi
