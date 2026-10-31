import XCTest
import NomasMotionCore


enum TestHelpers {
    static func fastSettlingProcessor(now: @escaping () -> Date = Date.init) -> MotionProcessor {
        let processor = MotionProcessor(now: now)
        var tuning = NomasMotionTuning.defaults
        tuning.smoothingAlpha = 0.5
        processor.applyTuning(tuning)
        return processor
    }

    static func ingestRepeated(_ processor: MotionProcessor, count: Int, x: Double, y: Double, z: Double) {
        for _ in 0..<count {
            processor.ingestScaled(x: x, y: y, z: z)
        }
    }

    static func fusedSample(
        userX: Double,
        userY: Double,
        timestamp: Double,
        quaternionX: Double = 0.0,
        quaternionY: Double = 0.0,
        quaternionZ: Double = 0.0,
        quaternionW: Double = 1.0
    ) -> FusedMotionSample {
        FusedMotionSample(
            userAccelerationX: userX,
            userAccelerationY: userY,
            userAccelerationZ: 0.0,
            gravityX: 0.0,
            gravityY: 0.0,
            gravityZ: -1.0,
            rotationRateX: 0.0,
            rotationRateY: 0.0,
            rotationRateZ: 0.0,
            quaternionX: quaternionX,
            quaternionY: quaternionY,
            quaternionZ: quaternionZ,
            quaternionW: quaternionW,
            timestamp: timestamp
        )
    }
}


final class MotionProcessorTests: XCTestCase {
    func testFirstSampleCreatesGravityEstimateWithoutMotionCue() throws {
        let processor = MotionProcessor()

        processor.ingestScaled(x: 0.10, y: -0.05, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(cue.hasSamples, "first sample should mark samples as available")
        XCTAssertTrue(abs(cue.screenX) < 0.000_001, "first sample screen x cue should be zero")
        XCTAssertTrue(abs(cue.screenY) < 0.000_001, "first sample screen y cue should be zero")
    }

    func testMaximumSampleAgeZerosRetainedMotionAfterSensorStops() throws {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let processor = MotionProcessor(now: { currentTime })

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
        processor.ingestScaled(x: 0.2, y: 0.0, z: 1.0)
        XCTAssertGreaterThan(processor.currentCue(maximumSampleAge: 0.5).screenX, 0.0)

        currentTime = currentTime.addingTimeInterval(0.51)
        let stale = processor.currentCue(maximumSampleAge: 0.5)
        XCTAssertFalse(stale.hasSamples)
        XCTAssertEqual(stale.screenX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.screenY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.viewX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.viewY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.rawX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.rawY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.rawZ, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.dynamicX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.dynamicY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(stale.motion, .still)
    }

    func testFusedTimestampEpochResetsAfterRawFallback() throws {
        let processor = MotionProcessor()
        processor.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 100.0))
        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)

        processor.ingest(TestHelpers.fusedSample(userX: 0.2, userY: 0.0, timestamp: 1.0))

        let cue = processor.currentCue()
        XCTAssertEqual(cue.sampleCount, 3)
        XCTAssertGreaterThan(cue.screenX, 0.0, "a new fused stream may use a new timestamp epoch")
    }

    func testMotionFilterConstants() throws {
        XCTAssertEqual(nomasMotionInputFilterAlpha, 0.2952182775507781, accuracy: 0.000_000_000_001)
        XCTAssertEqual(nomasMotionOutputFilterAlpha, 0.13575524816363319, accuracy: 0.000_000_000_001)
        XCTAssertEqual(nomasMotionViewFilterAlpha, 0.010363449720275758, accuracy: 0.000_000_000_001)
    }

    func testFusedMotionKeepsSlowViewSeparateFromPrimary() throws {
        let processor = MotionProcessor()
        let interval = 1.0 / 60.0
        processor.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 0.0))
        processor.ingest(TestHelpers.fusedSample(userX: 0.18, userY: 0.0, timestamp: interval))
        let cue = processor.currentCue()

        XCTAssertGreaterThan(cue.viewX, 0.0)
        XCTAssertLessThan(cue.viewX, cue.screenX, "the slow visual cue must remain distinct from the primary cue")
        XCTAssertEqual(cue.viewY, 0.0, accuracy: 0.000_001)
    }

    func testFusedMotionUsesGravityFreeAcceleration() throws {
        let processor = MotionProcessor()
        processor.ingest(TestHelpers.fusedSample(userX: 0.01, userY: 0.0, timestamp: 1.0))
        processor.ingest(TestHelpers.fusedSample(userX: 0.21, userY: 0.0, timestamp: 2.0))
        let cue = processor.currentCue()

        XCTAssertTrue(cue.screenX > 0.0)
        XCTAssertTrue(abs(cue.screenY) < 0.000_001)
    }

    func testFusedMotionDoesNotTreatFirstMotionSampleAsBias() throws {
        let processor = MotionProcessor()
        processor.ingest(TestHelpers.fusedSample(userX: 0.18, userY: 0.0, timestamp: 1.0))

        XCTAssertGreaterThan(
            processor.currentCue().screenX,
            0.0,
            "starting the app during motion must not erase the first acceleration as a baseline"
        )
    }

    func testFusedMotionDefaultsToIdentityAttitude() throws {
        let sample = TestHelpers.fusedSample(userX: 0.2, userY: -0.1, timestamp: 1.0)

        XCTAssertEqual(sample.quaternionX, 0.0)
        XCTAssertEqual(sample.quaternionY, 0.0)
        XCTAssertEqual(sample.quaternionZ, 0.0)
        XCTAssertEqual(sample.quaternionW, 1.0)
    }

    func testFusedMotionRemovesPureYawFromAttitude() throws {
        let processor = MotionProcessor()
        processor.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 1.0))
        processor.ingest(
            TestHelpers.fusedSample(
                userX: 1.0,
                userY: 0.0,
                timestamp: 1.0 + 1.0 / 60.0,
                quaternionZ: 1.0,
                quaternionW: 1.0
            )
        )
        let cue = processor.currentCue()

        XCTAssertGreaterThan(cue.screenX, 0.0, "pure yaw must leave +x acceleration on +x")
        XCTAssertLessThan(abs(cue.screenY), 0.000_001, "pure yaw must not create a lateral axis change")
    }

    func testFusedMotionAppliesYawCancelledRollMatrix() throws {
        let processor = MotionProcessor()
        processor.ingest(
            FusedMotionSample(
                userAccelerationX: 0.0,
                userAccelerationY: 1.0,
                userAccelerationZ: 0.0,
                gravityX: 0.0,
                gravityY: 0.0,
                gravityZ: 0.0,
                rotationRateX: 0.0,
                rotationRateY: 0.0,
                rotationRateZ: 0.0,
                quaternionX: 1.0,
                quaternionW: 1.0,
                timestamp: 1.0
            )
        )
        let cue = processor.currentCue()

        XCTAssertEqual(cue.rawX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.rawY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.rawZ, 1.0, accuracy: 0.000_001)
    }

    func testFusedMotionMatchesNativeYawCancelledMixedQuaternion() throws {
        let processor = MotionProcessor()
        processor.ingest(
            FusedMotionSample(
                userAccelerationX: 1.0,
                userAccelerationY: 2.0,
                userAccelerationZ: 3.0,
                gravityX: 0.0,
                gravityY: 0.0,
                gravityZ: 0.0,
                rotationRateX: 0.0,
                rotationRateY: 0.0,
                rotationRateZ: 0.0,
                quaternionX: 0.2,
                quaternionY: 0.3,
                quaternionZ: 0.9,
                quaternionW: 0.1,
                timestamp: 1.0
            )
        )
        let cue = processor.currentCue()

        XCTAssertEqual(cue.rawX, -0.228498074, accuracy: 0.000_001)
        XCTAssertEqual(cue.rawY, -0.375096277, accuracy: 0.000_001)
        XCTAssertEqual(cue.rawZ, 3.715789474, accuracy: 0.000_001)
    }

    func testFusedTimestampDeltaWinsOverWallClockJitter() throws {
        var jitteredWallClock = Date(timeIntervalSince1970: 100.0)
        let jittered = MotionProcessor(now: { jitteredWallClock })
        jittered.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 10.0))
        jitteredWallClock = jitteredWallClock.addingTimeInterval(10.0)
        jittered.ingest(TestHelpers.fusedSample(userX: 0.8, userY: 0.0, timestamp: 10.0 + 1.0 / 60.0))

        var nominalWallClock = Date(timeIntervalSince1970: 100.0)
        let nominal = MotionProcessor(now: { nominalWallClock })
        nominal.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 10.0))
        nominalWallClock = nominalWallClock.addingTimeInterval(1.0 / 60.0)
        nominal.ingest(TestHelpers.fusedSample(userX: 0.8, userY: 0.0, timestamp: 10.0 + 1.0 / 60.0))

        XCTAssertEqual(
            jittered.currentCue().screenX,
            nominal.currentCue().screenX,
            accuracy: 0.000_000_001,
            "fused samples must use their monotonic timestamps, not Date scheduling jitter"
        )
    }

    func testFusedPrimaryOutputIsClampedToUnitRange() throws {
        let processor = MotionProcessor()
        let interval = 1.0 / 60.0
        processor.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 0.0))
        for index in 1...240 {
            processor.ingest(
                TestHelpers.fusedSample(
                    userX: 100.0,
                    userY: -100.0,
                    timestamp: Double(index) * interval
                )
            )
        }

        let cue = processor.currentCue()
        XCTAssertLessThanOrEqual(cue.screenX, 1.0)
        XCTAssertGreaterThanOrEqual(cue.screenX, -1.0)
        XCTAssertLessThanOrEqual(cue.screenY, 1.0)
        XCTAssertGreaterThanOrEqual(cue.screenY, -1.0)
        XCTAssertEqual(cue.screenX, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.screenY, -1.0, accuracy: 0.000_001)
    }

    func testFusedPrimaryFilterTailIsNotTruncatedBySecondDeadband() throws {
        let processor = MotionProcessor()
        let interval = 1.0 / 60.0
        processor.ingest(TestHelpers.fusedSample(userX: 0.0, userY: 0.0, timestamp: 0.0))
        processor.ingest(TestHelpers.fusedSample(userX: 0.18, userY: 0.0, timestamp: interval))

        var retainedFilteredTail = false
        for index in 2...240 {
            processor.ingest(
                TestHelpers.fusedSample(
                    userX: 0.0,
                    userY: 0.0,
                    timestamp: Double(index) * interval
                )
            )
            let magnitude = abs(processor.currentCue().screenX)
            if magnitude > 0.0, magnitude < nomasMotionReleaseThreshold {
                retainedFilteredTail = true
                break
            }
        }

        XCTAssertTrue(retainedFilteredTail, "the 1.5 Hz output tail must decay continuously instead of snapping at a second deadband")
    }

    func testAccelerationPulseCreatesBackwardScreenCue() throws {
        let processor = MotionProcessor()

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: 0.0, y: -1.0, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(abs(cue.screenX) < 0.000_001, "forward acceleration should not create horizontal cue")
        XCTAssertTrue(cue.screenY < 0.0, "forward acceleration should move dots backward/down")
    }

    func testBrakingPulseCreatesForwardScreenCue() throws {
        let processor = MotionProcessor()

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: 0.0, y: 1.0, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(abs(cue.screenX) < 0.000_001, "braking should not create horizontal cue")
        XCTAssertTrue(cue.screenY > 0.0, "braking should move dots forward/up")
    }

    func testTurnsMoveOppositeTheTurn() throws {
        let leftTurn = MotionProcessor()
        leftTurn.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        leftTurn.ingestScaled(x: 1.0, y: 0.0, z: 1.0)
        XCTAssertTrue(leftTurn.currentCue().screenX > 0.0, "left turn should move dots right")

        let rightTurn = MotionProcessor()
        rightTurn.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        rightTurn.ingestScaled(x: -1.0, y: 0.0, z: 1.0)
        XCTAssertTrue(rightTurn.currentCue().screenX < 0.0, "right turn should move dots left")
    }

    func testWeakDiagonalInputPreservesPhysicalAxes() throws {
        let processor = MotionProcessor()

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: 1.0, y: -0.2, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(cue.motion == .turningLeft, "weak diagonal input should classify as a left turn")
        XCTAssertTrue(cue.screenX > 0.0, "dominant x input should keep horizontal cue")
        XCTAssertTrue(cue.screenY < 0.0, "filtering should preserve the minor physical axis")
    }

    func testMeaningfulDiagonalInputProducesComplexCue() throws {
        let processor = MotionProcessor()

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: 1.0, y: -0.8, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(cue.motion == .complex, "meaningful diagonal input should classify as complex motion")
        XCTAssertTrue(cue.screenX > 0.0, "complex cue should keep horizontal motion")
        XCTAssertTrue(cue.screenY < 0.0, "complex cue should keep vertical motion")
    }

    func testStaticTiltDecaysToNoPersistentCue() throws {
        var currentTime = Date(timeIntervalSince1970: 90_000)
        let processor = TestHelpers.fastSettlingProcessor(now: { currentTime })

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        for _ in 0..<700 {
            currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
            processor.ingestScaled(x: 0.20, y: -0.15, z: 0.97)
        }
        let cue = processor.currentCue()

        XCTAssertTrue(abs(cue.screenX) < 0.003, "held static tilt should not create persistent horizontal cue")
        XCTAssertTrue(abs(cue.screenY) < 0.003, "held static tilt should not create persistent vertical cue")
    }

    func testConstantSpeedAfterPulseReturnsToZero() throws {
        var currentTime = Date(timeIntervalSince1970: 100_000)
        let processor = TestHelpers.fastSettlingProcessor(now: { currentTime })

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        for _ in 0..<12 {
            currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
            processor.ingestScaled(x: 0.0, y: -0.20, z: 1.0)
        }
        XCTAssertTrue(processor.currentCue().screenY < 0.0, "acceleration pulse should first move dots backward/down")

        for _ in 0..<260 {
            currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
            processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        }
        let cue = processor.currentCue()

        XCTAssertTrue(abs(cue.screenX) < 0.003, "constant-speed cruise should return horizontal cue to zero")
        XCTAssertTrue(abs(cue.screenY) < 0.003, "constant-speed cruise should return vertical cue to zero")
    }

    func testRawQ16SamplesUseSharedScale() throws {
        let processor = MotionProcessor()

        processor.ingest(rawX: 0, rawY: 0, rawZ: 65_536)
        processor.ingest(rawX: 0, rawY: -65_536, rawZ: 65_536)
        let cue = processor.currentCue()

        XCTAssertTrue(abs(cue.screenX) < 0.000_001, "raw forward cue should not create horizontal output")
        XCTAssertTrue(cue.screenY < 0.0, "raw y cue should use Q16 scale before filtering")
    }

    func testTuningCanChangeSmoothing() throws {
        let processor = MotionProcessor()
        var tuning = NomasMotionTuning.defaults
        tuning.smoothingAlpha = 0.25
        processor.applyTuning(tuning)

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: 1.0, y: 0.0, z: 1.0)
        let cue = processor.currentCue()

        XCTAssertTrue(cue.screenX > 0.0, "x cue should use tuned smoothing alpha")
        XCTAssertTrue(abs(cue.screenY) < 0.000_001, "tuned horizontal cue should remain single-axis")
    }

    func testRawSensorSampleLineRoundTrip() throws {
        let sample = RawSensorSample(x: 12, y: -34, z: 65_536)

        XCTAssertTrue(sample.line == "12 -34 65536\n", "raw sample line should be stable")
        XCTAssertTrue(RawSensorSample(line: sample.line) == sample, "raw sample line should parse back")
        XCTAssertTrue(RawSensorSample(line: "12 -34") == nil, "raw sample parser should reject incomplete lines")
    }

    func testCueReportsAccelerationInMetersPerSecondSquared() throws {
        let cue = VehicleMotionCue(screenX: 0.0, screenY: 0.0, hasSamples: true, dynamicX: 0.3, dynamicY: 0.4)

        XCTAssertTrue(
            abs(cue.accelerationMetersPerSecondSquared - nomasMotionStandardGravity * 0.5) < 0.000_001,
            "cue acceleration should convert dynamic g magnitude to m/s^2"
        )
    }

    func testSensorLineBufferParsesMultipleLines() throws {
        var buffer = SensorLineBuffer()
        let samples = buffer.append(Data("1 2 3\n4 5 6\n".utf8))
        XCTAssertTrue(samples.count == 2, "line buffer should parse multiple samples")
        XCTAssertTrue(samples[0] == RawSensorSample(x: 1, y: 2, z: 3), "first parsed sample should match")
        XCTAssertTrue(samples[1] == RawSensorSample(x: 4, y: 5, z: 6), "second parsed sample should match")
    }

    func testAutoModeDefaultsToPassiveTravelDetection() throws {
        XCTAssertTrue(NomasMotionTuning.defaults.autoEnableEnabled, "auto mode should default on for passive launch")
        XCTAssertLessThanOrEqual(nomasMotionAutoDetectionInterval, 0.1, "auto mode must sample the filtered motion stream without 1 Hz aliasing")
        XCTAssertEqual(NomasMotionTuning.defaults.autoEnableWindowSeconds, 15.0, "auto mode should require conservative travel evidence")
        XCTAssertEqual(NomasMotionTuning.defaults.autoDisableQuietSeconds, 120.0, "auto mode should tolerate normal vehicle stops")
    }

    func testTravelAutoDetectorShowsAfterSustainedMotion() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 10_000)
        var action = TravelAutoOverlayAction.none

        for tick in 0...151 {
            action = detector.update(
                cue: autoCue(dynamicX: 0.030, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
        }

        XCTAssertEqual(action, .show, "fifteen seconds of sustained travel motion should show the passive overlay")
    }

    func testTravelAutoDetectorUsesExactShowAndHideBoundaries() throws {
        var showDetector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 15_000)

        var action = TravelAutoOverlayAction.none
        for tick in 0...149 {
            action = showDetector.update(
                cue: autoCue(dynamicX: 0.030, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
        }
        XCTAssertEqual(action, .none, "14.9 seconds must not qualify travel")
        action = showDetector.update(
            cue: autoCue(dynamicX: 0.030, sampleCount: 151),
            now: start.addingTimeInterval(15.0),
            overlayVisible: false,
            tuning: tuning
        )
        XCTAssertEqual(action, .show, "15.0 seconds qualifies travel")

        var hideDetector = TravelAutoDetector()
        for second in 0...119 {
            action = hideDetector.update(
                cue: autoCue(dynamicX: 0.0, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                overlayVisible: true,
                tuning: tuning
            )
        }
        XCTAssertEqual(action, .none, "119 seconds must not hide cues during a normal stop")
        action = hideDetector.update(
            cue: autoCue(dynamicX: 0.0, sampleCount: 121),
            now: start.addingTimeInterval(120.0),
            overlayVisible: true,
            tuning: tuning
        )
        XCTAssertEqual(action, .hide, "120 seconds of quiet hides automatic cues")
    }

    func testTravelAutoDetectorResetsAndHidesOnStaleSensor() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 18_000)

        for tick in 0...140 {
            _ = detector.update(
                cue: autoCue(dynamicX: 0.030, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
        }
        XCTAssertGreaterThan(detector.motionScoreSeconds, 13.0)

        let stale = VehicleMotionCue(screenX: 0.0, screenY: 0.0, hasSamples: false, sampleCount: 141)
        XCTAssertEqual(
            detector.update(cue: stale, now: start.addingTimeInterval(14.1), overlayVisible: true, tuning: tuning),
            .hide
        )
        XCTAssertEqual(detector.motionScoreSeconds, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(detector.quietSeconds, 0.0, accuracy: 0.000_001)
    }

    func testTravelAutoDetectorRejectsOneShortJolt() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 20_000)
        var action = TravelAutoOverlayAction.none

        for tick in 0...10 {
            action = detector.update(
                cue: autoCue(dynamicX: 0.030, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
        }
        for tick in 11...111 {
            action = detector.update(
                cue: autoCue(dynamicX: 0.0, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
        }

        XCTAssertEqual(action, .none, "one short laptop jolt should not show the overlay")
        XCTAssertLessThan(detector.motionScoreSeconds, 0.01, "short-jolt evidence should decay")
    }

    func testTravelAutoDetectorAccumulatesSeparateVehiclePulses() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 22_000)
        var didShow = false

        for tick in 0...200 {
            let pulseIsActive = tick % 10 < 9
            let action = detector.update(
                cue: autoCue(dynamicX: pulseIsActive ? 0.030 : 0.0, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
            didShow = didShow || action == .show
        }

        XCTAssertTrue(didShow, "nearby acceleration, turn, and brake pulses should accumulate into travel evidence")
    }

    func testTravelAutoDetectorRejectsLongDeskJitter() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 23_000)
        var didShow = false

        for tick in 0...600 {
            let jitter = tick.isMultiple(of: 2) ? 0.019 : -0.019
            let action = detector.update(
                cue: autoCue(dynamicX: jitter, sampleCount: tick + 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
            didShow = didShow || action == .show
        }

        XCTAssertFalse(didShow, "a minute of sub-threshold desk jitter must not show the overlay")
        XCTAssertLessThan(detector.motionScoreSeconds, 0.001)
    }

    func testTravelAutoDetectorRequiresFreshSamples() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 24_000)
        var didShow = false

        for tick in 0...200 {
            let action = detector.update(
                cue: autoCue(dynamicX: 0.050, sampleCount: 1),
                now: start.addingTimeInterval(Double(tick) * nomasMotionAutoDetectionInterval),
                overlayVisible: false,
                tuning: tuning
            )
            didShow = didShow || action == .show
        }

        XCTAssertFalse(didShow, "one retained sample must not accumulate into vehicle evidence")
        XCTAssertLessThan(detector.motionScoreSeconds, 0.001)
    }

    func testTravelAutoDetectorToleratesNormalStops() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 25_000)
        var action = TravelAutoOverlayAction.none

        for second in 0...60 {
            action = detector.update(
                cue: autoCue(dynamicX: 0.0, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                overlayVisible: true,
                tuning: tuning
            )
        }

        XCTAssertEqual(action, .none, "auto mode should tolerate a normal traffic stop")
    }

    func testTravelAutoDetectorHidesAfterLongQuietPeriod() throws {
        var detector = TravelAutoDetector()
        let tuning = NomasMotionTuning.defaults
        let start = Date(timeIntervalSince1970: 30_000)
        var action = TravelAutoOverlayAction.none

        for second in 0...120 {
            action = detector.update(
                cue: autoCue(dynamicX: 0.0, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                overlayVisible: true,
                tuning: tuning
            )
        }

        XCTAssertEqual(action, .hide, "auto mode should hide after two quiet minutes")
    }

    func testTripStatisticsDefaultOnAndPreserveOptOut() throws {
        let suiteName = "NomasMotionCoreTests.TripStatistics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let defaultStore = TripStatisticsStore(defaults: defaults)
        XCTAssertTrue(defaultStore.isEnabled, "statistics collection should default on for local-only trip history")

        defaultStore.isEnabled = false
        let optedOutStore = TripStatisticsStore(defaults: defaults)
        XCTAssertFalse(optedOutStore.isEnabled, "statistics collection should preserve an explicit opt-out")
    }

    func testTripStatisticsDoNotRecordWhenDisabled() throws {
        let store = makeTripStatisticsStore()
        store.isEnabled = false
        let start = Date(timeIntervalSince1970: 40_000)

        for second in 0...5 {
            store.record(
                cue: statisticsCue(dynamicX: 0.030, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }
        store.finishOpenTrip(now: start.addingTimeInterval(6.0))

        XCTAssertFalse(store.isEnabled, "statistics collection should be disabled after opt-out")
        XCTAssertTrue(store.trips.isEmpty, "disabled statistics should not record trips")
    }

    func testTripStatisticsRecordFiveMinuteMotionSessions() throws {
        let store = makeTripStatisticsStore()
        store.isEnabled = true
        let start = Date(timeIntervalSince1970: 50_000)

        for second in 0...5 {
            store.record(
                cue: statisticsCue(dynamicX: 0.030, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }
        store.finishOpenTrip(now: start.addingTimeInterval(6.0))

        XCTAssertEqual(store.trips.count, 1, "five-minute-equivalent sustained motion should record one trip")
        let trip = try XCTUnwrap(store.trips.first)
        XCTAssertEqual(trip.durationSeconds, 6.0, "trip duration should span from motion start to finish")
        XCTAssertGreaterThanOrEqual(trip.sampleCount, 4, "trip should keep sensor snapshots for the report log")
    }

    func testTripStatisticsTolerateStopsAndEndAfterQuietPeriod() throws {
        let store = makeTripStatisticsStore()
        store.isEnabled = true
        let start = Date(timeIntervalSince1970: 60_000)

        for second in 0...4 {
            store.record(
                cue: statisticsCue(dynamicX: 0.030, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }
        for second in 5...7 {
            store.record(
                cue: statisticsCue(dynamicX: 0.0, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }
        XCTAssertTrue(store.trips.isEmpty, "short stops should not end an active trip")

        for second in 8...10 {
            store.record(
                cue: statisticsCue(dynamicX: 0.0, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }

        let trip = try XCTUnwrap(store.trips.first)
        XCTAssertEqual(store.trips.count, 1, "statistics store should contain exactly one trip")
        XCTAssertEqual(trip.endedAt, start.addingTimeInterval(5.0), "trip should end at the quiet-period start after the stop exceeds the threshold")
    }

    func testTripStatisticsFalsePositiveReportIncludesSensorLog() throws {
        let store = makeTripStatisticsStore()
        store.isEnabled = true
        let start = Date(timeIntervalSince1970: 70_000)

        for second in 0...5 {
            store.record(
                cue: statisticsCue(dynamicX: 0.025, dynamicY: 0.020, sampleCount: second + 1),
                now: start.addingTimeInterval(Double(second)),
                motionThreshold: 0.010
            )
        }
        store.finishOpenTrip(now: start.addingTimeInterval(6.0))

        let trip = try XCTUnwrap(store.trips.first)
        let body = store.reportBody(for: trip, comment: "I was at my desk")
        XCTAssertTrue(body.contains("I was at my desk"), "false-positive report should include the optional user comment")
        XCTAssertTrue(body.contains("at,raw_x,raw_y,raw_z,dynamic_x,dynamic_y,screen_x,screen_y,motion,sample_count"), "false-positive report should include the CSV header")
        XCTAssertTrue(body.contains("0.025000,0.020000"), "false-positive report should include dynamic acceleration samples")

        let mailURL = store.falsePositiveMailURL(for: trip.id, comment: "I was at my desk")
        XCTAssertEqual(mailURL?.scheme, "mailto", "false-positive report should use mailto")
        XCTAssertTrue(mailURL?.absoluteString.contains("jcllobet@gmail.com") == true, "false-positive report should be addressed to the configured inbox")
    }

    func testStatusTextReportsWaitingLiveAndStaleSamples() throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let processor = MotionProcessor(now: { currentDate })
        XCTAssertTrue(processor.statusText() == "Sensor: waiting for samples", "status should report waiting before samples")

        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        XCTAssertTrue(processor.statusText() == "Sensor: 1 samples", "status should report live sample count")

        currentDate = currentDate.addingTimeInterval(0.51)
        XCTAssertEqual(
            processor.statusText(maximumSampleAge: 0.5),
            "Sensor: stale samples",
            "menu status must use the same freshness boundary as rendering and auto detection"
        )
        XCTAssertEqual(processor.statusText(), "Sensor: 1 samples", "the diagnostic default keeps its two-second window")

        currentDate = currentDate.addingTimeInterval(2.49)
        XCTAssertTrue(processor.statusText() == "Sensor: stale samples", "status should report stale samples")
    }

    private func autoCue(dynamicX: Double, sampleCount: Int) -> VehicleMotionCue {
        VehicleMotionCue(
            screenX: 0.0,
            screenY: 0.0,
            hasSamples: true,
            dynamicX: dynamicX,
            dynamicY: 0.0,
            sampleCount: sampleCount
        )
    }

    private func makeTripStatisticsStore() -> TripStatisticsStore {
        let suiteName = "NomasMotionCoreTests.TripStatistics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 3.0,
            tripQuietEndSeconds: 5.0,
            preludeSeconds: 2
        )
    }

    private func statisticsCue(dynamicX: Double, dynamicY: Double = 0.0, sampleCount: Int) -> VehicleMotionCue {
        VehicleMotionCue(
            screenX: dynamicX,
            screenY: dynamicY,
            motion: dynamicX == 0.0 && dynamicY == 0.0 ? .still : .complex,
            hasSamples: true,
            rawX: dynamicX,
            rawY: dynamicY,
            rawZ: 1.0,
            dynamicX: dynamicX,
            dynamicY: dynamicY,
            sampleCount: sampleCount
        )
    }
}
