import CAccelerometer
import Foundation
import NomasMotionCore

private final class DirectAccelerometerOwnership: @unchecked Sendable {
    let lock = NSLock()
    var retainedProcessor: Unmanaged<MotionProcessor>?
    var generation: UInt64 = 0
}

private let directAccelerometerOwnership = DirectAccelerometerOwnership()

@_cdecl("nomasMotionAccelCallback")
private func nomasMotionAccelCallback(_ x: Int32, _ y: Int32, _ z: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let processor = Unmanaged<MotionProcessor>.fromOpaque(context).takeUnretainedValue()
    processor.ingest(RawSensorSample(x: x, y: y, z: z))
}

func startDirectAccelerometer(processor: MotionProcessor) -> Int32 {
    let retainedProcessor = Unmanaged.passRetained(processor)
    let context = retainedProcessor.toOpaque()

    directAccelerometerOwnership.lock.lock()
    directAccelerometerOwnership.generation &+= 1
    let generation = directAccelerometerOwnership.generation
    directAccelerometerOwnership.lock.unlock()

    let result = nomas_accel_start(nomasMotionAccelCallback, context)
    directAccelerometerOwnership.lock.lock()
    let startIsCurrent = directAccelerometerOwnership.generation == generation
    if result == NOMAS_ACCEL_OK, startIsCurrent {
        directAccelerometerOwnership.retainedProcessor = retainedProcessor
    }
    directAccelerometerOwnership.lock.unlock()

    if result != NOMAS_ACCEL_OK {
        // Failed and timed-out starts synchronously quiesce any worker they
        // created. An already-running result belongs to the existing owner.
        retainedProcessor.release()
    } else if !startIsCurrent {
        // A stop raced the successful handoff. Quiesce before releasing the
        // callback context that C briefly borrowed.
        nomas_accel_stop()
        retainedProcessor.release()
    }
    return result
}

func stopDirectAccelerometer() {
    directAccelerometerOwnership.lock.lock()
    directAccelerometerOwnership.generation &+= 1
    let retainedProcessor = directAccelerometerOwnership.retainedProcessor
    directAccelerometerOwnership.retainedProcessor = nil
    directAccelerometerOwnership.lock.unlock()

    nomas_accel_stop()
    retainedProcessor?.release()
}
