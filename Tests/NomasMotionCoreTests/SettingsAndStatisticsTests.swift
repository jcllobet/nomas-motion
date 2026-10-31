import Foundation
import XCTest
@testable import NomasMotionCore

final class SettingsAndStatisticsTests: XCTestCase {
    func testSettingsRoundTripValidatesTuningAndColor() {
        let defaults = makeDefaults()
        let store = NomasMotionSettingsStore(defaults: defaults)
        var tuning = NomasMotionTuning.defaults
        tuning.horizontalGain = 10_000.0
        tuning.verticalDeadband = .nan

        store.update(tuning: tuning, dotColorRawValue: 2)

        let reloaded = NomasMotionSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dotColorRawValue, 2)
        XCTAssertEqual(reloaded.tuning.horizontalGain, 2_400.0)
        XCTAssertEqual(reloaded.tuning.verticalDeadband, NomasMotionTuning.defaults.verticalDeadband)
    }

    func testCorruptSettingsAreIgnoredWithoutBeingOverwritten() {
        let defaults = makeDefaults()
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])
        defaults.set(corrupt, forKey: NomasMotionSettingsStore.key)

        let store = NomasMotionSettingsStore(defaults: defaults)

        XCTAssertEqual(store.settings, NomasMotionSettings(tuning: .defaults, dotColorRawValue: 0))
        XCTAssertEqual(defaults.data(forKey: NomasMotionSettingsStore.key), corrupt)
    }

    func testResetSettingsRestoresTuningAndColor() {
        let defaults = makeDefaults()
        let store = NomasMotionSettingsStore(defaults: defaults)
        var tuning = NomasMotionTuning.defaults
        tuning.autoEnableEnabled = false
        store.update(tuning: tuning, dotColorRawValue: 1)

        store.reset()

        XCTAssertEqual(store.settings, NomasMotionSettings(tuning: .defaults, dotColorRawValue: 0))
        XCTAssertEqual(NomasMotionSettingsStore(defaults: defaults).settings, store.settings)
    }

    func testActivationThresholdValidationMatchesProcessorFloor() {
        var tuning = NomasMotionTuning.defaults
        tuning.motionActivationThresholdMetersPerSecondSquared = 0.0

        let validated = NomasMotionSettingsStore.validated(tuning)

        XCTAssertEqual(
            validated.motionActivationThresholdMetersPerSecondSquared,
            nomasMotionMinimumActivationThresholdMetersPerSecondSquared,
            accuracy: 0.000_000_001
        )
    }

    func testActiveTripCheckpointRecoversAndEndsAtLastFreshSample() throws {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 100_000)
        let first = TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 1.0,
            tripQuietEndSeconds: 100.0,
            preludeSeconds: 2
        )
        first.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        first.record(cue: cue(sampleCount: 2), now: start.addingTimeInterval(1.0), motionThreshold: 0.01)

        let recovered = TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 1.0,
            tripQuietEndSeconds: 100.0,
            preludeSeconds: 2
        )
        XCTAssertTrue(recovered.hasOpenTrip)

        recovered.finishOpenTrip(now: start.addingTimeInterval(20.0), atLastFreshSample: true)

        let trip = try XCTUnwrap(recovered.trips.first)
        XCTAssertEqual(trip.endedAt, start.addingTimeInterval(1.0))
        XCTAssertFalse(TripStatisticsStore(defaults: defaults).hasOpenTrip)
    }

    func testPreTripQuietSampleResetsContinuousQualification() throws {
        let store = TripStatisticsStore(
            defaults: makeDefaults(),
            minimumTripMotionSeconds: 3.0,
            tripQuietEndSeconds: 10.0,
            preludeSeconds: 2
        )
        let start = Date(timeIntervalSince1970: 150_000)

        store.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 2, dynamicX: 0.0), now: start.addingTimeInterval(1.0), motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 3, dynamicX: 0.0), now: start.addingTimeInterval(5.0), motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 4), now: start.addingTimeInterval(6.0), motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 5), now: start.addingTimeInterval(7.0), motionThreshold: 0.01)

        XCTAssertFalse(store.hasOpenTrip, "a second pulse must not inherit elapsed time from a pre-trip pulse")

        store.record(cue: cue(sampleCount: 6), now: start.addingTimeInterval(9.0), motionThreshold: 0.01)

        XCTAssertTrue(store.hasOpenTrip, "a fresh continuous motion window should qualify normally")
    }

    func testPreTripSampleGapDoesNotCountAsSustainedMotion() {
        let store = TripStatisticsStore(
            defaults: makeDefaults(),
            minimumTripMotionSeconds: 3.0,
            tripQuietEndSeconds: 300.0,
            preludeSeconds: 1
        )
        let start = Date(timeIntervalSince1970: 160_000)

        store.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 2), now: start.addingTimeInterval(299.0), motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 3), now: start.addingTimeInterval(300.0), motionThreshold: 0.01)

        XCTAssertFalse(store.hasOpenTrip, "missing samples must not become motion evidence")
    }

    func testActiveTripSampleGapEndsAtLastFreshSampleBeforeRequalification() throws {
        let defaults = makeDefaults()
        let store = TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 1.0,
            tripQuietEndSeconds: 5.0,
            preludeSeconds: 1
        )
        let start = Date(timeIntervalSince1970: 175_000)

        store.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 2), now: start.addingTimeInterval(1.0), motionThreshold: 0.01)
        XCTAssertTrue(store.hasOpenTrip)

        store.record(cue: cue(sampleCount: 3), now: start.addingTimeInterval(7.0), motionThreshold: 0.01)

        let firstTrip = try XCTUnwrap(store.trips.first)
        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(firstTrip.endedAt, start.addingTimeInterval(1.0))
        XCTAssertFalse(store.hasOpenTrip, "the resumed sample starts a new qualification window")

        store.record(cue: cue(sampleCount: 4), now: start.addingTimeInterval(8.0), motionThreshold: 0.01)
        XCTAssertTrue(store.hasOpenTrip)
    }

    func testNegativePreludeIsClampedWithoutCrashingOrDroppingCurrentSample() throws {
        let store = TripStatisticsStore(
            defaults: makeDefaults(),
            minimumTripMotionSeconds: 0.0,
            tripQuietEndSeconds: 5.0,
            preludeSeconds: -10
        )
        let start = Date(timeIntervalSince1970: 190_000)

        store.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        store.finishOpenTrip(now: start)

        let trip = try XCTUnwrap(store.trips.first)
        XCTAssertEqual(trip.sampleCount, 1, "a zero-length prelude still retains the qualifying sample")
    }

    func testActiveCheckpointAndReportRowsAreBounded() throws {
        struct Checkpoint: Codable {
            let id: String
            let startedAt: Date
            let endedAt: Date
            let snapshots: [TripSnapshot]
            let quietStartedAt: Date?
        }

        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 220_000)
        let snapshots = (0..<4_000).map { index in
            cue(sampleCount: index + 1).snapshot(at: start.addingTimeInterval(Double(index)))
        }
        let checkpoint = Checkpoint(
            id: "bounded",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_999.0),
            snapshots: snapshots,
            quietStartedAt: nil
        )
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: "NomasMotion.ActiveTrip")

        let store = TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 1.0,
            tripQuietEndSeconds: 5.0,
            preludeSeconds: 2
        )
        store.finishOpenTrip(now: start.addingTimeInterval(5_000.0), atLastFreshSample: true)

        let trip = try XCTUnwrap(store.trips.first)
        XCTAssertEqual(trip.sampleCount, 3_600, "active checkpoints must retain a bounded one-hour sample window")

        let body = store.reportBody(for: trip, comment: "")
        XCTAssertTrue(body.contains("report_rows: 120/3600"))
        let csv = try XCTUnwrap(body.components(separatedBy: "CSV:\n").last)
        XCTAssertEqual(csv.split(separator: "\n").count, 121, "mail reports must cap CSV rows while stating the total")
    }

    func testActiveCheckpointWritesAreRateLimited() throws {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 240_000)
        let store = TripStatisticsStore(
            defaults: defaults,
            minimumTripMotionSeconds: 1.0,
            tripQuietEndSeconds: 300.0,
            preludeSeconds: 1
        )
        store.record(cue: cue(sampleCount: 1), now: start, motionThreshold: 0.01)
        store.record(cue: cue(sampleCount: 2), now: start.addingTimeInterval(1.0), motionThreshold: 0.01)
        let promotedCheckpoint = try XCTUnwrap(defaults.data(forKey: "NomasMotion.ActiveTrip"))

        store.record(cue: cue(sampleCount: 3), now: start.addingTimeInterval(2.0), motionThreshold: 0.01)
        XCTAssertEqual(defaults.data(forKey: "NomasMotion.ActiveTrip"), promotedCheckpoint)

        store.record(cue: cue(sampleCount: 4), now: start.addingTimeInterval(31.0), motionThreshold: 0.01)
        XCTAssertNotEqual(defaults.data(forKey: "NomasMotion.ActiveTrip"), promotedCheckpoint)
    }

    func testStatisticsRetainTwentyMostRecentTrips() throws {
        let store = TripStatisticsStore(
            defaults: makeDefaults(),
            minimumTripMotionSeconds: 0.0,
            tripQuietEndSeconds: 100.0,
            preludeSeconds: 1
        )
        let start = Date(timeIntervalSince1970: 200_000)

        for index in 0..<21 {
            let at = start.addingTimeInterval(Double(index))
            store.record(cue: cue(sampleCount: index + 1), now: at, motionThreshold: 0.01)
            store.finishOpenTrip(now: at)
        }

        XCTAssertEqual(store.trips.count, 20)
        XCTAssertEqual(store.trips.first?.startedAt, start.addingTimeInterval(1.0))
        XCTAssertEqual(store.trips.last?.startedAt, start.addingTimeInterval(20.0))
    }

    func testCSVUsesPOSIXDecimalSeparator() throws {
        let store = TripStatisticsStore(defaults: makeDefaults())
        let at = Date(timeIntervalSince1970: 300_000)
        let trip = TripRecord(
            id: "csv",
            startedAt: at,
            endedAt: at,
            snapshots: [cue(sampleCount: 1, dynamicX: 0.125).snapshot(at: at)]
        )

        let body = store.reportBody(for: trip, comment: "")
        XCTAssertTrue(body.contains("0.125000"))
        XCTAssertFalse(body.contains("0,125000"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "NomasMotionCoreTests.SettingsAndStatistics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func cue(sampleCount: Int, dynamicX: Double = 0.03) -> VehicleMotionCue {
        VehicleMotionCue(
            screenX: dynamicX,
            screenY: 0.0,
            motion: .complex,
            hasSamples: true,
            dynamicX: dynamicX,
            sampleCount: sampleCount
        )
    }
}

private extension VehicleMotionCue {
    func snapshot(at date: Date) -> TripSnapshot {
        TripSnapshot(cue: self, at: date)
    }
}
