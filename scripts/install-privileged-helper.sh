#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if (( EUID == 0 )); then
  echo "Run this installer as the logged-in user, without sudo; it requests elevation only for privileged steps." >&2
  exit 1
fi

label="app.nomas.motion.sensor-helper"
helper_name="NomasMotionPrivilegedHelper"
helper_dest="/Library/PrivilegedHelperTools/$label"
plist_dest="/Library/LaunchDaemons/$label.plist"
canonical_socket_path="/var/run/nomas-motion-sensor.sock"
requested_socket_path="${NOMAS_MOTION_SENSOR_SOCKET:-$canonical_socket_path}"
socket_path="$canonical_socket_path"
stdout_log="/var/log/nomas-motion-privileged-helper.out.log"
stderr_log="/var/log/nomas-motion-privileged-helper.err.log"
run_uid="$(id -u)"
tmp_dir=""
root_helper_stage=""
root_plist_stage=""
root_helper_backup=""
root_plist_backup=""
helper_existed=0
plist_existed=0
helper_replaced=0
plist_replaced=0
service_was_loaded=0
service_booted_out=0
service_bootstrapped=0
install_committed=0
rollback_failure_status=125
rollback_failed=0

cleanup() {
  local exit_status=$?
  # Rollback must finish even if the user interrupts a second time.
  trap '' INT TERM
  trap - EXIT ERR
  set +e
  rollback_failed=0
  if (( ! install_committed && ( helper_replaced || plist_replaced || service_booted_out || service_bootstrapped ) )); then
    sudo launchctl bootout "system/$label" >/dev/null 2>&1 || true
    sudo launchctl bootout system "$plist_dest" >/dev/null 2>&1 || true
    if (( helper_replaced )); then
      if (( helper_existed )); then
        sudo install -o root -g wheel -m 544 "$root_helper_backup" "$helper_dest" >/dev/null 2>&1 || rollback_failed=1
      else
        sudo /bin/rm -f "$helper_dest" >/dev/null 2>&1 || rollback_failed=1
      fi
    fi
    if (( plist_replaced )); then
      if (( plist_existed )); then
        sudo install -o root -g wheel -m 644 "$root_plist_backup" "$plist_dest" >/dev/null 2>&1 || rollback_failed=1
      else
        sudo /bin/rm -f "$plist_dest" >/dev/null 2>&1 || rollback_failed=1
      fi
    fi
    if (( service_was_loaded )); then
      sudo launchctl bootstrap system "$plist_dest" >/dev/null 2>&1 || rollback_failed=1
      sudo launchctl kickstart -k "system/$label" >/dev/null 2>&1 || rollback_failed=1
    fi

    if (( helper_replaced )); then
      if (( helper_existed )); then
        sudo cmp -s "$root_helper_backup" "$helper_dest" || rollback_failed=1
      elif sudo /bin/test -e "$helper_dest"; then
        rollback_failed=1
      fi
    fi
    if (( plist_replaced )); then
      if (( plist_existed )); then
        sudo cmp -s "$root_plist_backup" "$plist_dest" || rollback_failed=1
      elif sudo /bin/test -e "$plist_dest"; then
        rollback_failed=1
      fi
    fi
    if (( service_was_loaded )); then
      launchd_service_is_running || rollback_failed=1
    elif sudo launchctl print "system/$label" >/dev/null 2>&1; then
      rollback_failed=1
    fi
  fi

  if (( rollback_failed )); then
    exit_status="$rollback_failure_status"
    echo "Privileged helper rollback incomplete; recovery artifacts were preserved." >&2
    echo "Helper backup: ${root_helper_backup:-none}" >&2
    echo "Plist backup: ${root_plist_backup:-none}" >&2
    echo "Helper staging: ${root_helper_stage:-none}" >&2
    echo "Plist staging: ${root_plist_stage:-none}" >&2
    echo "User staging: ${tmp_dir:-none}" >&2
  else
    if [[ -n "$root_helper_stage" ]]; then
      sudo /bin/rm -f "$root_helper_stage" >/dev/null 2>&1 || true
    fi
    if [[ -n "$root_plist_stage" ]]; then
      sudo /bin/rm -f "$root_plist_stage" >/dev/null 2>&1 || true
    fi
    if [[ -n "$root_helper_backup" ]]; then
      sudo /bin/rm -f "$root_helper_backup" >/dev/null 2>&1 || true
    fi
    if [[ -n "$root_plist_backup" ]]; then
      sudo /bin/rm -f "$root_plist_backup" >/dev/null 2>&1 || true
    fi
    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
      /bin/rm -rf "$tmp_dir" >/dev/null 2>&1 || true
    fi
  fi
  if (( ! rollback_failed && exit_status == rollback_failure_status )); then
    # Reserve 125 for a rollback that this script actually detected as bad.
    exit_status=1
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    echo "Refusing to replace non-socket at $socket_path" >&2
    exit 1
  fi
}

validate_socket_parent() {
  local parent_path parent_uid parent_mode parent_type
  parent_path="$(dirname "$socket_path")"
  parent_uid="$(stat -f '%u' "$parent_path")"
  parent_mode="$(stat -f '%Lp' "$parent_path")"
  parent_type="$(stat -f '%HT' "$parent_path")"
  if [[ "$parent_type" != "Directory" || "$parent_uid" != "0" || $((8#$parent_mode & 2)) -ne 0 ]]; then
    echo "Socket parent must be a root-owned directory without world write access: $parent_path" >&2
    exit 1
  fi
}

if [[ "$requested_socket_path" != "$canonical_socket_path" ]]; then
  echo "NOMAS_MOTION_SENSOR_SOCKET must be the canonical path: $canonical_socket_path" >&2
  exit 1
fi

validate_log_path() {
  local log_path="$1"
  if [[ -L "$log_path" ]]; then
    echo "Refusing to use symlinked LaunchDaemon log path: $log_path" >&2
    exit 1
  fi
  if [[ -e "$log_path" && ! -f "$log_path" ]]; then
    echo "Refusing to use non-file LaunchDaemon log path: $log_path" >&2
    exit 1
  fi
}

xml_escape() {
  /usr/bin/sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

bootout_helper() {
  local helper_pids
  # Record the attempted bootout before asking launchd to mutate service state,
  # so EXIT cleanup can restore the previous service after a partial failure.
  service_booted_out=1
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

validate_existing_plist() {
  if [[ -L "$plist_dest" ]]; then
    echo "Refusing to replace symlink at $plist_dest" >&2
    exit 1
  fi
  if [[ ! -e "$plist_dest" ]]; then
    return 0
  fi
  local installed_label
  installed_label="$(plutil -extract Label raw "$plist_dest" 2>/dev/null || true)"
  if [[ "$installed_label" != "$label" ]]; then
    echo "Refusing to replace LaunchDaemon with unexpected label at $plist_dest: ${installed_label:-unknown}" >&2
    exit 1
  fi
}

validate_existing_helper() {
  if [[ -L "$helper_dest" ]]; then
    echo "Refusing to replace symlink at $helper_dest" >&2
    exit 1
  fi
  if [[ -e "$helper_dest" && ! -f "$helper_dest" ]]; then
    echo "Refusing to replace non-file at $helper_dest" >&2
    exit 1
  fi
}

verify_file_properties() {
  local path="$1"
  local description="$2"
  local expected_owner="$3"
  local expected_group="$4"
  local expected_mode="$5"
  local properties owner group mode group_and_mode

  if [[ -L "$path" || ! -f "$path" ]]; then
    echo "Expected installed $description to be a regular file: $path" >&2
    return 1
  fi
  properties="$(sudo /usr/bin/stat -f '%Su:%Sg:%OLp' "$path" 2>/dev/null || true)"
  owner="${properties%%:*}"
  group_and_mode="${properties#*:}"
  group="${group_and_mode%%:*}"
  mode="${group_and_mode#*:}"
  if [[ "$owner" != "$expected_owner" || "$group" != "$expected_group" || ( "$mode" != "$expected_mode" && "$mode" != "0$expected_mode" ) ]]; then
    echo "Unexpected $description properties at $path: got ${properties:-unknown}, expected $expected_owner:$expected_group:$expected_mode" >&2
    return 1
  fi
}

verify_plist_value() {
  local key_path="$1"
  local expected="$2"
  local actual

  actual="$(plutil -extract "$key_path" raw "$plist_dest" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected LaunchDaemon plist value for $key_path: got ${actual:-missing}, expected $expected" >&2
    return 1
  fi
}

verify_installed_helper() {
  verify_file_properties "$helper_dest" "privileged helper" root wheel 544 || return 1
  verify_file_properties "$plist_dest" "LaunchDaemon plist" root wheel 644 || return 1
  verify_plist_value Label "$label" || return 1
  verify_plist_value ProgramArguments.0 "$helper_dest" || return 1
  verify_plist_value ProgramArguments.1 "$socket_path" || return 1
  verify_plist_value ProgramArguments.2 "$run_uid" || return 1
  verify_plist_value RunAtLoad true || return 1
  verify_plist_value KeepAlive true || return 1
  verify_plist_value ThrottleInterval 5 || return 1
  verify_plist_value StandardOutPath "$stdout_log" || return 1
  verify_plist_value StandardErrorPath "$stderr_log" || return 1
  if ! cmp -s "$helper_build" "$helper_dest"; then
    echo "Installed helper bytes do not match the verified release build" >&2
    return 1
  fi
  if ! cmp -s "$tmp_plist" "$plist_dest"; then
    echo "Installed LaunchDaemon plist does not match the generated configuration" >&2
    return 1
  fi
}

verify_socket_properties() {
  local properties socket_uid group_and_mode socket_group socket_mode

  if [[ ! -S "$socket_path" ]]; then
    echo "Expected helper socket at $socket_path" >&2
    echo "Helper stderr log: $stderr_log" >&2
    sudo tail -n 80 "$stderr_log" 2>/dev/null || true
    return 1
  fi

  properties="$(sudo /usr/bin/stat -f '%u:%Sg:%OLp' "$socket_path" 2>/dev/null || true)"
  socket_uid="${properties%%:*}"
  group_and_mode="${properties#*:}"
  socket_group="${group_and_mode%%:*}"
  socket_mode="${group_and_mode#*:}"
  if [[ "$socket_uid" != "$run_uid" ]]; then
    echo "Helper socket has unexpected owner UID at $socket_path: got ${socket_uid:-unknown}, expected $run_uid" >&2
    return 1
  fi
  if [[ "$socket_mode" != 600 && "$socket_mode" != 0600 ]]; then
    echo "Helper socket is not private at $socket_path: got ${socket_group:-unknown}:$socket_mode, expected mode 0600" >&2
    return 1
  fi
}

launchd_service_is_running() {
  local service_status

  service_status="$(sudo launchctl print "system/$label" 2>/dev/null || true)"
  [[ -n "$service_status" ]] || return 1
  printf '%s\n' "$service_status" | /usr/bin/grep -Eq '^[[:space:]]*state = running[[:space:]]*$'
}

probe_unix_socket() {
  # nc -U -z is not reliable on all macOS releases. Ruby's UnixSocket
  # constructor performs a real connect and close without writing data.
  if ! sudo -u "#$run_uid" /usr/bin/ruby -rsocket -e \
    'UNIXSocket.new(ARGV.fetch(0)).close' "$socket_path"; then
    echo "Could not actively connect to helper socket at $socket_path" >&2
    return 1
  fi
}

validate_socket_path
validate_socket_parent
validate_existing_plist
validate_existing_helper
validate_log_path "$stdout_log"
validate_log_path "$stderr_log"
escaped_socket_path="$(printf '%s' "$socket_path" | xml_escape)"
escaped_run_uid="$(printf '%s' "$run_uid" | xml_escape)"

if [[ ! -t 0 ]]; then
  cat >&2 <<'ERROR'
scripts/install-privileged-helper.sh must be run from an interactive terminal.

It asks sudo for the admin password while installing the LaunchDaemon.
Run it directly in Terminal from the repository root:

  scripts/install-privileged-helper.sh
ERROR
  exit 1
fi

echo "==> Build privileged helper"
swift build -c release -Xswiftc -warnings-as-errors --product "$helper_name"
helper_build=".build/release/$helper_name"

echo "==> Sign helper"
/usr/bin/codesign --force --sign - "$helper_build"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nomas-motion-helper.XXXXXX")"
chmod 700 "$tmp_dir"
tmp_plist="$tmp_dir/$label.plist"

cat >"$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper_dest</string>
    <string>$escaped_socket_path</string>
    <string>$escaped_run_uid</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$stdout_log</string>
  <key>StandardErrorPath</key>
  <string>$stderr_log</string>
</dict>
</plist>
PLIST
plutil -lint "$tmp_plist"

helper_changed=1
plist_changed=1
if [[ -f "$helper_dest" ]] && cmp -s "$helper_build" "$helper_dest"; then
  helper_changed=0
fi
if [[ -f "$plist_dest" ]] && cmp -s "$tmp_plist" "$plist_dest"; then
  plist_changed=0
fi
if sudo launchctl print "system/$label" >/dev/null 2>&1; then
  service_was_loaded=1
fi

echo "==> Install and start helper"
sudo mkdir -p /Library/PrivilegedHelperTools
sudo mkdir -p /Library/LaunchDaemons

if (( helper_changed || plist_changed )); then
  root_helper_stage="$(sudo mktemp "${helper_dest}.XXXXXX")"
  root_plist_stage="$(sudo mktemp "${plist_dest}.XXXXXX")"
  # Feed root-owned staging files through shell-opened descriptors. This
  # prevents a later privileged copy from re-reading a user-writable path.
  sudo /usr/bin/tee "$root_helper_stage" <"$helper_build" >/dev/null
  sudo chown root:wheel "$root_helper_stage"
  sudo chmod 544 "$root_helper_stage"
  sudo /usr/bin/tee "$root_plist_stage" <"$tmp_plist" >/dev/null
  sudo chown root:wheel "$root_plist_stage"
  sudo chmod 644 "$root_plist_stage"
  if [[ -f "$helper_dest" ]]; then
    helper_existed=1
    root_helper_backup="$(sudo mktemp "${helper_dest}.backup.XXXXXX")"
    sudo /bin/cp -p "$helper_dest" "$root_helper_backup"
  fi
  if [[ -f "$plist_dest" ]]; then
    plist_existed=1
    root_plist_backup="$(sudo mktemp "${plist_dest}.backup.XXXXXX")"
    sudo /bin/cp -p "$plist_dest" "$root_plist_backup"
  fi
  bootout_helper
  helper_replaced=1
  sudo mv -f "$root_helper_stage" "$helper_dest"
  root_helper_stage=""
  plist_replaced=1
  sudo mv -f "$root_plist_stage" "$plist_dest"
  root_plist_stage=""
else
  echo "Helper binary and LaunchDaemon plist are unchanged."
fi

service_loaded=0
if sudo launchctl print "system/$label" >/dev/null 2>&1; then
  service_loaded=1
fi
if (( ! service_loaded )); then
  # Mark before bootstrap so a partial launchd mutation is rolled back by EXIT.
  service_bootstrapped=1
  sudo launchctl bootstrap system "$plist_dest"
  service_loaded=1
fi
if (( ! service_bootstrapped )) && [[ ! -S "$socket_path" ]]; then
  sudo launchctl kickstart -k "system/$label"
fi

echo "==> Verify helper"
sleep 2
if ! launchd_service_is_running; then
  sudo launchctl kickstart -k "system/$label"
  sleep 1
fi
if ! launchd_service_is_running; then
  echo "Expected launchd service system/$label to be running" >&2
  sudo tail -n 80 "$stderr_log" 2>/dev/null || true
  exit 1
fi
verify_installed_helper
verify_socket_properties
probe_unix_socket

# From here onward the installed helper is verified and must remain paired
# with the app selected by the parent transaction. Defer late signals until
# this script has returned success to the parent.
trap ':' INT TERM
echo "Privileged helper ready."
echo "Socket: $socket_path"
echo "Logs: $stderr_log"
install_committed=1
