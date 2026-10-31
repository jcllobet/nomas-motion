import AppKit
import NomasMotionCore
import NomasMotionOverlay
import XCTest

@MainActor
final class OverlayLayoutTests: XCTestCase {
    func testOverlayWindowBehavior() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        OverlayController.configureOverlayWindow(window)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.isOpaque)
        XCTAssertFalse(window.hasShadow)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testSavedDefaultUsesFixedGray() throws {
        XCTAssertEqual(DotColorMode(rawValue: 0), .gray)
        XCTAssertEqual(DotOverlayView.dotColor(for: .gray), NSColor(calibratedWhite: 0.5, alpha: 1.0))
        XCTAssertEqual(DotOverlayView.dotColor(for: .black), .black)
        XCTAssertEqual(DotOverlayView.dotColor(for: .white), .white)
    }

    func testDotModesDoNotInvertUnderlyingContent() throws {
        let view = DotOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        for mode in DotColorMode.allCases {
            view.dotColorMode = mode
            XCTAssertNil(view.layer?.compositingFilter)
        }
    }

    func testGrayRemainsGrayAcrossAppearancesAndMotionFrames() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 240)
        let view = DotOverlayView(frame: bounds)
        for phase in [-70.0, 0.0, 70.0] {
            view.motionOffset = CGSize(width: phase, height: phase * 0.3)
            let dot = try XCTUnwrap(SideRailRenderer.frame(in: bounds, phase: view.motionOffset).max { $0.alpha < $1.alpha })
            for background in [NSColor.black, .white] {
                var pixels: [NSColor] = []
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    view.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(bounds.width),
                        pixelsHigh: Int(bounds.height),
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0,
                        bitsPerPixel: 0
                    ))
                    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    background.setFill()
                    bounds.fill()
                    view.draw(bounds)
                    context.flushGraphics()
                    NSGraphicsContext.restoreGraphicsState()
                    let pixel = try XCTUnwrap(bitmap.colorAt(
                        x: Int(dot.point.x.rounded()),
                        y: bitmap.pixelsHigh - 1 - Int(dot.point.y.rounded())
                    ))
                    pixels.append(pixel)
                    XCTAssertGreaterThan(pixel.redComponent, 0.2)
                    XCTAssertLessThan(pixel.redComponent, 0.8)
                    XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.01)
                    XCTAssertEqual(pixel.redComponent, pixel.blueComponent, accuracy: 0.01)
                }
                XCTAssertEqual(pixels[0].redComponent, pixels[1].redComponent, accuracy: 0.01)
            }
        }
    }

    func testMirrored48DotLattice() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let dots = SideRailRenderer.baseFrame(in: bounds)
        XCTAssertEqual(SideRailRenderer.dotCount, 48)
        XCTAssertEqual(dots.count, 48)
        let left = dots.filter { $0.point.x < bounds.midX }
        let right = dots.filter { $0.point.x > bounds.midX }
        XCTAssertEqual(left.count, 24)
        XCTAssertEqual(right.count, 24)
        XCTAssertEqual(groupedEdgeOffsets(left.map(\.point.x), edge: bounds.minX), [30: 6, 90: 6, 150: 6, 210: 6])
        XCTAssertEqual(groupedEdgeOffsets(right.map(\.point.x), edge: bounds.maxX), groupedEdgeOffsets(left.map(\.point.x), edge: bounds.minX))
        XCTAssertEqual(SideRailRenderer.boundaryXs(in: bounds).map { Int($0.rounded()) }, [30, 210, 990, 1170])
    }

    func testRailRowsRemainStaggeredWithNonzeroOrigin() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1200, height: 760)
        let dots = SideRailRenderer.baseFrame(in: bounds)
        let expectedRows: [[CGFloat]] = [
            [0.1133333, 0.28, 0.4466667, 0.6133333, 0.78, 0.9466667],
            [0.03, 0.1966667, 0.3633333, 0.53, 0.6966667, 0.8633333],
            [0.1133333, 0.28, 0.4466667, 0.6133333, 0.78, 0.9466667],
            [0.03, 0.1966667, 0.3633333, 0.53, 0.6966667, 0.8633333],
        ]

        for (index, fraction) in SideRailRenderer.trackFractions.enumerated() {
            let leftX = bounds.minX + bounds.width * fraction
            let rightX = bounds.maxX - bounds.width * fraction
            for x in [leftX, rightX] {
                let normalizedRows = dots
                    .filter { abs($0.point.x - x) < 0.000_001 }
                    .map { (bounds.maxY - $0.point.y) / bounds.height }
                    .sorted()
                XCTAssertEqual(normalizedRows.count, expectedRows[index].count)
                for (actual, expected) in zip(normalizedRows, expectedRows[index]) {
                    XCTAssertEqual(actual, expected, accuracy: 0.000_001)
                }
            }
        }
    }

    func testHorizontalSeamUsesDocumentedFadingCopies() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let frame = SideRailRenderer.frame(in: bounds, phase: CGSize(width: 38, height: 0))
        XCTAssertEqual(SideRailRenderer.baseFrame(in: bounds).count, 48)
        XCTAssertEqual(frame.count, 60, "seam crossfades may draw copies of the 48 logical dots")
        XCTAssertTrue(frame.allSatisfy { dot in
            dot.point.x < bounds.minX + bounds.width * SideRailRenderer.protectedCenterFraction
                || dot.point.x > bounds.maxX - bounds.width * SideRailRenderer.protectedCenterFraction
        })
    }

    func testVerticalWrapPreservesAlternatingRowsAndUniformSpacing() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1200, height: 760)
        for phase in [-1.03, -0.5, -0.03, 0.0, 0.03, 0.5, 1.03] {
            let dots = SideRailRenderer.frame(in: bounds, phase: CGSize(width: 0, height: bounds.height * phase))
            for isLeft in [true, false] {
                let rows = Dictionary(grouping: dots.filter { ($0.point.x < bounds.midX) == isLeft }, by: \.point.y)
                let heights = rows.keys.sorted()
                XCTAssertGreaterThan(heights.count, 1)
                guard heights.count > 1 else { continue }
                XCTAssertTrue(rows.values.allSatisfy { $0.count == 2 })
                let spacing = bounds.height / CGFloat(heights.count)
                let pairs = zip(heights, heights.dropFirst() + [heights[0] + bounds.height])
                XCTAssertTrue(pairs.allSatisfy { abs($1 - $0 - spacing) < 0.000_001 }, "phase: \(phase)")
                let tracks = heights.map { rows[$0]!.map(\.point.x).sorted() }
                XCTAssertTrue(zip(tracks, tracks.dropFirst() + [tracks[0]]).allSatisfy { $0 != $1 }, "phase: \(phase)")
            }
        }
    }

    func testSharedPhaseWrapsAndMovesEveryDotTogetherVertically() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let rest = SideRailRenderer.frame(in: bounds)
        let moved = SideRailRenderer.frame(in: bounds, phase: CGSize(width: 0, height: 10))
        XCTAssertEqual(rest.count, moved.count)
        for (before, after) in zip(rest, moved) {
            XCTAssertEqual(after.point.x, before.point.x, accuracy: 0.000_001)
            XCTAssertEqual(after.point.y - before.point.y, 10, accuracy: 0.000_001)
        }
        let first = sortedDots(SideRailRenderer.frame(in: bounds, phase: CGSize(width: 38, height: -24)))
        let wrapped = sortedDots(SideRailRenderer.frame(in: bounds, phase: CGSize(width: 38 + bounds.width * 0.20, height: bounds.height - 24)))
        XCTAssertEqual(first.count, wrapped.count)
        for (lhs, rhs) in zip(first, wrapped) {
            XCTAssertEqual(lhs.point.x, rhs.point.x, accuracy: 0.000_001)
            XCTAssertEqual(lhs.point.y, rhs.point.y, accuracy: 0.000_001)
            XCTAssertEqual(lhs.alpha, rhs.alpha, accuracy: 0.000_001)
        }
    }

    func testBothSignsMoveAllRailsInOneScreenDirection() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 760)
        // Compare one logical dot at a time. The full frame may contain a
        // second fading copy at a wrap boundary, so frame-array indices are
        // not identities during that transition.
        let base = SideRailRenderer.baseFrame(in: bounds)
        for dot in base {
            let rest = SideRailRenderer.wrappedPoint(dot.point, by: .zero, in: bounds)
            let positive = SideRailRenderer.wrappedPoint(dot.point, by: CGSize(width: 2, height: 0), in: bounds)
            let negative = SideRailRenderer.wrappedPoint(dot.point, by: CGSize(width: -2, height: 0), in: bounds)
            XCTAssertGreaterThanOrEqual(positive.x, rest.x - 0.000_001)
            XCTAssertLessThanOrEqual(negative.x, rest.x + 0.000_001)
        }
    }

    func testMaximumDotSizeStillProtectsCenter() throws {
        let bounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        var tuning = NomasMotionTuning.defaults
        tuning.dotSizeScale = 100
        for phase in [-3.7 * bounds.width, -38, 0, 38, 3.7 * bounds.width] {
            let dots = SideRailRenderer.frame(in: bounds, phase: CGSize(width: phase, height: phase * 0.37), tuning: tuning)
            XCTAssertFalse(dots.isEmpty)
            XCTAssertTrue(dots.allSatisfy { dot in
                let radius = SideRailRenderer.radius(at: dot.point.x, in: bounds, tuning: tuning)
                return dot.point.x + radius <= bounds.width * SideRailRenderer.protectedCenterFraction
                    || dot.point.x - radius >= bounds.width * (1 - SideRailRenderer.protectedCenterFraction)
            })
        }
    }

    func testTuningChangesSizeAndAlphaWithoutChangingGeometry() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let defaults = SideRailRenderer.baseFrame(in: bounds)
        var tuning = NomasMotionTuning.defaults
        tuning.dotSizeScale = 1.2
        tuning.dotAlphaScale = 0.5
        let tuned = SideRailRenderer.baseFrame(in: bounds, tuning: tuning)
        XCTAssertEqual(defaults.count, tuned.count)
        XCTAssertEqual(defaults[0].point, tuned[0].point)
        XCTAssertEqual(tuned[0].alpha, defaults[0].alpha * 0.5, accuracy: 0.000_001)
        XCTAssertGreaterThan(SideRailRenderer.radius(at: defaults[0].point.x, in: bounds, tuning: tuning), SideRailRenderer.radius(at: defaults[0].point.x, in: bounds))
    }

    func testDebugMeasurementsDescribeRails() throws {
        let bounds = CGRect(x: 100, y: 200, width: 400, height: 300)
        let measurements = SideRailRenderer.debugMeasurements(in: bounds, phase: .zero)
        XCTAssertEqual(measurements.verticalBoundaryXs.map { Int($0.rounded()) }, [110, 170, 430, 490])
        XCTAssertEqual(measurements.horizontalBoundaryYs.map { Int($0.rounded()) }, [200, 500])
        XCTAssertTrue(measurements.leftOuterEdgeDistanceToNearestXBoundary.isFinite)
        XCTAssertTrue(measurements.rightOuterEdgeDistanceToNearestXBoundary.isFinite)
    }

    private func groupedEdgeOffsets(_ xs: [CGFloat], edge: CGFloat) -> [Int: Int] {
        xs.reduce(into: [:]) { groups, x in
            groups[Int(abs(x - edge).rounded()), default: 0] += 1
        }
    }

    private func sortedDots(_ dots: [OverlayDot]) -> [OverlayDot] {
        dots.sorted {
            if abs($0.point.x - $1.point.x) > 0.000_001 { return $0.point.x < $1.point.x }
            if abs($0.point.y - $1.point.y) > 0.000_001 { return $0.point.y < $1.point.y }
            return $0.alpha < $1.alpha
        }
    }

}
