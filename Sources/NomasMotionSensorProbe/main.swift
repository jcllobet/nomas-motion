import CAccelerometer
import Foundation

private let accelScale = 65_536.0

@_cdecl("nomasMotionSensorProbeCallback")
func nomasMotionSensorProbeCallback(_ x: Int32, _ y: Int32, _ z: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let samples = Unmanaged<ProbeSamples>.fromOpaque(context).takeUnretainedValue()
    samples.ingest(rawX: x, rawY: y, rawZ: z)
}

final class ProbeSamples {
    private let lock = NSLock()
    private var latest = (x: 0.0, y: 0.0, z: 0.0)
    private var first: (x: Double, y: Double, z: Double)?
    private var minimum = (x: Double.infinity, y: Double.infinity, z: Double.infinity)
    private var maximum = (x: -Double.infinity, y: -Double.infinity, z: -Double.infinity)
    private var count = 0

    func ingest(rawX: Int32, rawY: Int32, rawZ: Int32) {
        let sample = (
            x: Double(rawX) / accelScale,
            y: Double(rawY) / accelScale,
            z: Double(rawZ) / accelScale
        )
        lock.lock()
        latest = sample
        if first == nil {
            first = sample
        }
        minimum = (
            x: min(minimum.x, sample.x),
            y: min(minimum.y, sample.y),
            z: min(minimum.z, sample.z)
        )
        maximum = (
            x: max(maximum.x, sample.x),
            y: max(maximum.y, sample.y),
            z: max(maximum.z, sample.z)
        )
        count += 1
        lock.unlock()
    }

    func snapshot() -> (count: Int, first: (x: Double, y: Double, z: Double)?, latest: (x: Double, y: Double, z: Double), span: (x: Double, y: Double, z: Double)) {
        lock.lock()
        let snapshot = (
            count: count,
            first: first,
            latest: latest,
            span: (
                x: count > 0 ? maximum.x - minimum.x : 0.0,
                y: count > 0 ? maximum.y - minimum.y : 0.0,
                z: count > 0 ? maximum.z - minimum.z : 0.0
            )
        )
        lock.unlock()
        return snapshot
    }
}

@main
struct NomasMotionSensorProbe {
    static func main() {
        let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 10.0
        let samples = ProbeSamples()
        let context = Unmanaged.passUnretained(samples).toOpaque()
        let result = nomas_accel_start(nomasMotionSensorProbeCallback, context)
        guard result == NOMAS_ACCEL_OK else {
            fputs("Sensor probe failed: \(String(cString: nomas_accel_error_message(result)))\n", stderr)
            fputs("Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
            Foundation.exit(1)
        }

        let started = Date()
        var lastCount = 0
        print("Sensor probe started. Move the MacBook to watch accelerometer values.")
        while Date().timeIntervalSince(started) < seconds {
            Thread.sleep(forTimeInterval: 0.25)
            let snapshot = samples.snapshot()
            if snapshot.count != lastCount {
                lastCount = snapshot.count
                print(String(format: "samples=%d x=% .4fg y=% .4fg z=% .4fg", snapshot.count, snapshot.latest.x, snapshot.latest.y, snapshot.latest.z))
            }
        }

        // Quiesce the worker before reading the final snapshot or releasing
        // its borrowed callback context.
        nomas_accel_stop()
        let final = samples.snapshot()
        if final.count == 0 {
            fputs("Sensor probe ended without samples.\n", stderr)
            fputs("Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
            Foundation.exit(2)
        }
        if let first = final.first {
            print(String(format: "Sensor probe first sample: x=% .4fg y=% .4fg z=% .4fg", first.x, first.y, first.z))
        }
        print(String(format: "Sensor probe latest sample: x=% .4fg y=% .4fg z=% .4fg", final.latest.x, final.latest.y, final.latest.z))
        print(String(format: "Sensor probe observed span: dx=% .4fg dy=% .4fg dz=% .4fg", final.span.x, final.span.y, final.span.z))
        print("Sensor probe complete with \(final.count) samples.")
    }
}
