import Foundation

public struct RawSensorSample: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public let z: Int32

    public init(x: Int32, y: Int32, z: Int32) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init?(line: String) {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count == 3,
              let x = Int32(parts[0]),
              let y = Int32(parts[1]),
              let z = Int32(parts[2]) else {
            return nil
        }
        self.init(x: x, y: y, z: z)
    }

    public var line: String {
        "\(x) \(y) \(z)\n"
    }
}

public struct FusedMotionSample: Equatable, Sendable {
    public let userAccelerationX: Double
    public let userAccelerationY: Double
    public let userAccelerationZ: Double
    public let gravityX: Double
    public let gravityY: Double
    public let gravityZ: Double
    public let rotationRateX: Double
    public let rotationRateY: Double
    public let rotationRateZ: Double
    /// The Core Motion attitude quaternion, in CMQuaternion's x/y/z/w order.
    ///
    /// Older callers that do not have attitude data use the identity
    /// quaternion.  Keeping the fields as scalars leaves this core target
    /// independent of CoreMotion while preserving the exact wire shape used
    /// by the system reader.
    public let quaternionX: Double
    public let quaternionY: Double
    public let quaternionZ: Double
    public let quaternionW: Double
    public let timestamp: Double

    public init(
        userAccelerationX: Double,
        userAccelerationY: Double,
        userAccelerationZ: Double,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        rotationRateX: Double,
        rotationRateY: Double,
        rotationRateZ: Double,
        quaternionX: Double = 0.0,
        quaternionY: Double = 0.0,
        quaternionZ: Double = 0.0,
        quaternionW: Double = 1.0,
        timestamp: Double
    ) {
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.quaternionW = quaternionW
        self.timestamp = timestamp
    }
}

/// Accumulates newline-delimited `RawSensorSample` lines from streaming sensor I/O.
public struct SensorLineBuffer {
    private static let maximumLineBytes = 256

    private var buffer = Data()
    private var discardingOversizedLine = false

    public init() {}

    public mutating func append(_ chunk: Data) -> [RawSensorSample] {
        guard !chunk.isEmpty else {
            return []
        }
        buffer.append(chunk)
        return drainSamples()
    }

    public mutating func drainSamples() -> [RawSensorSample] {
        var samples: [RawSensorSample] = []
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if discardingOversizedLine {
                discardingOversizedLine = false
                continue
            }
            guard lineData.count <= Self.maximumLineBytes else {
                continue
            }
            guard let line = String(data: lineData, encoding: .utf8),
                  let sample = RawSensorSample(line: line) else {
                continue
            }
            samples.append(sample)
        }

        // A producer that never emits a newline must not be able to grow this
        // parser without bound. Drop the partial line and ignore its eventual
        // terminator; the next complete line can still be parsed normally.
        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll(keepingCapacity: true)
            discardingOversizedLine = true
        }
        return samples
    }
}
