import Foundation

public let nomasMotionDefaultSmoothingAlpha = 0.13575524816363319

public struct MotionVisualPreset: Equatable, Sendable {
    public let horizontalGain: Double
    public let verticalGain: Double
    public let motionSpeedScale: Double
    public let horizontalDeadband: Double
    public let verticalDeadband: Double
    public let horizontalMaxOffset: Double
    public let verticalMaxOffset: Double

    public init(
        horizontalGain: Double,
        verticalGain: Double,
        motionSpeedScale: Double,
        horizontalDeadband: Double,
        verticalDeadband: Double,
        horizontalMaxOffset: Double,
        verticalMaxOffset: Double
    ) {
        self.horizontalGain = horizontalGain
        self.verticalGain = verticalGain
        self.motionSpeedScale = motionSpeedScale
        self.horizontalDeadband = horizontalDeadband
        self.verticalDeadband = verticalDeadband
        self.horizontalMaxOffset = horizontalMaxOffset
        self.verticalMaxOffset = verticalMaxOffset
    }

    public static let mvp = NomasMotionTuning.defaults.visualPreset
}

public struct NomasMotionTuning: Equatable, Sendable {
    public var smoothingAlpha: Double
    public var horizontalGain: Double
    public var verticalGain: Double
    public var motionSpeedScale: Double
    public var horizontalDeadband: Double
    public var verticalDeadband: Double
    public var horizontalMaxOffset: Double
    public var verticalMaxOffset: Double
    public var motionActivationThresholdMetersPerSecondSquared: Double
    public var dotAlphaScale: Double
    public var dotSizeScale: Double
    public var autoEnableEnabled: Bool
    public var autoEnableThreshold: Double
    public var autoEnableWindowSeconds: Double
    public var autoDisableQuietSeconds: Double

    public init(
        smoothingAlpha: Double,
        horizontalGain: Double,
        verticalGain: Double,
        motionSpeedScale: Double,
        horizontalDeadband: Double,
        verticalDeadband: Double,
        horizontalMaxOffset: Double,
        verticalMaxOffset: Double,
        motionActivationThresholdMetersPerSecondSquared: Double,
        dotAlphaScale: Double,
        dotSizeScale: Double,
        autoEnableEnabled: Bool,
        autoEnableThreshold: Double,
        autoEnableWindowSeconds: Double,
        autoDisableQuietSeconds: Double
    ) {
        self.smoothingAlpha = smoothingAlpha
        self.horizontalGain = horizontalGain
        self.verticalGain = verticalGain
        self.motionSpeedScale = motionSpeedScale
        self.horizontalDeadband = horizontalDeadband
        self.verticalDeadband = verticalDeadband
        self.horizontalMaxOffset = horizontalMaxOffset
        self.verticalMaxOffset = verticalMaxOffset
        self.motionActivationThresholdMetersPerSecondSquared = motionActivationThresholdMetersPerSecondSquared
        self.dotAlphaScale = dotAlphaScale
        self.dotSizeScale = dotSizeScale
        self.autoEnableEnabled = autoEnableEnabled
        self.autoEnableThreshold = autoEnableThreshold
        self.autoEnableWindowSeconds = autoEnableWindowSeconds
        self.autoDisableQuietSeconds = autoDisableQuietSeconds
    }

    public static let defaults = NomasMotionTuning(
        smoothingAlpha: nomasMotionDefaultSmoothingAlpha,
        horizontalGain: 320.0,
        verticalGain: 520.0,
        motionSpeedScale: 1.0,
        horizontalDeadband: 0.012,
        verticalDeadband: 0.008,
        horizontalMaxOffset: 64.0,
        verticalMaxOffset: 72.0,
        motionActivationThresholdMetersPerSecondSquared: 0.00980665,
        dotAlphaScale: 1.0,
        dotSizeScale: 1.0,
        autoEnableEnabled: true,
        autoEnableThreshold: 0.020,
        autoEnableWindowSeconds: 15.0,
        autoDisableQuietSeconds: 120.0
    )

    public var visualPreset: MotionVisualPreset {
        MotionVisualPreset(
            horizontalGain: horizontalGain,
            verticalGain: verticalGain,
            motionSpeedScale: motionSpeedScale,
            horizontalDeadband: horizontalDeadband,
            verticalDeadband: verticalDeadband,
            horizontalMaxOffset: horizontalMaxOffset,
            verticalMaxOffset: verticalMaxOffset
        )
    }
}
