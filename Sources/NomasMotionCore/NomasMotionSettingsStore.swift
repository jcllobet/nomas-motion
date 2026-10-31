import Foundation

/// The settings shared by the app and its non-AppKit targets.
///
/// DotColorMode lives in the AppKit overlay target, so persistence stores its
/// stable raw value instead of making the core target depend on AppKit.
public struct NomasMotionSettings: Equatable, Sendable {
    public let tuning: NomasMotionTuning
    public let dotColorRawValue: Int

    public init(tuning: NomasMotionTuning, dotColorRawValue: Int) {
        self.tuning = tuning
        self.dotColorRawValue = dotColorRawValue
    }
}

/// Loads settings once and writes only validated values.
///
/// A malformed payload is ignored and left in UserDefaults for diagnosis; it
/// is never replaced during initialization with a default payload.
public final class NomasMotionSettingsStore: @unchecked Sendable {
    public static let key = "NomasMotion.Settings.v1"

    private struct StoredSettings: Codable {
        let schemaVersion: Int
        let tuning: StoredTuning
        let dotColorRawValue: Int
    }

    private struct StoredTuning: Codable {
        let smoothingAlpha: Double
        let horizontalGain: Double
        let verticalGain: Double
        let motionSpeedScale: Double
        let horizontalDeadband: Double
        let verticalDeadband: Double
        let horizontalMaxOffset: Double
        let verticalMaxOffset: Double
        let motionActivationThresholdMetersPerSecondSquared: Double
        let dotAlphaScale: Double
        let dotSizeScale: Double
        let autoEnableEnabled: Bool
        let autoEnableThreshold: Double
        let autoEnableWindowSeconds: Double
        let autoDisableQuietSeconds: Double

        init(tuning: NomasMotionTuning) {
            smoothingAlpha = tuning.smoothingAlpha
            horizontalGain = tuning.horizontalGain
            verticalGain = tuning.verticalGain
            motionSpeedScale = tuning.motionSpeedScale
            horizontalDeadband = tuning.horizontalDeadband
            verticalDeadband = tuning.verticalDeadband
            horizontalMaxOffset = tuning.horizontalMaxOffset
            verticalMaxOffset = tuning.verticalMaxOffset
            motionActivationThresholdMetersPerSecondSquared = tuning.motionActivationThresholdMetersPerSecondSquared
            dotAlphaScale = tuning.dotAlphaScale
            dotSizeScale = tuning.dotSizeScale
            autoEnableEnabled = tuning.autoEnableEnabled
            autoEnableThreshold = tuning.autoEnableThreshold
            autoEnableWindowSeconds = tuning.autoEnableWindowSeconds
            autoDisableQuietSeconds = tuning.autoDisableQuietSeconds
        }

        func tuning() -> NomasMotionTuning {
            NomasMotionTuning(
                smoothingAlpha: smoothingAlpha,
                horizontalGain: horizontalGain,
                verticalGain: verticalGain,
                motionSpeedScale: motionSpeedScale,
                horizontalDeadband: horizontalDeadband,
                verticalDeadband: verticalDeadband,
                horizontalMaxOffset: horizontalMaxOffset,
                verticalMaxOffset: verticalMaxOffset,
                motionActivationThresholdMetersPerSecondSquared: motionActivationThresholdMetersPerSecondSquared,
                dotAlphaScale: dotAlphaScale,
                dotSizeScale: dotSizeScale,
                autoEnableEnabled: autoEnableEnabled,
                autoEnableThreshold: autoEnableThreshold,
                autoEnableWindowSeconds: autoEnableWindowSeconds,
                autoDisableQuietSeconds: autoDisableQuietSeconds
            )
        }
    }

    private let defaults: UserDefaults
    public private(set) var settings: NomasMotionSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    public var tuning: NomasMotionTuning { settings.tuning }
    public var dotColorRawValue: Int { settings.dotColorRawValue }

    public func update(tuning: NomasMotionTuning, dotColorRawValue: Int? = nil) {
        let next = NomasMotionSettings(
            tuning: Self.validated(tuning),
            dotColorRawValue: Self.validatedDotColorRawValue(dotColorRawValue ?? settings.dotColorRawValue)
        )
        settings = next
        persist(next)
    }

    public func updateDotColorRawValue(_ rawValue: Int) {
        update(tuning: settings.tuning, dotColorRawValue: rawValue)
    }

    public func reset() {
        let next = NomasMotionSettings(tuning: .defaults, dotColorRawValue: 0)
        settings = next
        persist(next)
    }

    public static func validated(_ tuning: NomasMotionTuning) -> NomasMotionTuning {
        let defaults = NomasMotionTuning.defaults
        return NomasMotionTuning(
            smoothingAlpha: bounded(tuning.smoothingAlpha, fallback: defaults.smoothingAlpha, min: 0.02, max: 0.30),
            horizontalGain: bounded(tuning.horizontalGain, fallback: defaults.horizontalGain, min: 0.0, max: 2_400.0),
            verticalGain: bounded(tuning.verticalGain, fallback: defaults.verticalGain, min: 0.0, max: 2_400.0),
            motionSpeedScale: bounded(tuning.motionSpeedScale, fallback: defaults.motionSpeedScale, min: 0.3, max: 3.0),
            horizontalDeadband: bounded(tuning.horizontalDeadband, fallback: defaults.horizontalDeadband, min: 0.0, max: 0.06),
            verticalDeadband: bounded(tuning.verticalDeadband, fallback: defaults.verticalDeadband, min: 0.0, max: 0.06),
            horizontalMaxOffset: bounded(tuning.horizontalMaxOffset, fallback: defaults.horizontalMaxOffset, min: 0.0, max: 1_920.0),
            verticalMaxOffset: bounded(tuning.verticalMaxOffset, fallback: defaults.verticalMaxOffset, min: 0.0, max: 1_920.0),
            motionActivationThresholdMetersPerSecondSquared: bounded(
                tuning.motionActivationThresholdMetersPerSecondSquared,
                fallback: defaults.motionActivationThresholdMetersPerSecondSquared,
                min: nomasMotionMinimumActivationThresholdMetersPerSecondSquared,
                max: 1.50
            ),
            dotAlphaScale: bounded(tuning.dotAlphaScale, fallback: defaults.dotAlphaScale, min: 0.2, max: 1.4),
            dotSizeScale: bounded(tuning.dotSizeScale, fallback: defaults.dotSizeScale, min: 0.5, max: 1.6),
            autoEnableEnabled: tuning.autoEnableEnabled,
            autoEnableThreshold: bounded(tuning.autoEnableThreshold, fallback: defaults.autoEnableThreshold, min: 0.005, max: 0.12),
            autoEnableWindowSeconds: bounded(tuning.autoEnableWindowSeconds, fallback: defaults.autoEnableWindowSeconds, min: 2.0, max: 30.0),
            autoDisableQuietSeconds: bounded(tuning.autoDisableQuietSeconds, fallback: defaults.autoDisableQuietSeconds, min: 60.0, max: 600.0)
        )
    }

    private static func load(from defaults: UserDefaults) -> NomasMotionSettings {
        guard let data = defaults.data(forKey: key) else {
            return NomasMotionSettings(tuning: .defaults, dotColorRawValue: 0)
        }

        do {
            let stored = try JSONDecoder().decode(StoredSettings.self, from: data)
            guard stored.schemaVersion == 1 else {
                throw SettingsStoreError.unsupportedSchema(stored.schemaVersion)
            }
            let tuning = validated(stored.tuning.tuning())
            let color = validatedDotColorRawValue(stored.dotColorRawValue)
            return NomasMotionSettings(tuning: tuning, dotColorRawValue: color)
        } catch {
            fputs("Nomas Motion: ignoring invalid settings payload: \(error)\n", stderr)
            return NomasMotionSettings(tuning: .defaults, dotColorRawValue: 0)
        }
    }

    private func persist(_ settings: NomasMotionSettings) {
        let payload = StoredSettings(
            schemaVersion: 1,
            tuning: StoredTuning(tuning: settings.tuning),
            dotColorRawValue: settings.dotColorRawValue
        )
        do {
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: Self.key)
        } catch {
            fputs("Nomas Motion: could not persist settings: \(error)\n", stderr)
        }
    }

    private static func bounded(_ value: Double, fallback: Double, min: Double, max: Double) -> Double {
        guard value.isFinite else {
            return fallback
        }
        return Swift.min(max, Swift.max(min, value))
    }

    private static func validatedDotColorRawValue(_ rawValue: Int) -> Int {
        rawValue >= 0 && rawValue <= 2 ? rawValue : 0
    }

    private enum SettingsStoreError: Error {
        case unsupportedSchema(Int)
    }
}
