import XCTest
import NomasMotionCore
import NomasMotionOverlay

final class OverlayOffsetTests: XCTestCase {
    func testOverlayOffsetUsesSemanticScreenCueAndClamp() throws {
        let deadbanded = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 0.010, screenY: -0.007, hasSamples: true))
        XCTAssertTrue(abs(deadbanded.width) < 0.000_001, "overlay x offset should suppress small jitter")
        XCTAssertTrue(abs(deadbanded.height) < 0.000_001, "overlay y offset should suppress small jitter")

        let normal = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 0.10, screenY: -0.05, hasSamples: true))
        XCTAssertTrue(abs(normal.width - 28.16) < 0.000_001, "default x velocity should use the side-rail presentation gain")
        XCTAssertTrue(abs(normal.height + 21.84) < 0.000_001, "default y velocity should use the side-rail presentation gain")

        let clamped = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 2.0, screenY: 2.0, hasSamples: true))
        XCTAssertTrue(abs(clamped.width - 64.0) < 0.000_001, "x velocity should use the side-rail product clamp")
        XCTAssertTrue(abs(clamped.height - 72.0) < 0.000_001, "y velocity should use the side-rail product clamp")
    }

    func testOverlayOffsetUsesTuning() throws {
        var tuning = NomasMotionTuning.defaults
        tuning.horizontalGain = 100.0
        tuning.verticalGain = 200.0
        tuning.motionSpeedScale = 1.0
        tuning.horizontalDeadband = 0.0
        tuning.verticalDeadband = 0.0
        tuning.horizontalMaxOffset = 5.0
        tuning.verticalMaxOffset = 20.0

        let normal = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 0.03, screenY: -0.04, hasSamples: true), tuning: tuning)
        XCTAssertTrue(abs(normal.width - 3.0) < 0.000_001, "custom tuning should control horizontal gain")
        XCTAssertTrue(abs(normal.height + 8.0) < 0.000_001, "custom tuning should control vertical gain")

        let clamped = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 1.0, screenY: -1.0, hasSamples: true), tuning: tuning)
        XCTAssertTrue(abs(clamped.width - 5.0) < 0.000_001, "custom tuning should control horizontal clamp")
        XCTAssertTrue(abs(clamped.height + 20.0) < 0.000_001, "custom tuning should control vertical clamp")

        tuning.motionSpeedScale = 2.0
        tuning.horizontalMaxOffset = 50.0
        tuning.verticalMaxOffset = 50.0
        let faster = OverlayController.dotVelocity(for: VehicleMotionCue(screenX: 0.03, screenY: -0.04, hasSamples: true), tuning: tuning)

        let integrated = OverlayController.integrateMotionOffset(
            offset: CGSize(width: 10.0, height: -5.0),
            velocity: CGSize(width: 96.0, height: -48.0),
            dt: 1.0 / 60.0
        )
        XCTAssertEqual(integrated.width, 11.6, accuracy: 0.000_001)
        XCTAssertEqual(integrated.height, -5.8, accuracy: 0.000_001)
        XCTAssertTrue(abs(faster.width - 6.0) < 0.000_001, "custom tuning should control horizontal speed scale")
        XCTAssertTrue(abs(faster.height + 16.0) < 0.000_001, "custom tuning should control vertical speed scale")
    }

}
