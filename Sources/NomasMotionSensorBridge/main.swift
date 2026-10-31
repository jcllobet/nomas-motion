import CAccelerometer
import Foundation
import NomasMotionCore

final class BridgeWriter {
    private let lock = NSLock()
    private var count = 0
    private var lastReport = Date()

    func write(rawX: Int32, rawY: Int32, rawZ: Int32) {
        let sample = RawSensorSample(x: rawX, y: rawY, z: rawZ)
        guard let data = sample.line.data(using: .utf8) else {
            return
        }
        lock.lock()
        FileHandle.standardOutput.write(data)
        count += 1
        if Date().timeIntervalSince(lastReport) >= 2 {
            fputs("Sensor bridge samples: \(count)\n", stderr)
            lastReport = Date()
        }
        lock.unlock()
    }

    func sampleCount() -> Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }
}

@_cdecl("nomasMotionSensorBridgeCallback")
func nomasMotionSensorBridgeCallback(_ x: Int32, _ y: Int32, _ z: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let writer = Unmanaged<BridgeWriter>.fromOpaque(context).takeUnretainedValue()
    writer.write(rawX: x, rawY: y, rawZ: z)
}

@main
struct NomasMotionSensorBridge {
    static func main() {
        let writer = BridgeWriter()
        let context = Unmanaged.passUnretained(writer).toOpaque()
        let result = nomas_accel_start(nomasMotionSensorBridgeCallback, context)
        guard result == NOMAS_ACCEL_OK else {
            fputs("Sensor bridge failed: \(String(cString: nomas_accel_error_message(result)))\n", stderr)
            fputs("Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
            Foundation.exit(1)
        }

        fputs("Sensor bridge started. Streaming raw samples to stdout.\n", stderr)
        var waitTicks = 0
        while true {
            Thread.sleep(forTimeInterval: 1)
            if writer.sampleCount() == 0 {
                waitTicks += 1
                if waitTicks >= 5 {
                    fputs("Sensor bridge waiting for samples. Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
                    waitTicks = 0
                }
            }
        }
    }
}
