import CoreGraphics
import Foundation
import NomasMotionCore

/// The only shipping overlay renderer.
///
/// This is deliberately a pure projection: a screen rectangle, one shared
/// phase, and tuning produce a frame of peripheral dots.  Motion state lives
/// in `OverlayController`; AppKit state lives in `DotOverlayView`.
public enum SideRailRenderer {
    public static let trackFractions: [CGFloat] = [0.025, 0.075, 0.125, 0.175]
    public static let outerTrackFraction: CGFloat = 0.025
    public static let innerTrackFraction: CGFloat = 0.175
    /// Dots fade out by this distance before the protected center zone.
    public static let fadeWidthFraction: CGFloat = 0.05
    /// The central half of the display is work space, never a particle field.
    public static let protectedCenterFraction: CGFloat = 0.25
    public static let dotCount = trackFractions.count * rowsPerTrack * 2

    private static let rowsPerTrack = 6
    private static let smallestRadius: CGFloat = 5.25
    private static let largestRadius: CGFloat = 13.65
    private static let trackPresets: [(rowOffset: CGFloat, alpha: CGFloat)] = [
        (0.5, 0.86),
        (0.0, 0.70),
        (0.5, 0.66),
        (0.0, 0.78)
    ]

    public static func frame(
        in bounds: CGRect,
        phase: CGSize = .zero,
        tuning: NomasMotionTuning = .defaults
    ) -> [OverlayDot] {
        guard bounds.width > 0.0, bounds.height > 0.0 else { return [] }

        return baseFrame(in: bounds, tuning: tuning).flatMap { dot in
            let y = wrappedValue(dot.point.y + phase.height, min: bounds.minY, max: bounds.maxY)
            return renderedRailXs(dot.point.x, by: phase.width, in: bounds).map { rendered in
                OverlayDot(
                    point: CGPoint(x: rendered.x, y: y),
                    alpha: dot.alpha * rendered.alpha
                )
            }
        }
    }

    /// The fixed rest composition.  It is useful for tests and diagnostics,
    /// but never owns motion state.
    public static func baseFrame(
        in bounds: CGRect,
        tuning: NomasMotionTuning = .defaults
    ) -> [OverlayDot] {
        guard bounds.width > 0.0, bounds.height > 0.0 else { return [] }

        let alphaScale = CGFloat(max(0.0, tuning.dotAlphaScale))
        var dots: [OverlayDot] = []
        dots.reserveCapacity(dotCount)

        for (trackIndex, fraction) in trackFractions.enumerated() {
            let preset = trackPresets[trackIndex]
            let offset = bounds.width * fraction
            let leftX = bounds.minX + offset
            let rightX = bounds.maxX - offset
            for row in 0..<rowsPerTrack {
                let topFraction = 0.03 + (CGFloat(row) + preset.rowOffset) / CGFloat(rowsPerTrack)
                let y = bounds.maxY - bounds.height * topFraction
                dots.append(OverlayDot(
                    point: CGPoint(x: leftX, y: y),
                    alpha: min(1.0, preset.alpha * alphaScale)
                ))
                dots.append(OverlayDot(
                    point: CGPoint(x: rightX, y: y),
                    alpha: min(1.0, preset.alpha * alphaScale)
                ))
            }
        }
        return dots
    }

    /// Draw radius is derived from the rendered x position.  The final cap
    /// is intentional: even an extreme size setting cannot cross the center
    /// protection boundary.
    public static func radius(
        at x: CGFloat,
        in bounds: CGRect,
        tuning: NomasMotionTuning = .defaults
    ) -> CGFloat {
        let edgeDistance = min(abs(x - bounds.minX), abs(bounds.maxX - x))
        let outerDistance = bounds.width * outerTrackFraction
        let innerDistance = bounds.width * innerTrackFraction
        let denominator = max(1.0, innerDistance - outerDistance)
        let edgeCloseness = max(0.0, min(1.0, (innerDistance - edgeDistance) / denominator))
        let base = smallestRadius + (largestRadius - smallestRadius) * edgeCloseness
        let scaled = base * CGFloat(max(0.1, tuning.dotSizeScale))

        let centerBoundary = x < bounds.midX
            ? bounds.minX + bounds.width * protectedCenterFraction
            : bounds.maxX - bounds.width * protectedCenterFraction
        let distanceToCenter = abs(centerBoundary - x)
        // Keep a tiny positive gap so antialiasing cannot paint across the
        // protected boundary when a user selects an intentionally huge size.
        return max(0.0, min(scaled, distanceToCenter - 0.001))
    }

    public static func wrappedPoint(_ point: CGPoint, by phase: CGSize, in bounds: CGRect) -> CGPoint {
        let rendered = renderedRailXs(point.x, by: phase.width, in: bounds)
            .max { $0.alpha < $1.alpha }?.x ?? point.x
        return CGPoint(
            x: rendered,
            y: wrappedValue(point.y + phase.height, min: bounds.minY, max: bounds.maxY)
        )
    }

    public static func renderedDots(
        for dot: OverlayDot,
        by phase: CGSize,
        in bounds: CGRect
    ) -> [OverlayDot] {
        let y = wrappedValue(dot.point.y + phase.height, min: bounds.minY, max: bounds.maxY)
        return renderedRailXs(dot.point.x, by: phase.width, in: bounds).map { rendered in
            OverlayDot(
                point: CGPoint(x: rendered.x, y: y),
                alpha: dot.alpha * rendered.alpha
            )
        }
    }

    public static func debugMeasurements(
        in bounds: CGRect,
        phase: CGSize,
        tuning: NomasMotionTuning = .defaults
    ) -> OverlayDebugMeasurements {
        let dots = frame(in: bounds, phase: phase, tuning: tuning)
        let boundaries = boundaryXs(in: bounds)
        let leftDots = dots.filter { $0.point.x < bounds.midX }
        let rightDots = dots.filter { $0.point.x > bounds.midX }
        let topDot = dots.max { $0.point.y < $1.point.y }
        let bottomDot = dots.min { $0.point.y < $1.point.y }
        let leftOuter = leftDots.min { $0.point.x < $1.point.x }
        let leftInner = leftDots.max { $0.point.x < $1.point.x }
        let rightInner = rightDots.min { $0.point.x < $1.point.x }
        let rightOuter = rightDots.max { $0.point.x < $1.point.x }

        return OverlayDebugMeasurements(
            verticalBoundaryXs: boundaries,
            horizontalBoundaryYs: [bounds.minY, bounds.maxY],
            leftOuterEdgeDistanceToNearestXBoundary: edgeDistance(leftOuter, boundary: boundaries[0], in: bounds, tuning: tuning),
            leftInnerEdgeDistanceToNearestXBoundary: edgeDistance(leftInner, boundary: boundaries[1], in: bounds, tuning: tuning),
            rightInnerEdgeDistanceToNearestXBoundary: edgeDistance(rightInner, boundary: boundaries[2], in: bounds, tuning: tuning),
            rightOuterEdgeDistanceToNearestXBoundary: edgeDistance(rightOuter, boundary: boundaries[3], in: bounds, tuning: tuning),
            upperEdgeDistanceToTopBoundary: topDot.map { bounds.maxY - $0.point.y - radius(at: $0.point.x, in: bounds, tuning: tuning) } ?? 0.0,
            lowerEdgeDistanceToBottomBoundary: bottomDot.map { $0.point.y - radius(at: $0.point.x, in: bounds, tuning: tuning) - bounds.minY } ?? 0.0
        )
    }

    public static func boundaryXs(in bounds: CGRect) -> [CGFloat] {
        let outer = bounds.minX + bounds.width * outerTrackFraction
        let inner = bounds.minX + bounds.width * innerTrackFraction
        return [outer, inner, bounds.maxX - (inner - bounds.minX), bounds.maxX - (outer - bounds.minX)]
    }

    /// Normalize accumulated state to the repeating rail periods.  This keeps
    /// a long-running app numerically bounded without changing its frame.
    public static func boundedPhase(_ phase: CGSize, in bounds: CGRect) -> CGSize {
        guard bounds.width > 0.0, bounds.height > 0.0 else { return .zero }
        let gap = max(1.0, bounds.width * (innerTrackFraction - outerTrackFraction) / 3.0)
        return CGSize(
            width: wrappedValue(phase.width, min: 0.0, max: gap * 4.0),
            height: wrappedValue(phase.height, min: 0.0, max: bounds.height)
        )
    }

    private static func edgeDistance(
        _ dot: OverlayDot?,
        boundary: CGFloat,
        in bounds: CGRect,
        tuning: NomasMotionTuning
    ) -> CGFloat {
        guard let dot else { return 0.0 }
        return abs(dot.point.x - boundary) - radius(at: dot.point.x, in: bounds, tuning: tuning)
    }

    private static func renderedRailXs(
        _ x: CGFloat,
        by phase: CGFloat,
        in bounds: CGRect
    ) -> [(x: CGFloat, alpha: CGFloat)] {
        let metrics = railMetrics(in: bounds)
        let isLeftSide = x < bounds.midX
        let baseEdgeOffset = isLeftSide
            ? x - bounds.minX + phase
            : bounds.maxX - x - phase
        let centerOffset = (metrics.minOffset + metrics.maxOffset) * 0.5
        let normalizedOffset = baseEdgeOffset
            - floor((baseEdgeOffset - centerOffset) / metrics.period) * metrics.period

        return [normalizedOffset - metrics.period, normalizedOffset, normalizedOffset + metrics.period].compactMap { edgeOffset in
            let alpha = fadeAlpha(edgeOffset, metrics: metrics)
            guard alpha > 0.001 else { return nil }
            return (
                isLeftSide ? bounds.minX + edgeOffset : bounds.maxX - edgeOffset,
                alpha
            )
        }
    }

    private static func railMetrics(in bounds: CGRect) -> (minOffset: CGFloat, maxOffset: CGFloat, period: CGFloat, fadeWidth: CGFloat) {
        let outerOffset = bounds.width * outerTrackFraction
        let innerOffset = bounds.width * innerTrackFraction
        let gap = max(1.0, (innerOffset - outerOffset) / 3.0)
        return (outerOffset, innerOffset, gap * 4.0, gap)
    }

    private static func fadeAlpha(
        _ edgeOffset: CGFloat,
        metrics: (minOffset: CGFloat, maxOffset: CGFloat, period: CGFloat, fadeWidth: CGFloat)
    ) -> CGFloat {
        if edgeOffset < metrics.minOffset {
            return smoothstep((edgeOffset - (metrics.minOffset - metrics.fadeWidth)) / metrics.fadeWidth)
        }
        if edgeOffset > metrics.maxOffset {
            return smoothstep(((metrics.maxOffset + metrics.fadeWidth) - edgeOffset) / metrics.fadeWidth)
        }
        return 1.0
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = max(0.0, min(1.0, value))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func wrappedValue(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let range = max - min
        guard range > 0.0 else { return min }
        var wrapped = (value - min).truncatingRemainder(dividingBy: range)
        if wrapped < 0.0 { wrapped += range }
        return min + wrapped
    }
}

public struct OverlayDebugMeasurements: Equatable, Sendable {
    public let verticalBoundaryXs: [CGFloat]
    public let horizontalBoundaryYs: [CGFloat]
    public let leftOuterEdgeDistanceToNearestXBoundary: CGFloat
    public let leftInnerEdgeDistanceToNearestXBoundary: CGFloat
    public let rightInnerEdgeDistanceToNearestXBoundary: CGFloat
    public let rightOuterEdgeDistanceToNearestXBoundary: CGFloat
    public let upperEdgeDistanceToTopBoundary: CGFloat
    public let lowerEdgeDistanceToBottomBoundary: CGFloat
}
