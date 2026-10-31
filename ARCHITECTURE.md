# Architecture

Nomas Motion runs as a macOS menu-bar app. It reads motion from the MacBook, filters the samples, and moves a peripheral overlay. The app, settings, statistics, and motion gate run locally.

## Data flow

```text
System motion input       Sensor helper / test FIFO
        |                             |
        +---------- MotionProcessor --+
                          |
                 freshness-bounded cue
                          |
              +-----------+------------+
              |           |            |
       OverlayController  Travel gate  Trip statistics
              |
       SideRailRenderer
```

The app tries system motion input first. When that input is unavailable, an ordinary user process waits for the sensor helper and reconnects when it appears. Direct IOKit access is limited to privileged diagnostic runs.

## Targets

| Target | Responsibility |
|---|---|
| `CAccelerometer` | IOKit accelerometer access and Unix socket helpers |
| `NomasMotionCore` | Samples, filtering, transport, automatic activation, settings, and statistics |
| `NomasMotionOverlay` | Peripheral geometry, rendering, and overlay window |
| `NomasMotion` | Menu, settings UI, sensor selection, and app lifecycle |
| `NomasMotionPrivilegedHelper` | Read the accelerometer and stream samples to the app |
| `NomasMotionSensorProbe` | Bounded sensor diagnostics |
| `NomasMotionSensorBridge` | Sensor-to-FIFO diagnostics |
| `NomasMotionVerify` | Offscreen overlay snapshots |

## Motion and rendering

`MotionProcessor` removes orientation and slowly changing bias from the motion signal, filters it, and produces a `VehicleMotionCue`. Every continuous consumer uses a cue with a maximum sample age of 0.5 seconds. A disconnected sensor therefore cannot leave a retained motion value driving the overlay or the travel gate.

`OverlayController` integrates the cue into a shared phase. `SideRailRenderer` projects 48 logical dots into four mirrored tracks on each side, at 2.5%, 7.5%, 12.5%, and 17.5% of display width. Every track has six evenly spaced rows. Alternate tracks have a half-row stagger, including across vertical wrapping.

Horizontal wrapping can draw fading copies of a logical dot at the rail boundary. The center remains clear at every phase. Rendering targets the built-in display and uses a transparent, click-through window.

## Automatic activation

The app starts with cues hidden. `TravelAutoDetector` checks fresh motion at 10 Hz and accumulates qualifying movement across acceleration, braking, and turns. Defaults are 15 seconds of evidence above 0.020 g to show cues and 120 quiet seconds to hide them. Repeated timer ticks cannot reuse an old sample as new evidence.

Manual Show/Hide Cues is separate from Automatic Cues. Quitting stops timers and sensor readers. The login item starts the app at the next login; the sensor helper does not relaunch the app after a quit.

## Sensor transport

The helper listens at `/var/run/nomas-motion-sensor.sock`. The socket belongs to the logged-in user and has mode `0600`. The helper validates the connecting user's identity.

The wire format is one newline-delimited Q16 sample:

```text
rawX rawY rawZ
```

Dividing each value by 65536 gives acceleration in g. `SensorLineBuffer` handles framing, oversized lines, and partial reads. Socket readers reconnect after outages and stop promptly during shutdown.

`NOMAS_MOTION_SENSOR_PIPE` selects a FIFO for controlled tests. `NOMAS_MOTION_DISABLE_SYSTEM_DEVICE_MOTION=1` exercises helper fallback. These are diagnostic settings, not normal setup requirements.

## Installation and validation

`scripts/install-local-app.sh` builds the app, installs it in `/Applications`, and installs the sensor helper. It requests elevation for privileged filesystem and service operations; the app itself runs as the user. App and helper updates are transactional, with rollback on failure.

The app requests Login Item registration when launched from its installed bundle. Settings and trip history are stored locally. See [Settings](SETTINGS.md), [Statistics](STATISTICS.md), and [Contributing](CONTRIBUTING.md).

Run `scripts/verify-local.sh` for build, XCTest, offscreen snapshots, and bounded startup/shutdown checks. The tests cover rail geometry, wrapping, center clearance, motion direction, quiet periods, stale samples, helper recovery, and shutdown.
