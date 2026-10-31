import Foundation

public struct TripRecord: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public var endedAt: Date
    public var snapshots: [TripSnapshot]

    public var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    public var sampleCount: Int {
        snapshots.count
    }
}

public struct TripSnapshot: Codable, Equatable, Sendable {
    public let at: Date
    public let rawX: Double
    public let rawY: Double
    public let rawZ: Double
    public let dynamicX: Double
    public let dynamicY: Double
    public let screenX: Double
    public let screenY: Double
    public let motion: String
    public let sampleCount: Int

    public init(cue: VehicleMotionCue, at: Date) {
        self.at = at
        self.rawX = cue.rawX
        self.rawY = cue.rawY
        self.rawZ = cue.rawZ
        self.dynamicX = cue.dynamicX
        self.dynamicY = cue.dynamicY
        self.screenX = cue.screenX
        self.screenY = cue.screenY
        self.motion = cue.motion.rawValue
        self.sampleCount = cue.sampleCount
    }
}

public final class TripStatisticsStore {
    private static let maximumRetainedTrips = 20
    /// Samples arrive at roughly 1 Hz. One hour is enough to diagnose a trip
    /// without allowing a day-long ride to grow UserDefaults without bound.
    private static let maximumStoredSnapshotsPerTrip = 3_600
    private static let maximumReportSnapshots = 120
    private static let maximumReportCommentCharacters = 2_000
    private static let activeCheckpointInterval: TimeInterval = 30.0
    private static let maximumCandidateSampleGap: TimeInterval = 2.0

    private struct ActiveTrip: Codable {
        let id: String
        let startedAt: Date
        var endedAt: Date
        var snapshots: [TripSnapshot]
        var quietStartedAt: Date?
    }

    private let defaults: UserDefaults
    private let enabledKey = "NomasMotion.StatisticsEnabled"
    private let tripsKey = "NomasMotion.Trips"
    private let activeTripKey = "NomasMotion.ActiveTrip"
    private let minimumTripMotionSeconds: TimeInterval
    private let tripQuietEndSeconds: TimeInterval
    private let preludeSeconds: Int

    public private(set) var trips: [TripRecord]
    private var activeTrip: ActiveTrip?
    private var motionStartedAt: Date?
    private var quietStartedAt: Date?
    private var preludeSnapshots: [TripSnapshot] = []
    private var candidateSnapshots: [TripSnapshot] = []
    private var lastRecordedAt: Date?
    private var lastCheckpointAt: Date?
    public var onChange: (() -> Void)?

    public var hasOpenTrip: Bool {
        activeTrip != nil
    }

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
            if !isEnabled {
                resetActiveTrip()
                defaults.removeObject(forKey: activeTripKey)
            }
            onChange?()
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        minimumTripMotionSeconds: TimeInterval = 300.0,
        tripQuietEndSeconds: TimeInterval = 300.0,
        preludeSeconds: Int = 120
    ) {
        self.defaults = defaults
        self.minimumTripMotionSeconds = max(0.0, minimumTripMotionSeconds)
        self.tripQuietEndSeconds = max(0.0, tripQuietEndSeconds)
        self.preludeSeconds = min(Self.maximumStoredSnapshotsPerTrip, max(0, preludeSeconds))
        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        if let data = defaults.data(forKey: tripsKey) {
            do {
                let decoded = try JSONDecoder().decode([TripRecord].self, from: data)
                self.trips = decoded
                    .suffix(Self.maximumRetainedTrips)
                    .map(Self.boundedRecord)
            } catch {
                fputs("Nomas Motion: ignoring invalid trip statistics payload: \(error)\n", stderr)
                self.trips = []
            }
        } else {
            self.trips = []
        }

        if let data = defaults.data(forKey: activeTripKey) {
            do {
                var recovered = try JSONDecoder().decode(ActiveTrip.self, from: data)
                recovered.snapshots = Self.boundedSnapshots(recovered.snapshots)
                guard !recovered.snapshots.isEmpty else {
                    throw StatisticsStoreError.emptyCheckpoint
                }
                self.activeTrip = recovered
                self.motionStartedAt = recovered.startedAt
                self.quietStartedAt = recovered.quietStartedAt
                self.lastRecordedAt = recovered.snapshots.last?.at
                self.lastCheckpointAt = recovered.endedAt
                self.preludeSnapshots = Array(recovered.snapshots.suffix(preludeSeconds))
                self.candidateSnapshots = recovered.snapshots
            } catch {
                fputs("Nomas Motion: ignoring invalid active-trip checkpoint: \(error)\n", stderr)
            }
        }
    }

    public func record(cue: VehicleMotionCue, now: Date, motionThreshold: Double) {
        guard isEnabled,
              cue.hasSamples,
              cue.rawX.isFinite,
              cue.rawY.isFinite,
              cue.rawZ.isFinite,
              cue.dynamicX.isFinite,
              cue.dynamicY.isFinite,
              cue.screenX.isFinite,
              cue.screenY.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite
        else {
            return
        }
        if let lastRecordedAt, now < lastRecordedAt {
            return
        }

        // A sensor outage is not a quiet vehicle interval. Close an active
        // trip at its last fresh sample before treating the resumed sample as
        // a new qualification candidate.
        if let lastRecordedAt,
           now.timeIntervalSince(lastRecordedAt) >= tripQuietEndSeconds {
            if activeTrip != nil {
                guard finishActiveTrip(endedAt: lastRecordedAt) else {
                    return
                }
                resetActiveTrip()
            } else {
                resetCandidate()
                quietStartedAt = nil
            }
        }
        if activeTrip == nil,
           motionStartedAt != nil,
           let lastRecordedAt,
           now.timeIntervalSince(lastRecordedAt) > Self.maximumCandidateSampleGap {
            resetCandidate()
        }

        let snapshot = TripSnapshot(cue: cue, at: now)
        appendPrelude(snapshot)

        let moving = hypot(cue.dynamicX, cue.dynamicY) >= max(0.001, motionThreshold)
        var promotedThisSample = false
        if moving {
            if motionStartedAt == nil {
                motionStartedAt = now
                candidateSnapshots = preludeSnapshots
                // With a zero-length prelude the current sample still belongs
                // in the candidate. For a nonzero prelude appendPrelude has
                // already included it.
                if candidateSnapshots.last != snapshot {
                    appendStoredSnapshot(snapshot, to: &candidateSnapshots)
                }
            } else if activeTrip == nil {
                appendStoredSnapshot(snapshot, to: &candidateSnapshots)
            }
            quietStartedAt = nil

            if activeTrip == nil, let motionStartedAt, now.timeIntervalSince(motionStartedAt) >= minimumTripMotionSeconds {
                activeTrip = ActiveTrip(
                    id: UUID().uuidString,
                    startedAt: motionStartedAt,
                    endedAt: now,
                    snapshots: candidateSnapshots,
                    quietStartedAt: nil
                )
                promotedThisSample = true
            }
        } else if activeTrip != nil {
            if quietStartedAt == nil {
                quietStartedAt = now
            }
            activeTrip?.endedAt = now
            if let activeTrip {
                var updated = activeTrip
                Self.appendStoredSnapshot(snapshot, to: &updated.snapshots)
                self.activeTrip = updated
            }
        } else {
            // Qualification requires continuous fresh moving samples. A quiet
            // pre-trip sample discards elapsed candidate time but the bounded
            // prelude remains available for the next candidate.
            resetCandidate()
            quietStartedAt = nil
        }

        if activeTrip != nil, moving, !promotedThisSample {
            activeTrip?.endedAt = now
            if let activeTrip {
                var updated = activeTrip
                Self.appendStoredSnapshot(snapshot, to: &updated.snapshots)
                self.activeTrip = updated
            }
        }

        lastRecordedAt = now

        if activeTrip != nil,
           let quietStartedAt,
           now.timeIntervalSince(quietStartedAt) >= tripQuietEndSeconds {
            if finishActiveTrip(endedAt: quietStartedAt) {
                resetActiveTrip()
            } else {
                persistActiveTrip(at: now, force: true)
            }
        } else {
            persistActiveTrip(at: now, force: promotedThisSample)
        }
    }

    public func resetStatistics() {
        guard persistTrips([]) else {
            return
        }
        trips = []
        resetActiveTrip()
        defaults.removeObject(forKey: activeTripKey)
        onChange?()
    }

    /// Finish a recovered/open trip. The app uses `atLastFreshSample` during
    /// shutdown so a disconnected sensor cannot inflate the trip duration with
    /// wall-clock time that had no fresh samples. The default preserves the
    /// explicit caller-supplied end time for library clients.
    public func finishOpenTrip(now: Date, atLastFreshSample: Bool = false) {
        guard activeTrip != nil else {
            return
        }
        let endDate: Date
        if atLastFreshSample, let lastRecordedAt {
            endDate = min(now, lastRecordedAt)
        } else {
            endDate = now
        }
        if finishActiveTrip(endedAt: endDate) {
            resetActiveTrip()
        }
    }

    public func falsePositiveMailURL(for tripID: String, comment: String) -> URL? {
        guard let trip = trips.first(where: { $0.id == tripID }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "jcllobet@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Nomas Motion false motion positive"),
            URLQueryItem(name: "body", value: reportBody(for: trip, comment: comment))
        ]
        return components.url
    }

    public func reportBody(for trip: TripRecord, comment: String) -> String {
        let totalRows = trip.snapshots.count
        let includedSnapshots = Array(trip.snapshots.suffix(Self.maximumReportSnapshots))
        let boundedComment = String(comment.prefix(Self.maximumReportCommentCharacters))
        var lines: [String] = [
            "False motion positive report",
            "",
            "Optional comment:",
            boundedComment.isEmpty ? "(none)" : boundedComment,
            "",
            "Trip:",
            "id: \(trip.id)",
            "started_at: \(Self.isoString(from: trip.startedAt))",
            "ended_at: \(Self.isoString(from: trip.endedAt))",
            String(format: "duration_seconds: %.0f", trip.durationSeconds),
            "snapshot_count: \(totalRows)",
            "report_rows: \(includedSnapshots.count)/\(totalRows)",
            "",
            "CSV:",
            "at,raw_x,raw_y,raw_z,dynamic_x,dynamic_y,screen_x,screen_y,motion,sample_count"
        ]

        if comment.count > Self.maximumReportCommentCharacters {
            lines.insert("comment_truncated: true", at: 4)
        }
        if includedSnapshots.count < totalRows {
            lines.insert("report_truncated: true", at: lines.firstIndex(of: "CSV:") ?? lines.count)
        }
        lines.append(contentsOf: includedSnapshots.map(Self.csvLine))
        return lines.joined(separator: "\n")
    }

    private func appendPrelude(_ snapshot: TripSnapshot) {
        preludeSnapshots.append(snapshot)
        if preludeSnapshots.count > preludeSeconds {
            preludeSnapshots.removeFirst(preludeSnapshots.count - preludeSeconds)
        }
    }

    private func resetCandidate() {
        motionStartedAt = nil
        candidateSnapshots = []
    }

    private func appendStoredSnapshot(_ snapshot: TripSnapshot, to snapshots: inout [TripSnapshot]) {
        snapshots.append(snapshot)
        if snapshots.count > Self.maximumStoredSnapshotsPerTrip {
            snapshots.removeFirst(snapshots.count - Self.maximumStoredSnapshotsPerTrip)
        }
    }

    private static func appendStoredSnapshot(_ snapshot: TripSnapshot, to snapshots: inout [TripSnapshot]) {
        snapshots.append(snapshot)
        if snapshots.count > Self.maximumStoredSnapshotsPerTrip {
            snapshots.removeFirst(snapshots.count - Self.maximumStoredSnapshotsPerTrip)
        }
    }

    private static func boundedSnapshots(_ snapshots: [TripSnapshot]) -> [TripSnapshot] {
        Array(snapshots.suffix(Self.maximumStoredSnapshotsPerTrip))
    }

    private static func boundedRecord(_ record: TripRecord) -> TripRecord {
        var bounded = record
        bounded.snapshots = boundedSnapshots(record.snapshots)
        return bounded
    }

    @discardableResult
    private func finishActiveTrip(endedAt: Date) -> Bool {
        guard var activeTrip else {
            return false
        }
        activeTrip.endedAt = endedAt
        var nextTrips = trips
        nextTrips.append(
            TripRecord(
                id: activeTrip.id,
                startedAt: activeTrip.startedAt,
                endedAt: activeTrip.endedAt,
                snapshots: activeTrip.snapshots
            )
        )
        if nextTrips.count > Self.maximumRetainedTrips {
            nextTrips.removeFirst(nextTrips.count - Self.maximumRetainedTrips)
        }
        guard persistTrips(nextTrips) else {
            return false
        }
        trips = nextTrips
        defaults.removeObject(forKey: activeTripKey)
        onChange?()
        return true
    }

    private func resetActiveTrip() {
        activeTrip = nil
        motionStartedAt = nil
        quietStartedAt = nil
        preludeSnapshots = []
        candidateSnapshots = []
        lastRecordedAt = nil
        lastCheckpointAt = nil
    }

    @discardableResult
    private func persistTrips(_ records: [TripRecord]? = nil) -> Bool {
        do {
            let data = try JSONEncoder().encode(records ?? trips)
            defaults.set(data, forKey: tripsKey)
            return true
        } catch {
            fputs("Nomas Motion: could not persist trip statistics: \(error)\n", stderr)
            return false
        }
    }

    private func persistActiveTrip(at now: Date, force: Bool = false) {
        guard let activeTrip else {
            defaults.removeObject(forKey: activeTripKey)
            lastCheckpointAt = nil
            return
        }
        if !force,
           let lastCheckpointAt,
           now.timeIntervalSince(lastCheckpointAt) >= 0.0,
           now.timeIntervalSince(lastCheckpointAt) < Self.activeCheckpointInterval {
            return
        }
        var checkpoint = activeTrip
        checkpoint.quietStartedAt = quietStartedAt
        do {
            defaults.set(try JSONEncoder().encode(checkpoint), forKey: activeTripKey)
            lastCheckpointAt = now
        } catch {
            fputs("Nomas Motion: could not checkpoint active trip: \(error)\n", stderr)
        }
    }

    private static func csvLine(_ snapshot: TripSnapshot) -> String {
        [
            isoString(from: snapshot.at),
            csvNumber(snapshot.rawX),
            csvNumber(snapshot.rawY),
            csvNumber(snapshot.rawZ),
            csvNumber(snapshot.dynamicX),
            csvNumber(snapshot.dynamicY),
            csvNumber(snapshot.screenX),
            csvNumber(snapshot.screenY),
            snapshot.motion,
            String(snapshot.sampleCount)
        ].joined(separator: ",")
    }

    private static func csvNumber(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private enum StatisticsStoreError: Error {
        case emptyCheckpoint
    }
}
