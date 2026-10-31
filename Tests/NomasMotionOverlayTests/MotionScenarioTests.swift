import XCTest
import NomasMotionCore
import NomasMotionOverlay

final class MotionScenarioTests: XCTestCase {
    func testTransientVehicleMotionScenarios() throws {
        struct Scenario {
            let name: String
            let run: () -> CGSize
            let expectation: (CGSize) -> Bool
            let note: String
        }

        let scenarioEpoch = Date(timeIntervalSince1970: 110_000)

        func seededProcessor(now: @escaping () -> Date = { scenarioEpoch }) -> MotionProcessor {
            let processor = MotionProcessor(now: now)
            processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
            return processor
        }

        func dotVelocity(_ processor: MotionProcessor) -> CGSize {
            OverlayController.dotVelocity(for: processor.currentCue(), tuning: .defaults)
        }

        func ingestRepeated(_ processor: MotionProcessor, count: Int, x: Double, y: Double, z: Double) {
            for _ in 0..<count { processor.ingestScaled(x: x, y: y, z: z) }
        }

        func fusedSample(userX: Double = 0.0, userY: Double = 0.0, timestamp: Double) -> FusedMotionSample {
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
                timestamp: timestamp
            )
        }

        func nearZero(_ offset: CGSize) -> Bool {
            abs(offset.width) < 0.75 && abs(offset.height) < 0.75
        }

        func formatOffset(_ value: CGFloat) -> String {
            String(format: "%.3f", Double(value))
        }

        let scenarios = [
            Scenario(
                name: "rest-small-noise",
                run: {
                    let processor = seededProcessor()
                    processor.ingestScaled(x: 0.001, y: -0.001, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { nearZero($0) },
                note: "small sensor noise produces no visible cue"
            ),
            Scenario(
                name: "static-tilt-decay",
                run: {
                    var currentTime = Date(timeIntervalSince1970: 110_000)
                    let processor = seededProcessor(now: { currentTime })
                    for _ in 0..<2_000 {
                        currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
                        processor.ingestScaled(x: 0.18, y: -0.12, z: 0.98)
                    }
                    return dotVelocity(processor)
                },
                expectation: { nearZero($0) },
                note: "held tilt is learned as orientation and does not persist as vehicle motion"
            ),
            Scenario(
                name: "forward-acceleration-backward-dots",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: 0.0, y: -0.20, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { abs($0.width) < 0.000_001 && $0.height < 0.0 },
                note: "accelerating forward moves dots backward/down"
            ),
            Scenario(
                name: "braking-forward-dots",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: 0.0, y: 0.20, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { abs($0.width) < 0.000_001 && $0.height > 0.0 },
                note: "braking moves dots forward/up"
            ),
            Scenario(
                name: "left-turn-right-dots",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: 0.20, y: 0.0, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { $0.width > 0.0 && abs($0.height) < 0.000_001 },
                note: "left turn moves dots right, opposite the turn"
            ),
            Scenario(
                name: "right-turn-left-dots",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: -0.20, y: 0.0, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { $0.width < 0.0 && abs($0.height) < 0.000_001 },
                note: "right turn moves dots left, opposite the turn"
            ),
            Scenario(
                name: "six-axis-constant-speed-cruise-returns-zero",
                run: {
                    let processor = MotionProcessor()
                    var timestamp = 0.0
                    processor.ingest(fusedSample(timestamp: timestamp))
                    for _ in 0..<8 {
                        timestamp += 1.0 / 60.0
                        processor.ingest(fusedSample(userY: -0.20, timestamp: timestamp))
                    }
                    for _ in 0..<180 {
                        timestamp += 1.0 / 60.0
                        processor.ingest(fusedSample(timestamp: timestamp))
                    }
                    return dotVelocity(processor)
                },
                expectation: { nearZero($0) },
                note: "after acceleration ends, constant speed has no persistent cue"
            ),
            Scenario(
                name: "weak-diagonal-input-preserved",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: 0.22, y: 0.07, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { $0.width > 0.0 && $0.height > 0.0 },
                note: "filter defaults preserve both physical acceleration axes"
            ),
            Scenario(
                name: "meaningful-diagonal-input-complex-motion",
                run: {
                    let processor = seededProcessor()
                    ingestRepeated(processor, count: 4, x: 0.22, y: 0.18, z: 1.0)
                    return dotVelocity(processor)
                },
                expectation: { $0.width > 0.0 && $0.height > 0.0 },
                note: "meaningful two-axis acceleration keeps horizontal and vertical compensation"
            )
        ]

        print("NomasMotionVerify scenarios")
        print("Local vehicle-motion cue contract using filter defaults")
        for scenario in scenarios {
            let offset = scenario.run()
            guard scenario.expectation(offset) else {
                XCTFail("\(scenario.name) produced dx=\(formatOffset(offset.width)) dy=\(formatOffset(offset.height))")
                continue
            }
            print("\(scenario.name): dx=\(formatOffset(offset.width)) dy=\(formatOffset(offset.height)) - \(scenario.note)")
        }
        print("PASS")
    }
}
