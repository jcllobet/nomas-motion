import Foundation

public let nomasMotionAccelScale = 65_536.0
public let nomasMotionStandardGravity = 9.80665

public let nomasMotionInputFilterAlpha = 0.2952182775507781
public let nomasMotionOutputFilterAlpha = 0.13575524816363319
public let nomasMotionViewFilterAlpha = 0.010363449720275758
public let nomasMotionSmoothingAlpha = nomasMotionOutputFilterAlpha
public let nomasMotionSensorNoiseDeadband = 0.001
public let nomasMotionActivationThreshold = 0.001
public let nomasMotionMinimumActivationThresholdMetersPerSecondSquared =
    nomasMotionActivationThreshold * nomasMotionStandardGravity
public let nomasMotionReleaseThreshold = 0.0005
public let nomasMotionCombinedAxisRatio = 0.45

private let inputCutoffFrequency = 4.0
private let gravityCutoffFrequency = 0.1
private let staticBiasThreshold = 0.02
private let turningRateThreshold = 0.05
private let nominalSampleInterval = 1.0 / 60.0

public enum VehicleMotionKind: String, Sendable {
    case still
    case acceleratingForward
    case braking
    case turningLeft
    case turningRight
    case complex

    public var label: String {
        switch self {
        case .still:
            return "still"
        case .acceleratingForward:
            return "accelerating forward"
        case .braking:
            return "braking"
        case .turningLeft:
            return "turning left"
        case .turningRight:
            return "turning right"
        case .complex:
            return "complex motion"
        }
    }
}

public struct VehicleMotionCue: Sendable {
    public let screenX: Double
    public let screenY: Double
    public let viewX: Double
    public let viewY: Double
    public let motion: VehicleMotionKind
    public let hasSamples: Bool
    public let rawX: Double
    public let rawY: Double
    public let rawZ: Double
    public let dynamicX: Double
    public let dynamicY: Double
    public let sampleCount: Int

    public var accelerationMetersPerSecondSquared: Double {
        hypot(dynamicX, dynamicY) * nomasMotionStandardGravity
    }

    public init(
        screenX: Double,
        screenY: Double,
        viewX: Double = 0.0,
        viewY: Double = 0.0,
        motion: VehicleMotionKind = .still,
        hasSamples: Bool,
        rawX: Double = 0.0,
        rawY: Double = 0.0,
        rawZ: Double = 0.0,
        dynamicX: Double = 0.0,
        dynamicY: Double = 0.0,
        sampleCount: Int = 0
    ) {
        self.screenX = screenX
        self.screenY = screenY
        self.viewX = viewX
        self.viewY = viewY
        self.motion = motion
        self.hasSamples = hasSamples
        self.rawX = rawX
        self.rawY = rawY
        self.rawZ = rawZ
        self.dynamicX = dynamicX
        self.dynamicY = dynamicY
        self.sampleCount = sampleCount
    }
}

public final class MotionProcessor: @unchecked Sendable {
    private let now: () -> Date
    private let lock = NSLock()

    private var gravityX = 0.0
    private var gravityY = 0.0
    private var gravityZ = 0.0
    private var fusedBiasX = 0.0
    private var fusedBiasY = 0.0
    private var inputFilterX = 0.0
    private var inputFilterY = 0.0
    private var outputFilterX = 0.0
    private var outputFilterY = 0.0
    private var viewFilterX = 0.0
    private var viewFilterY = 0.0

    private var latestX = 0.0
    private var latestY = 0.0
    private var latestZ = 0.0
    private var latestDynamicX = 0.0
    private var latestDynamicY = 0.0
    private var cueScreenX = 0.0
    private var cueScreenY = 0.0
    private var motion = VehicleMotionKind.still

    private var hasGravityEstimate = false
    private var sampleCount = 0
    private var lastSampleAt: Date?
    private var lastFusedTimestamp: Double?
    private var inputSource: InputSource?
    private var cueSmoothingAlpha = nomasMotionDefaultSmoothingAlpha
    private var activationThresholdMetersPerSecondSquared = NomasMotionTuning.defaults.motionActivationThresholdMetersPerSecondSquared

    private struct SampleTiming {
        let dt: Double
        let resetTransientFilters: Bool
    }

    private enum InputSource {
        case raw
        case fused
    }

    private let filterResetGap: TimeInterval = 0.5

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func ingest(rawX: Int32, rawY: Int32, rawZ: Int32) {
        ingestScaled(
            x: Double(rawX) / nomasMotionAccelScale,
            y: Double(rawY) / nomasMotionAccelScale,
            z: Double(rawZ) / nomasMotionAccelScale
        )
    }

    public func ingest(_ sample: RawSensorSample) {
        ingest(rawX: sample.x, rawY: sample.y, rawZ: sample.z)
    }

    public func ingest(_ sample: FusedMotionSample) {
        guard isFinite(sample) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if inputSource != .fused {
            inputSource = .fused
            lastFusedTimestamp = nil
            resetTransientFilters(clearBias: true)
        }

        let vectors = rotatedVectors(for: sample)
        let combined = (
            x: vectors.userAcceleration.x + vectors.gravity.x,
            y: vectors.userAcceleration.y + vectors.gravity.y,
            z: vectors.userAcceleration.z + vectors.gravity.z
        )
        guard isFinite(vectors), combined.x.isFinite, combined.y.isFinite, combined.z.isFinite else {
            return
        }

        guard let timing = fusedSampleTiming(timestamp: sample.timestamp) else {
            // Core Motion timestamps are monotonic. Dropping a replayed or
            // out-of-order frame is safer than moving the clock backwards and
            // poisoning the next filter interval.
            return
        }

        if timing.resetTransientFilters {
            resetTransientFilters(clearBias: true)
        }

        let sampleAt = now()
        gravityX = vectors.gravity.x
        gravityY = vectors.gravity.y
        gravityZ = vectors.gravity.z
        latestX = combined.x
        latestY = combined.y
        latestZ = combined.z
        hasGravityEstimate = true

        var dynamicX = vectors.userAcceleration.x - fusedBiasX
        var dynamicY = vectors.userAcceleration.y - fusedBiasY
        guard dynamicX.isFinite, dynamicY.isFinite else {
            resetTransientFilters(clearBias: true)
            return
        }
        if hypot(dynamicX, dynamicY) < staticBiasThreshold,
           abs(vectors.rotation.z) < turningRateThreshold {
            let biasAlpha = lowPassAlpha(cutoffFrequency: gravityCutoffFrequency, dt: timing.dt)
            fusedBiasX = lowPass(vectors.userAcceleration.x, previous: fusedBiasX, alpha: biasAlpha)
            fusedBiasY = lowPass(vectors.userAcceleration.y, previous: fusedBiasY, alpha: biasAlpha)
            dynamicX = vectors.userAcceleration.x - fusedBiasX
            dynamicY = vectors.userAcceleration.y - fusedBiasY
            guard fusedBiasX.isFinite, fusedBiasY.isFinite, dynamicX.isFinite, dynamicY.isFinite else {
                resetTransientFilters(clearBias: true)
                return
            }
        }
        lastFusedTimestamp = sample.timestamp
        processDynamic(
            x: dynamicX,
            y: dynamicY,
            dt: timing.dt
        )
        finishSample(at: sampleAt)
    }

    public func ingestScaled(x: Double, y: Double, z: Double) {
        guard x.isFinite, y.isFinite, z.isFinite else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if inputSource != .raw {
            inputSource = .raw
            lastFusedTimestamp = nil
            hasGravityEstimate = false
            resetTransientFilters(clearBias: true)
        }

        let sampleAt = now()
        let timing = sampleTiming(at: sampleAt)
        latestX = x
        latestY = y
        latestZ = z

        if !hasGravityEstimate || timing.resetTransientFilters {
            gravityX = x
            gravityY = y
            gravityZ = z
            hasGravityEstimate = true
            resetTransientFilters(clearBias: timing.resetTransientFilters)
        } else {
            let dynamicX = x - gravityX
            let dynamicY = y - gravityY
            guard dynamicX.isFinite, dynamicY.isFinite else {
                return
            }
            processDynamic(x: dynamicX, y: dynamicY, dt: timing.dt)

            let gravityAlpha = lowPassAlpha(cutoffFrequency: gravityCutoffFrequency, dt: timing.dt)
            gravityX = lowPass(x, previous: gravityX, alpha: gravityAlpha)
            gravityY = lowPass(y, previous: gravityY, alpha: gravityAlpha)
            gravityZ = lowPass(z, previous: gravityZ, alpha: gravityAlpha)
            guard gravityX.isFinite, gravityY.isFinite, gravityZ.isFinite else {
                return
            }
        }

        finishSample(at: sampleAt)
    }

    public func applyTuning(_ tuning: NomasMotionTuning) {
        lock.lock()
        let smoothingAlpha = tuning.smoothingAlpha.isFinite
            ? tuning.smoothingAlpha
            : nomasMotionDefaultSmoothingAlpha
        let activationThreshold = tuning.motionActivationThresholdMetersPerSecondSquared.isFinite
            ? tuning.motionActivationThresholdMetersPerSecondSquared
            : NomasMotionTuning.defaults.motionActivationThresholdMetersPerSecondSquared
        cueSmoothingAlpha = max(0.001, min(1.0, smoothingAlpha))
        activationThresholdMetersPerSecondSquared = max(
            nomasMotionMinimumActivationThresholdMetersPerSecondSquared,
            activationThreshold
        )
        lock.unlock()
    }

    /// Return the latest cue, optionally invalidating retained motion after the
    /// sensor stops producing samples. Callers that animate continuously should
    /// set `maximumSampleAge` so a disconnected sensor cannot leave motion
    /// frozen at its last nonzero value.
    public func currentCue(maximumSampleAge: TimeInterval? = nil) -> VehicleMotionCue {
        lock.lock()
        let hasRecentSample: Bool
        if let maximumSampleAge {
            let age = lastSampleAt.map { max(0.0, now().timeIntervalSince($0)) }
            hasRecentSample = sampleCount > 0 && age.map { $0 <= max(0.0, maximumSampleAge) } == true
        } else {
            hasRecentSample = sampleCount > 0
        }
        let hasMotionData = hasGravityEstimate && hasRecentSample
        let cue = VehicleMotionCue(
            screenX: hasMotionData ? cueScreenX : 0.0,
            screenY: hasMotionData ? cueScreenY : 0.0,
            viewX: hasMotionData ? clampPrimary(viewFilterX) : 0.0,
            viewY: hasMotionData ? clampPrimary(viewFilterY) : 0.0,
            motion: hasMotionData ? motion : .still,
            hasSamples: hasRecentSample,
            rawX: hasRecentSample ? latestX : 0.0,
            rawY: hasRecentSample ? latestY : 0.0,
            rawZ: hasRecentSample ? latestZ : 0.0,
            dynamicX: hasRecentSample ? latestDynamicX : 0.0,
            dynamicY: hasRecentSample ? latestDynamicY : 0.0,
            sampleCount: sampleCount
        )
        lock.unlock()
        return cue
    }

    public func statusText(maximumSampleAge: TimeInterval = 2.0) -> String {
        lock.lock()
        let count = sampleCount
        let age = lastSampleAt.map { now().timeIntervalSince($0) }
        lock.unlock()

        guard count > 0 else {
            return "Sensor: waiting for samples"
        }
        if let age, age > max(0.0, maximumSampleAge) {
            return "Sensor: stale samples"
        }
        return "Sensor: \(count) samples"
    }

    private func processDynamic(x: Double, y: Double, dt: Double) {
        let inputAlpha = lowPassAlpha(cutoffFrequency: inputCutoffFrequency, dt: dt)
        inputFilterX = lowPass(x, previous: inputFilterX, alpha: inputAlpha)
        inputFilterY = lowPass(y, previous: inputFilterY, alpha: inputAlpha)
        guard inputFilterX.isFinite, inputFilterY.isFinite else {
            resetTransientFilters()
            return
        }

        let thresholdG = max(
            nomasMotionSensorNoiseDeadband,
            activationThresholdMetersPerSecondSquared / nomasMotionStandardGravity
        )
        let dynamicX = applyDeadband(inputFilterX, threshold: thresholdG)
        let dynamicY = applyDeadband(inputFilterY, threshold: thresholdG)
        latestDynamicX = dynamicX
        latestDynamicY = dynamicY

        let outputAlpha = timeAdjustedAlpha(nominalAlpha: cueSmoothingAlpha, dt: dt)
        outputFilterX = lowPass(dynamicX, previous: outputFilterX, alpha: outputAlpha)
        outputFilterY = lowPass(dynamicY, previous: outputFilterY, alpha: outputAlpha)
        let viewAlpha = timeAdjustedAlpha(nominalAlpha: nomasMotionViewFilterAlpha, dt: dt)
        viewFilterX = lowPass(dynamicX, previous: viewFilterX, alpha: viewAlpha)
        viewFilterY = lowPass(dynamicY, previous: viewFilterY, alpha: viewAlpha)
        guard outputFilterX.isFinite, outputFilterY.isFinite, viewFilterX.isFinite, viewFilterY.isFinite else {
            resetTransientFilters()
            return
        }
        cueScreenX = clampPrimary(outputFilterX)
        cueScreenY = clampPrimary(outputFilterY)
        motion = classifyMotion(screenX: cueScreenX, screenY: cueScreenY)
    }

    private func resetTransientFilters(clearBias: Bool = false) {
        if clearBias {
            fusedBiasX = 0.0
            fusedBiasY = 0.0
        }
        inputFilterX = 0.0
        inputFilterY = 0.0
        outputFilterX = 0.0
        outputFilterY = 0.0
        viewFilterX = 0.0
        viewFilterY = 0.0
        latestDynamicX = 0.0
        latestDynamicY = 0.0
        cueScreenX = 0.0
        cueScreenY = 0.0
        motion = .still
    }

    private func finishSample(at sampleAt: Date) {
        sampleCount += 1
        lastSampleAt = sampleAt
    }

    private func sampleTiming(at sampleAt: Date) -> SampleTiming {
        guard let lastSampleAt else {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: false)
        }
        let measured = sampleAt.timeIntervalSince(lastSampleAt)
        guard measured.isFinite, measured > 0.0 else {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: false)
        }
        if measured > filterResetGap {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: true)
        }
        return SampleTiming(
            dt: max(1.0 / 240.0, min(1.0 / 15.0, measured)),
            resetTransientFilters: false
        )
    }

    private func fusedSampleTiming(timestamp: Double) -> SampleTiming? {
        guard timestamp.isFinite else {
            return nil
        }
        guard let lastFusedTimestamp else {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: false)
        }
        guard lastFusedTimestamp.isFinite, timestamp > lastFusedTimestamp else {
            return nil
        }
        let measured = timestamp - lastFusedTimestamp
        guard measured.isFinite, measured > 0.0 else {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: true)
        }
        if measured > filterResetGap {
            return SampleTiming(dt: nominalSampleInterval, resetTransientFilters: true)
        }
        return SampleTiming(
            dt: max(1.0 / 240.0, min(1.0 / 15.0, measured)),
            resetTransientFilters: false
        )
    }

    private func lowPassAlpha(cutoffFrequency: Double, dt: Double) -> Double {
        let factor = 2.0 * Double.pi * cutoffFrequency * dt
        return factor / (1.0 + factor)
    }

    private func timeAdjustedAlpha(nominalAlpha: Double, dt: Double) -> Double {
        guard nominalAlpha < 1.0 else {
            return 1.0
        }
        let nominalRatio = nominalAlpha / (1.0 - nominalAlpha)
        let adjustedRatio = nominalRatio * dt / nominalSampleInterval
        return adjustedRatio / (1.0 + adjustedRatio)
    }

    private func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1.0 - alpha) * previous
    }

    private func applyDeadband(_ value: Double, threshold: Double) -> Double {
        abs(value) < threshold ? 0.0 : value
    }

    private func clampPrimary(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0.0
        }
        return max(-1.0, min(1.0, value))
    }

    private func rotatedVectors(for sample: FusedMotionSample) -> (
        userAcceleration: (x: Double, y: Double, z: Double),
        gravity: (x: Double, y: Double, z: Double),
        rotation: (x: Double, y: Double, z: Double)
    ) {
        let quaternion = yawRemovedQuaternion(
            x: sample.quaternionX,
            y: sample.quaternionY,
            z: sample.quaternionZ,
            w: sample.quaternionW
        )
        return (
            userAcceleration: rotate(
                x: sample.userAccelerationX,
                y: sample.userAccelerationY,
                z: sample.userAccelerationZ,
                by: quaternion
            ),
            gravity: rotate(
                x: sample.gravityX,
                y: sample.gravityY,
                z: sample.gravityZ,
                by: quaternion
            ),
            rotation: rotate(
                x: sample.rotationRateX,
                y: sample.rotationRateY,
                z: sample.rotationRateZ,
                by: quaternion
            )
        )
    }

    private func isFinite(_ sample: FusedMotionSample) -> Bool {
        sample.userAccelerationX.isFinite &&
            sample.userAccelerationY.isFinite &&
            sample.userAccelerationZ.isFinite &&
            sample.gravityX.isFinite &&
            sample.gravityY.isFinite &&
            sample.gravityZ.isFinite &&
            sample.rotationRateX.isFinite &&
            sample.rotationRateY.isFinite &&
            sample.rotationRateZ.isFinite &&
            sample.quaternionX.isFinite &&
            sample.quaternionY.isFinite &&
            sample.quaternionZ.isFinite &&
            sample.quaternionW.isFinite &&
            sample.timestamp.isFinite
    }

    private func isFinite(
        _ vectors: (
            userAcceleration: (x: Double, y: Double, z: Double),
            gravity: (x: Double, y: Double, z: Double),
            rotation: (x: Double, y: Double, z: Double)
        )
    ) -> Bool {
        vectors.userAcceleration.x.isFinite &&
            vectors.userAcceleration.y.isFinite &&
            vectors.userAcceleration.z.isFinite &&
            vectors.gravity.x.isFinite &&
            vectors.gravity.y.isFinite &&
            vectors.gravity.z.isFinite &&
            vectors.rotation.x.isFinite &&
            vectors.rotation.y.isFinite &&
            vectors.rotation.z.isFinite
    }

    private func yawRemovedQuaternion(x: Double, y: Double, z: Double, w: Double) -> (
        x: Double,
        y: Double,
        z: Double,
        w: Double
    ) {
        let magnitudeSquared = x * x + y * y + z * z + w * w
        guard magnitudeSquared.isFinite, magnitudeSquared > Double.leastNonzeroMagnitude else {
            return (x: 0.0, y: 0.0, z: 0.0, w: 1.0)
        }
        let inverseMagnitude = 1.0 / sqrt(magnitudeSquared)
        let normalizedX = x * inverseMagnitude
        let normalizedY = y * inverseMagnitude
        let normalizedZ = z * inverseMagnitude
        let normalizedW = w * inverseMagnitude
        let twistMagnitude = hypot(normalizedW, normalizedZ)

        // At an exact 180-degree horizontal swing, the Z twist is undefined;
        // the normalized quaternion already contains no usable yaw component.
        guard twistMagnitude > Double.leastNonzeroMagnitude else {
            return (x: normalizedX, y: normalizedY, z: 0.0, w: normalizedW)
        }

        return (
            x: (normalizedW * normalizedX + normalizedY * normalizedZ) / twistMagnitude,
            y: (normalizedW * normalizedY - normalizedX * normalizedZ) / twistMagnitude,
            z: 0.0,
            w: twistMagnitude
        )
    }

    private func rotate(
        x: Double,
        y: Double,
        z: Double,
        by quaternion: (x: Double, y: Double, z: Double, w: Double)
    ) -> (x: Double, y: Double, z: Double) {
        let qx = quaternion.x
        let qy = quaternion.y
        let qz = quaternion.z
        let qw = quaternion.w

        let xx = qx * qx
        let yy = qy * qy
        let zz = qz * qz
        let xy = qx * qy
        let xz = qx * qz
        let yz = qy * qz
        let wx = qw * qx
        let wy = qw * qy
        let wz = qw * qz

        let m00 = 1.0 - 2.0 * (yy + zz)
        let m01 = 2.0 * (xy - wz)
        let m02 = 2.0 * (xz + wy)
        let m10 = 2.0 * (xy + wz)
        let m11 = 1.0 - 2.0 * (xx + zz)
        let m12 = 2.0 * (yz - wx)
        let m20 = 2.0 * (xz - wy)
        let m21 = 2.0 * (yz + wx)
        let m22 = 1.0 - 2.0 * (xx + yy)

        return (
            x: m00 * x + m01 * y + m02 * z,
            y: m10 * x + m11 * y + m12 * z,
            z: m20 * x + m21 * y + m22 * z
        )
    }

    private func classifyMotion(screenX: Double, screenY: Double) -> VehicleMotionKind {
        let strongest = max(abs(screenX), abs(screenY))
        if strongest < nomasMotionReleaseThreshold {
            return .still
        }
        if motion == .still && strongest < nomasMotionActivationThreshold {
            return .still
        }
        return detectMotion(screenX: screenX, screenY: screenY)
    }

    private func detectMotion(screenX: Double, screenY: Double) -> VehicleMotionKind {
        let xMagnitude = abs(screenX)
        let yMagnitude = abs(screenY)
        let strongest = max(xMagnitude, yMagnitude)
        guard strongest > 0.0 else {
            return .still
        }

        let weakest = min(xMagnitude, yMagnitude)
        if weakest >= nomasMotionReleaseThreshold,
           weakest / strongest >= nomasMotionCombinedAxisRatio {
            return .complex
        }
        if yMagnitude >= xMagnitude {
            return screenY < 0.0 ? .acceleratingForward : .braking
        }
        return screenX < 0.0 ? .turningRight : .turningLeft
    }
}
