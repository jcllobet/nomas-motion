import AppKit
import CoreGraphics
import Foundation
import NomasMotionCore

@MainActor
public final class OverlayController {
    private static let maximumRenderSampleAge: TimeInterval = 0.5

    private let processor: MotionProcessor
    private var window: NSWindow?
    private var overlayView: DotOverlayView?
    private var timer: Timer?
    private var scrollPhase = CGSize.zero
    private var lastFrameAt: Date?

    public var tuning: NomasMotionTuning {
        didSet {
            processor.applyTuning(tuning)
            overlayView?.tuning = tuning
        }
    }

    public var dotColorMode = DotColorMode.gray {
        didSet { overlayView?.dotColorMode = dotColorMode }
    }

    public init(
        processor: MotionProcessor,
        dotColorMode: DotColorMode = .gray,
        tuning: NomasMotionTuning = .defaults
    ) {
        self.processor = processor
        self.dotColorMode = dotColorMode
        self.tuning = tuning
        processor.applyTuning(tuning)
    }

    public var isVisible: Bool { window?.isVisible == true }

    /// Convert the filtered cue to a bounded screen-space velocity. The view
    /// never sees raw accelerometer jitter.
    nonisolated public static func dotVelocity(
        for cue: VehicleMotionCue,
        preset: MotionVisualPreset = .mvp
    ) -> CGSize {
        CGSize(
            width: dampedOffset(
                value: cue.screenX,
                gain: preset.horizontalGain * max(0.0, preset.motionSpeedScale),
                deadband: preset.horizontalDeadband,
                maxOffset: preset.horizontalMaxOffset
            ),
            height: dampedOffset(
                value: cue.screenY,
                gain: preset.verticalGain * max(0.0, preset.motionSpeedScale),
                deadband: preset.verticalDeadband,
                maxOffset: preset.verticalMaxOffset
            )
        )
    }

    nonisolated public static func dotVelocity(
        for cue: VehicleMotionCue,
        tuning: NomasMotionTuning
    ) -> CGSize {
        dotVelocity(for: cue, preset: tuning.visualPreset)
    }

    nonisolated private static func dampedOffset(
        value: Double,
        gain: Double,
        deadband: Double,
        maxOffset: Double
    ) -> Double {
        let magnitude = abs(value)
        guard magnitude > deadband else { return 0.0 }
        let offset = (magnitude - deadband) * gain
        let signed = value < 0.0 ? -offset : offset
        return max(-maxOffset, min(maxOffset, signed))
    }

    public func show() {
        if window == nil { createWindow() }
        guard window != nil else { return }
        guard reframeWindowIfNeeded() else { return }
        // Prime the side-only frame before the window becomes visible. This
        // prevents a stale/empty full-screen flash on re-entry.
        renderFrame()
        startDisplayLink()
        window?.orderFrontRegardless()
    }

    public func hide() {
        timer?.invalidate()
        timer = nil
        lastFrameAt = nil
        scrollPhase = .zero
        overlayView?.resetVisualState()
        window?.orderOut(nil)
    }

    private func createWindow() {
        guard let screen = preferredScreen() else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let view = DotOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.dotColorMode = dotColorMode
        view.tuning = tuning
        view.autoresizingMask = [.width, .height]

        window.contentView = view
        Self.configureOverlayWindow(window)

        self.window = window
        overlayView = view
    }

    public static func configureOverlayWindow(_ window: NSWindow) {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: isBuiltInDisplay) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(screenNumber.uint32Value)) != 0
    }

    @discardableResult
    private func reframeWindowIfNeeded() -> Bool {
        guard let window else { return false }
        guard let screen = preferredScreen() else {
            // A display can disappear during hot-unplug, sleep, or Space
            // reconfiguration. Do not leave a stale transparent window or
            // its timer alive while there is nowhere safe to draw.
            hide()
            return false
        }
        guard window.frame != screen.frame else { return true }
        window.setFrame(screen.frame, display: false)
        overlayView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        return true
    }

    private func startDisplayLink() {
        timer?.invalidate()
        lastFrameAt = nil
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.renderFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func renderFrame() {
        guard reframeWindowIfNeeded() else { return }

        let now = Date()
        let dt = min(
            max(now.timeIntervalSince(lastFrameAt ?? now.addingTimeInterval(-1.0 / 60.0)), 1.0 / 240.0),
            1.0 / 15.0
        )
        lastFrameAt = now

        let cue = processor.currentCue(maximumSampleAge: Self.maximumRenderSampleAge)
        let velocity = Self.dotVelocity(for: cue, tuning: tuning)
        let integrated = Self.integrateMotionOffset(offset: scrollPhase, velocity: velocity, dt: dt)
        scrollPhase = if let bounds = overlayView?.bounds {
            SideRailRenderer.boundedPhase(integrated, in: bounds)
        } else {
            integrated
        }
        overlayView?.updateSideRailFrame(motionOffset: scrollPhase)
    }

    nonisolated public static func integrateMotionOffset(
        offset: CGSize,
        velocity: CGSize,
        dt: Double
    ) -> CGSize {
        let elapsed = max(0.0, dt.isFinite ? dt : 0.0)
        return CGSize(
            width: offset.width + velocity.width * elapsed,
            height: offset.height + velocity.height * elapsed
        )
    }

}
