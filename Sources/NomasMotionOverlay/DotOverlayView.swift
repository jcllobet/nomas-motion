import AppKit
import Foundation
import NomasMotionCore

public enum DotColorMode: Int, CaseIterable, Sendable {
    case gray = 0
    case black
    case white
}

/// The shipping frame contains only geometry and opacity. Radius is derived
/// by the view from the rendered x position so there is one sizing rule.
public struct OverlayDot: Equatable, Sendable {
    public let point: CGPoint
    public let alpha: CGFloat

    public init(point: CGPoint, alpha: CGFloat) {
        self.point = point
        self.alpha = alpha
    }
}

/// AppKit owns no motion state. It draws the latest pure side-rail frame and
/// remains click-through when hosted by `OverlayController`.
public final class DotOverlayView: NSView {
    public var dotColorMode = DotColorMode.gray {
        didSet {
            needsDisplay = true
        }
    }

    public var motionOffset = CGSize.zero {
        didSet { needsDisplay = true }
    }

    public var tuning = NomasMotionTuning.defaults {
        didSet { needsDisplay = true }
    }

    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let dots = SideRailRenderer.frame(in: bounds, phase: motionOffset, tuning: tuning)
        let dotColor = Self.dotColor(for: dotColorMode)
        for dot in dots {
            let radius = SideRailRenderer.radius(at: dot.point.x, in: bounds, tuning: tuning)
            let rect = CGRect(
                x: dot.point.x - radius,
                y: dot.point.y - radius,
                width: radius * 2.0,
                height: radius * 2.0
            )
            dotColor.withAlphaComponent(max(0.0, min(1.0, dot.alpha))).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

    }

    /// Explicitly named update keeps controller/view ownership readable. The
    /// view's `motionOffset` setter is also enough for settings previews.
    public func updateSideRailFrame(motionOffset: CGSize) {
        self.motionOffset = motionOffset
    }

    public func resetVisualState() {
        motionOffset = .zero
        needsDisplay = true
    }

    // Stable pure API for headless layout checks and external integrations.
    nonisolated public static func sideRailDots(
        in bounds: CGRect,
        motionOffset: CGSize = .zero,
        tuning: NomasMotionTuning = .defaults
    ) -> [OverlayDot] {
        SideRailRenderer.frame(in: bounds, phase: motionOffset, tuning: tuning)
    }

    nonisolated public static func sideRailBaseDots(
        in bounds: CGRect,
        tuning: NomasMotionTuning = .defaults
    ) -> [OverlayDot] {
        SideRailRenderer.baseFrame(in: bounds, tuning: tuning)
    }

    nonisolated public static func sideRailRadius(
        at x: CGFloat,
        in bounds: CGRect,
        tuning: NomasMotionTuning = .defaults
    ) -> CGFloat {
        SideRailRenderer.radius(at: x, in: bounds, tuning: tuning)
    }

    nonisolated public static func wrappedPoint(_ point: CGPoint, by offset: CGSize, in bounds: CGRect) -> CGPoint {
        SideRailRenderer.wrappedPoint(point, by: offset, in: bounds)
    }

    nonisolated public static func renderedDots(
        for dot: OverlayDot,
        by offset: CGSize,
        in bounds: CGRect
    ) -> [OverlayDot] {
        SideRailRenderer.renderedDots(for: dot, by: offset, in: bounds)
    }

    @MainActor
    public static func dotColor(for mode: DotColorMode) -> NSColor {
        switch mode {
        case .black:
            return .black
        case .white:
            return .white
        case .gray:
            return NSColor(calibratedWhite: 0.5, alpha: 1.0)
        }
    }
}
