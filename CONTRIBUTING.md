# Contributing

Thanks for helping improve Nomas Motion. This is a **local macOS OSS MVP**: it needs admin/root for live accelerometer access and is not aimed at App Store distribution.

## Prerequisites

- macOS 14+ (Apple Silicon MacBook with SPU accelerometer for live sensor work).
- Full Xcode with the Swift 6.3+ toolchain. Command Line Tools alone cannot run
  the authoritative XCTest suites.

## Quick setup

```bash
swift build
scripts/verify-local.sh
```

`verify-local.sh` builds all targets, requires and runs every XCTest target,
runs offscreen overlay snapshots,
validates generated artifact types and sizes, performs bounded headless
bundle/FIFO startup checks, and runs non-interactive script checks. XCTest is
the authoritative production behavior suite; the CLI must not duplicate those
assertions. The script writes generated artifacts below a temporary directory
and removes them on exit. It never launches a forced-visible overlay or
registers a login item.

Open the package in Xcode with `open Package.swift`.

## Offscreen snapshots

```bash
swift test
.build/debug/NomasMotionVerify snapshot /tmp/nomas-motion-overlay.png dark 0 0
```

XCTest covers production behavior. The snapshot command renders the overlay into an image without opening a window. Use `light` for a light background and the final two arguments for horizontal and vertical phase offsets.

## Project layout

| Path | Role |
|------|------|
| `Sources/NomasMotionCore/` | Motion math, sensor wire format (Foundation only) |
| `Sources/NomasMotionOverlay/` | AppKit overlay rendering |
| `Sources/NomasMotion/` | Menu-bar app |
| `Tests/` | XCTest (`NomasMotionAppTests`, `NomasMotionCoreTests`, `NomasMotionOverlayTests`) |
| `Sources/NomasMotionPrivilegedHelper/` | Root helper → Unix socket |
| `Sources/NomasMotionSensorProbe/` | Live sensor diagnostic |
| `Sources/NomasMotionSensorBridge/` | FIFO diagnostic bridge |
| `Sources/NomasMotionVerify/` | Offscreen snapshot CLI; production behavior is covered by XCTest |
| `Sources/CAccelerometer/` | IOKit C bridge |
| `scripts/` | Install, uninstall, verify, and local app run helpers |

See [ARCHITECTURE.md](ARCHITECTURE.md).

## Making changes

- Prefer small, focused diffs. Match existing naming and file style.
- Run `scripts/verify-local.sh` before opening a PR.
- Do not commit secrets, ride logs with personal data, or generated `.build/` / `dist/` output.
- Medical claims: avoid strong clinical wording in user-facing copy (enforced by verify-local).

## Install path for manual testing

```bash
scripts/install-local-app.sh
open -a "Nomas Motion"
```

Uninstall: `scripts/uninstall-local-app.sh`; it unregisters the login item before
removing the helper and app bundle.

For helper-only diagnostics, use `scripts/install-privileged-helper.sh`.

## License

MIT — see [LICENSE](LICENSE).
