#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

app_name="Nomas Motion"
bundle_path="dist/${app_name}.app"
bundle_parent="dist"
staging_dir=""
backup_path=""
staged_bundle=""

rollback_bundle() {
  local status="$?"
  trap - EXIT
  if (( status != 0 )); then
    if [[ -n "$staging_dir" ]]; then
      /bin/rm -rf "$staging_dir" >/dev/null 2>&1 || true
    fi
    if [[ -n "$backup_path" && ( -e "$backup_path" || -L "$backup_path" ) ]]; then
      if [[ -e "$bundle_path" || -L "$bundle_path" ]]; then
        /bin/rm -rf "$bundle_path" >/dev/null 2>&1 || true
      fi
      /bin/mv "$backup_path" "$bundle_path" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap rollback_bundle EXIT

mkdir -p "$bundle_parent"
if [[ -L "$bundle_path" ]]; then
  echo "Refusing to replace symlink at $bundle_path" >&2
  exit 1
fi
staging_dir="$(mktemp -d "$bundle_parent/.nomas-motion-bundle.XXXXXX")"
staged_bundle="$staging_dir/${app_name}.app"
contents_path="${staged_bundle}/Contents"
macos_path="${contents_path}/MacOS"
resources_path="${contents_path}/Resources"
plist_path="${contents_path}/Info.plist"
iconset_path="${resources_path}/AppIcon.iconset"
icns_path="${resources_path}/AppIcon.icns"

echo "==> Build Nomas Motion"
swift build -c release -Xswiftc -warnings-as-errors

echo "==> Create ${bundle_path}"
mkdir -p "$macos_path"
mkdir -p "$resources_path"
cp .build/release/NomasMotion "$macos_path/NomasMotion"

echo "==> Create app icon"
swift scripts/render-app-icon.swift "$iconset_path"
/usr/bin/iconutil -c icns "$iconset_path" -o "$icns_path"
/bin/rm -rf "$iconset_path"

cat >"$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>NomasMotion</string>
  <key>CFBundleIdentifier</key>
  <string>app.nomas.motion</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Nomas Motion</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$macos_path/NomasMotion"
/usr/bin/codesign --force --deep --sign - "$staged_bundle"

if [[ -e "$bundle_path" ]]; then
  backup_path="$staging_dir.backup"
  /bin/mv "$bundle_path" "$backup_path"
fi
/bin/mv "$staged_bundle" "$bundle_path"
if [[ -n "$backup_path" ]]; then
  /bin/rm -rf "$backup_path"
fi
/bin/rm -rf "$staging_dir"
staging_dir=""
backup_path=""

echo "${bundle_path}"
