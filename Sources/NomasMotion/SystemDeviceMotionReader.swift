import CoreMotion
import Darwin
import Foundation
import NomasMotionCore
import ObjectiveC.runtime

private typealias MotionObjectInitializer = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias MotionObjectGetter = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias MotionDoubleGetter = @convention(c) (AnyObject, Selector) -> Double
private typealias MotionAccelerationGetter = @convention(c) (AnyObject, Selector) -> CMAcceleration
private typealias MotionRotationGetter = @convention(c) (AnyObject, Selector) -> CMRotationRate
private typealias MotionQuaternionGetter = @convention(c) (AnyObject, Selector) -> CMQuaternion
private typealias MotionDoubleSetter = @convention(c) (AnyObject, Selector, Double) -> Void
private typealias MotionVoidMethod = @convention(c) (AnyObject, Selector) -> Void

@MainActor
protocol SystemDeviceMotionReading: AnyObject {
    func start(
        onSample: @escaping (FusedMotionSample) -> Void,
        onUnavailable: @escaping () -> Void
    ) -> Bool
    func stop()
}

/// Uses the same private six-axis Core Motion surface as macOS Vehicle Motion Cues.
/// Every lookup is dynamic so unsupported macOS versions fall back to the HID helper.
@MainActor
final class SystemDeviceMotionReader: SystemDeviceMotionReading {
    private static let frameworkPath = "/System/Library/Frameworks/CoreMotion.framework/CoreMotion"
    private static let sampleInterval = 1.0 / 60.0
    private static let sampleWatchdogInterval = 0.5
    private static let sampleWatchdogTimeout = 1.5

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var manager: AnyObject?
    private var pollTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastTimestamp = -Double.infinity
    private var hasReceivedSample = false
    private var startUptime: TimeInterval?
    private var lastSampleUptime: TimeInterval?
    private var lifecycleGeneration: UInt64 = 0
    private var unavailableCallbackDelivered = false
    private var onSample: ((FusedMotionSample) -> Void)?
    private var onUnavailable: (() -> Void)?

    func start(
        onSample: @escaping (FusedMotionSample) -> Void,
        onUnavailable: @escaping () -> Void
    ) -> Bool {
        guard manager == nil else {
            return true
        }

        resetStateForStart()
        guard ProcessInfo.processInfo.environment["NOMAS_MOTION_DISABLE_SYSTEM_DEVICE_MOTION"] != "1" else {
            return false
        }
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            return false
        }
        frameworkHandle = handle

        guard let managerClass = NSClassFromString("CMMotionManager"),
              let initializedManager = makeManager(from: managerClass) else {
            stop()
            return false
        }

        self.manager = initializedManager
        self.onSample = onSample
        self.onUnavailable = onUnavailable

        guard
            setDouble(
                Self.sampleInterval,
                on: initializedManager,
                selectorNames: ["setDeviceMotionUpdateIntervalPrivate:", "setDeviceMotionUpdateInterval:"]
            ),
            invokeVoid(
                on: initializedManager,
                selectorNames: ["startDeviceMotionUpdatesNoSim", "startDeviceMotionUpdates"]
            )
        else {
            stop()
            return false
        }

        startUptime = ProcessInfo.processInfo.systemUptime
        let generation = lifecycleGeneration
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll(forGeneration: generation)
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSampleWatchdog(forGeneration: generation)
            }
        }
        if let timeoutTimer {
            RunLoop.main.add(timeoutTimer, forMode: .common)
        }
        return true
    }

    func stop() {
        lifecycleGeneration &+= 1
        pollTimer?.invalidate()
        timeoutTimer?.invalidate()
        pollTimer = nil
        timeoutTimer = nil

        if let manager {
            _ = invokeVoid(
                on: manager,
                selectorNames: ["stopDeviceMotionUpdatesNoSim", "stopDeviceMotionUpdates"]
            )
        }
        manager = nil
        closeFramework()

        lastTimestamp = -Double.infinity
        hasReceivedSample = false
        startUptime = nil
        lastSampleUptime = nil
        onSample = nil
        onUnavailable = nil
    }

    private func poll(forGeneration generation: UInt64) {
        guard generation == lifecycleGeneration else {
            return
        }
        guard
            let manager,
            let motion = invokeObject(
                on: manager,
                selectorNames: ["deviceMotionNoSim", "deviceMotion"]
            ),
            let timestamp = getDouble(on: motion, selectorName: "timestamp"),
            timestamp.isFinite,
            timestamp > lastTimestamp,
            let userAcceleration = getAcceleration(on: motion, selectorName: "userAcceleration"),
            let gravity = getAcceleration(on: motion, selectorName: "gravity"),
            let rotationRate = getRotation(on: motion, selectorName: "rotationRate")
        else {
            return
        }

        let quaternion: CMQuaternion
        if let attitude = invokeObject(on: motion, selectorNames: ["attitude"]) {
            guard let value = getQuaternion(on: attitude, selectorName: "quaternion") else {
                return
            }
            quaternion = value
        } else {
            quaternion = CMQuaternion(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
        }

        guard
            isFinite(userAcceleration),
            isFinite(gravity),
            isFinite(rotationRate),
            isFinite(quaternion)
        else {
            return
        }

        lastTimestamp = timestamp
        hasReceivedSample = true
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        onSample?(
            FusedMotionSample(
                userAccelerationX: userAcceleration.x,
                userAccelerationY: userAcceleration.y,
                userAccelerationZ: userAcceleration.z,
                gravityX: gravity.x,
                gravityY: gravity.y,
                gravityZ: gravity.z,
                rotationRateX: rotationRate.x,
                rotationRateY: rotationRate.y,
                rotationRateZ: rotationRate.z,
                quaternionX: quaternion.x,
                quaternionY: quaternion.y,
                quaternionZ: quaternion.z,
                quaternionW: quaternion.w,
                timestamp: timestamp
            )
        )
    }

    private func checkSampleWatchdog(forGeneration generation: UInt64) {
        guard generation == lifecycleGeneration else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let referenceUptime = hasReceivedSample ? lastSampleUptime : startUptime
        guard let referenceUptime else {
            return
        }
        let elapsed = now - referenceUptime
        guard elapsed >= Self.sampleWatchdogTimeout else {
            return
        }
        guard !unavailableCallbackDelivered else {
            return
        }

        unavailableCallbackDelivered = true
        let callback = onUnavailable
        stop()
        callback?()
    }

    private func resetStateForStart() {
        lifecycleGeneration &+= 1
        pollTimer?.invalidate()
        timeoutTimer?.invalidate()
        pollTimer = nil
        timeoutTimer = nil
        lastTimestamp = -Double.infinity
        hasReceivedSample = false
        startUptime = nil
        lastSampleUptime = nil
        unavailableCallbackDelivered = false
        onSample = nil
        onUnavailable = nil
        closeFramework()
    }

    private func closeFramework() {
        guard let frameworkHandle else {
            return
        }
        self.frameworkHandle = nil
        dlclose(frameworkHandle)
    }

    private func invokeInitializer(
        on object: AnyObject,
        class objectClass: AnyClass,
        selectorName: String
    ) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            return nil
        }
        guard methodMatches(method, signature: .object) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: MotionObjectInitializer.self)
        return function(object, selector)
    }

    private func makeManager(from managerClass: AnyClass) -> AnyObject? {
        guard let rawManager = class_createInstance(managerClass, 0) as AnyObject? else {
            return nil
        }
        return invokeInitializer(
            on: rawManager,
            class: managerClass,
            selectorName: "initUsing6AxisSensorFusion"
        )
    }

    private func invokeObject(on object: AnyObject, selectorNames: [String]) -> AnyObject? {
        guard let objectClass = object_getClass(object) else {
            return nil
        }
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            guard let method = class_getInstanceMethod(objectClass, selector) else {
                continue
            }
            guard methodMatches(method, signature: .object) else {
                continue
            }
            let function = unsafeBitCast(method_getImplementation(method), to: MotionObjectGetter.self)
            if let result = function(object, selector) {
                return result
            }
        }
        return nil
    }

    @discardableResult
    private func invokeVoid(on object: AnyObject, selectorNames: [String]) -> Bool {
        guard let objectClass = object_getClass(object) else {
            return false
        }
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            guard let method = class_getInstanceMethod(objectClass, selector) else {
                continue
            }
            guard methodMatches(method, signature: .void) else {
                continue
            }
            let function = unsafeBitCast(method_getImplementation(method), to: MotionVoidMethod.self)
            function(object, selector)
            return true
        }
        return false
    }

    private func setDouble(_ value: Double, on object: AnyObject, selectorNames: [String]) -> Bool {
        guard let objectClass = object_getClass(object) else {
            return false
        }
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            guard let method = class_getInstanceMethod(objectClass, selector) else {
                continue
            }
            guard methodMatches(method, signature: .doubleSetter) else {
                continue
            }
            let function = unsafeBitCast(method_getImplementation(method), to: MotionDoubleSetter.self)
            function(object, selector, value)
            return true
        }
        return false
    }

    private func getDouble(on object: AnyObject, selectorName: String) -> Double? {
        guard let objectClass = object_getClass(object) else {
            return nil
        }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            return nil
        }
        guard methodMatches(method, signature: .double) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: MotionDoubleGetter.self)
        return function(object, selector)
    }

    private func getAcceleration(on object: AnyObject, selectorName: String) -> CMAcceleration? {
        guard let objectClass = object_getClass(object) else {
            return nil
        }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            return nil
        }
        guard methodMatches(method, signature: .acceleration) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: MotionAccelerationGetter.self)
        return function(object, selector)
    }

    private func getRotation(on object: AnyObject, selectorName: String) -> CMRotationRate? {
        guard let objectClass = object_getClass(object) else {
            return nil
        }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            return nil
        }
        guard methodMatches(method, signature: .rotation) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: MotionRotationGetter.self)
        return function(object, selector)
    }

    private func getQuaternion(on object: AnyObject, selectorName: String) -> CMQuaternion? {
        guard let objectClass = object_getClass(object) else {
            return nil
        }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            return nil
        }
        guard methodMatches(method, signature: .quaternion) else {
            return nil
        }
        let function = unsafeBitCast(method_getImplementation(method), to: MotionQuaternionGetter.self)
        return function(object, selector)
    }

    private enum MotionMethodSignature {
        case object
        case void
        case double
        case doubleSetter
        case acceleration
        case rotation
        case quaternion
    }

    private func methodMatches(_ method: Method, signature: MotionMethodSignature) -> Bool {
        guard let rawEncoding = method_getTypeEncoding(method) else {
            return false
        }
        let encoding = String(cString: rawEncoding)

        switch signature {
        case .object:
            return compactTypeEncoding(encoding) == "@@:"
        case .void:
            return compactTypeEncoding(encoding) == "v@:"
        case .double:
            return compactTypeEncoding(encoding) == "d@:"
        case .doubleSetter:
            return compactTypeEncoding(encoding) == "v@:d"
        case .acceleration, .rotation:
            return structReturnMatches(encoding, componentCount: 3)
        case .quaternion:
            return structReturnMatches(encoding, componentCount: 4)
        }
    }

    private func compactTypeEncoding(_ encoding: String) -> String {
        var compact = ""
        var inQuotedFieldName = false

        for character in encoding {
            if character == "\"" {
                inQuotedFieldName.toggle()
                continue
            }
            if inQuotedFieldName || character.isNumber || "rnNoORV".contains(character) {
                continue
            }
            compact.append(character)
        }
        return compact
    }

    private func structReturnMatches(_ encoding: String, componentCount: Int) -> Bool {
        guard
            let openingBrace = encoding.firstIndex(of: "{"),
            let closingBrace = encoding[openingBrace...].firstIndex(of: "}")
        else {
            return false
        }

        let returnType = String(encoding[openingBrace...closingBrace])
        guard let equals = returnType.firstIndex(of: "=") else {
            return false
        }

        let fieldsStart = returnType.index(after: equals)
        let fieldsEnd = returnType.index(before: returnType.endIndex)
        let fields = fieldsStart <= fieldsEnd ? String(returnType[fieldsStart...fieldsEnd]) : ""
        guard compactTypeEncoding(fields) == String(repeating: "d", count: componentCount) else {
            return false
        }

        let suffixStart = encoding.index(after: closingBrace)
        return compactTypeEncoding(String(encoding[suffixStart...])) == "@:"
    }

    private func isFinite(_ acceleration: CMAcceleration) -> Bool {
        acceleration.x.isFinite && acceleration.y.isFinite && acceleration.z.isFinite
    }

    private func isFinite(_ rotation: CMRotationRate) -> Bool {
        rotation.x.isFinite && rotation.y.isFinite && rotation.z.isFinite
    }

    private func isFinite(_ quaternion: CMQuaternion) -> Bool {
        quaternion.x.isFinite && quaternion.y.isFinite && quaternion.z.isFinite && quaternion.w.isFinite
    }
}
