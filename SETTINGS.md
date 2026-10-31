# Settings

Open the Settings page from the Nomas Motion menu-bar icon:

1. Click the Nomas Motion menu-bar icon.
2. Choose **Settings...**.

The settings window opens centered. Each tunable value has five bounded presets: **Min**, **Less**, **Default**, **More**, and **Max**. The numeric field on the right is an advanced override; values outside the allowed range are clamped before they are applied. Tuning and dot-color selections are persisted for the next launch.

The preview on the right is synthetic, so changes are visible without needing a real ride. Production uses four mirrored side tracks at 2.5%, 7.5%, 12.5%, and 17.5% of the display width from each edge: staggered six-row tracks, 48 logical dots (24 per side), one shared phase, horizontal wrap with fading seam copies inside the rails, vertical wrap, and a clear center. **Restore Defaults** immediately reapplies every tuning control's `.defaults` value, resets automatic qualification evidence, and resets dot color to **Gray dots**. It does not erase Statistics.

The default filters smooth the motion signal. Rail speed, deadbands, size, and opacity remain separate comfort controls:

- **Activation threshold**: transient acceleration in m/s^2 required to fire movement.
- **Response speed**: how quickly the filtered cue responds to motion.
- **Speed multiplier**: side-rail phase-speed scale; the default is `1.0`.
- **Horizontal / forward-brake motion**: side-rail deadbands, scaling, and speed caps in points per second. These cap phase velocity; they are not maximum-displacement settings. Small sensor noise is discarded before the 48 logical dots move.
- **Auto sensitivity**: MacBook motion threshold; the default is `0.020 g`.
- **Auto show delay**: accumulated meaningful, fresh motion before display; the default is `15 s` and is observed at `10 Hz`.
- **Auto hide quiet**: no-motion latch after automatic display; the default is `120 s` so a traffic light does not immediately hide the cues.
