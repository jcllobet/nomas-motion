import Foundation

public let nomasMotionAutoDetectionInterval = 0.1

public enum TravelAutoOverlayAction: Equatable, Sendable {
    case none
    case show
    case hide
}

public struct TravelAutoDetector: Sendable {
    public private(set) var motionScoreSeconds = 0.0
    public private(set) var quietSeconds = 0.0

    private var lastUpdateAt: Date?
    private var lastSampleCount: Int?

    public init() {}

    public mutating func reset() {
        motionScoreSeconds = 0.0
        quietSeconds = 0.0
        lastUpdateAt = nil
        lastSampleCount = nil
    }

    public mutating func update(
        cue: VehicleMotionCue,
        now: Date = Date(),
        overlayVisible: Bool,
        tuning: NomasMotionTuning
    ) -> TravelAutoOverlayAction {
        guard tuning.autoEnableEnabled else {
            reset()
            return .none
        }

        // A disconnected sensor is not quiet vehicle motion. Discard prior
        // qualification evidence and remove an automatically shown overlay;
        // manual cues may remain visible but receive a zeroed renderer cue.
        guard cue.hasSamples else {
            reset()
            return overlayVisible ? .hide : .none
        }

        let dt = updateInterval(now: now)
        let hasNewSample = lastSampleCount.map { cue.sampleCount > $0 } ?? cue.hasSamples
        lastSampleCount = cue.sampleCount

        let activationThreshold = max(0.001, tuning.autoEnableThreshold)
        let releaseThreshold = activationThreshold * 0.45
        let magnitude = cue.hasSamples && hasNewSample ? hypot(cue.dynamicX, cue.dynamicY) : 0.0

        if magnitude >= activationThreshold {
            motionScoreSeconds = min(max(1.0, tuning.autoEnableWindowSeconds), motionScoreSeconds + dt)
            quietSeconds = 0.0
        } else if magnitude <= releaseThreshold {
            // Preserve evidence across the separate acceleration, turn, and brake
            // pulses of a real ride without letting one short laptop jolt trigger.
            motionScoreSeconds = max(0.0, motionScoreSeconds - dt * 0.25)
            quietSeconds += dt
        } else {
            motionScoreSeconds = max(0.0, motionScoreSeconds - dt * 0.10)
            quietSeconds = 0.0
        }

        if !overlayVisible && motionScoreSeconds >= max(1.0, tuning.autoEnableWindowSeconds) {
            return .show
        }
        if overlayVisible && quietSeconds >= max(60.0, tuning.autoDisableQuietSeconds) {
            return .hide
        }
        return .none
    }

    private mutating func updateInterval(now: Date) -> Double {
        defer { lastUpdateAt = now }
        guard let lastUpdateAt else {
            return 0.0
        }
        // A delayed timer callback must not turn one stale sample into several
        // seconds of motion evidence after wake or main-thread contention.
        return max(0.0, min(1.0, now.timeIntervalSince(lastUpdateAt)))
    }
}
