import Darwin
import Foundation
import XCTest
import NomasMotionCore

private final class RawSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RawSensorSample] = []

    func append(_ sample: RawSensorSample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    var values: [RawSensorSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

private final class SocketServerControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

final class CoreRobustnessTests: XCTestCase {
    private func fusedSample(
        userX: Double = 0.0,
        userY: Double = 0.0,
        timestamp: Double,
        quaternionX: Double = 0.0,
        quaternionY: Double = 0.0,
        quaternionZ: Double = 0.0,
        quaternionW: Double = 1.0
    ) -> FusedMotionSample {
        FusedMotionSample(
            userAccelerationX: userX,
            userAccelerationY: userY,
            userAccelerationZ: 0.0,
            gravityX: 0.0,
            gravityY: 0.0,
            gravityZ: -1.0,
            rotationRateX: 0.0,
            rotationRateY: 0.0,
            rotationRateZ: 0.0,
            quaternionX: quaternionX,
            quaternionY: quaternionY,
            quaternionZ: quaternionZ,
            quaternionW: quaternionW,
            timestamp: timestamp
        )
    }

    func testNonFiniteSamplesAreIgnoredWithoutPoisoningState() {
        let processor = MotionProcessor()
        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        processor.ingestScaled(x: .nan, y: 0.2, z: 1.0)
        processor.ingestScaled(x: .infinity, y: 0.2, z: 1.0)

        var tuning = NomasMotionTuning.defaults
        tuning.smoothingAlpha = .nan
        tuning.motionActivationThresholdMetersPerSecondSquared = .infinity
        processor.applyTuning(tuning)
        processor.ingestScaled(x: 0.2, y: 0.0, z: 1.0)

        let cue = processor.currentCue()
        XCTAssertEqual(cue.sampleCount, 2)
        XCTAssertTrue(cue.screenX.isFinite)
        XCTAssertTrue(cue.screenY.isFinite)
        XCTAssertTrue(cue.viewX.isFinite)
        XCTAssertTrue(cue.viewY.isFinite)
        XCTAssertEqual(cue.rawX, 0.2, accuracy: 0.000_001)
    }

    func testNonFiniteFusedSampleIsIgnored() {
        let processor = MotionProcessor()
        processor.ingest(fusedSample(timestamp: 10.0))
        processor.ingest(fusedSample(userX: .nan, timestamp: 10.1))

        let cue = processor.currentCue()
        XCTAssertEqual(cue.sampleCount, 1)
        XCTAssertTrue(cue.screenX.isFinite)
        XCTAssertEqual(cue.rawX, 0.0, accuracy: 0.000_001)
    }

    func testOutOfOrderFusedSamplesDoNotMoveTimestampBackwards() {
        let withReplay = MotionProcessor()
        let control = MotionProcessor()

        for processor in [withReplay, control] {
            processor.ingest(fusedSample(timestamp: 10.0))
            processor.ingest(fusedSample(userX: 0.35, timestamp: 10.1))
        }
        withReplay.ingest(fusedSample(userX: 100.0, timestamp: 10.05))
        XCTAssertEqual(withReplay.currentCue().sampleCount, 2)

        withReplay.ingest(fusedSample(userX: 0.0, timestamp: 10.2))
        control.ingest(fusedSample(userX: 0.0, timestamp: 10.2))

        XCTAssertEqual(
            withReplay.currentCue().screenX,
            control.currentCue().screenX,
            accuracy: 0.000_000_001,
            "a replayed frame must not change the interval used by the next frame"
        )
    }

    func testFusedGapResetsTransientMotionFilters() {
        let processor = MotionProcessor()
        processor.ingest(fusedSample(timestamp: 0.0))
        processor.ingest(fusedSample(userX: 0.8, timestamp: 1.0 / 60.0))
        XCTAssertGreaterThan(processor.currentCue().screenX, 0.0)

        processor.ingest(fusedSample(timestamp: 1.0))

        let cue = processor.currentCue()
        XCTAssertEqual(cue.screenX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.screenY, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.viewX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.viewY, 0.0, accuracy: 0.000_001)
    }

    func testWallClockGapResetsTransientMotionFiltersAndReanchorsGravity() {
        var now = Date(timeIntervalSince1970: 1_000.0)
        let processor = MotionProcessor(now: { now })
        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)
        now = now.addingTimeInterval(1.0 / 60.0)
        processor.ingestScaled(x: 0.4, y: 0.0, z: 1.0)
        XCTAssertGreaterThan(processor.currentCue().screenX, 0.0)

        now = now.addingTimeInterval(1.0)
        processor.ingestScaled(x: 0.0, y: 0.0, z: 1.0)

        let cue = processor.currentCue()
        XCTAssertEqual(cue.screenX, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(cue.screenY, 0.0, accuracy: 0.000_001)
    }

    func testSensorLineBufferDropsOversizedPartialLineButParsesNextLine() {
        var buffer = SensorLineBuffer()
        let oversized = Data(repeating: 65, count: 512)
        XCTAssertTrue(buffer.append(oversized).isEmpty)

        let samples = buffer.append(Data("\n1 2 3\n".utf8))
        XCTAssertEqual(samples, [RawSensorSample(x: 1, y: 2, z: 3)])
    }

    func testFIFOEndOfFileIsReported() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nomas-motion-fifo-eof-\(UUID().uuidString)")
        try? Data("1 2 3\n".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let eof = DispatchSemaphore(value: 0)
        let handle = SensorLineReader.startFIFO(
            path: path.path,
            ingest: { _ in },
            onUnavailable: { message in
                if message.contains("reached EOF") {
                    eof.signal()
                }
            }
        )

        XCTAssertEqual(
            eof.wait(timeout: .now() + 2.0),
            .success,
            "an empty FIFO read must terminate and notify instead of polling forever"
        )
        handle.stop()
    }

    func testSensorLineReaderStopIsPromptAndIdempotent() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nomas-motion-fifo-stop-\(UUID().uuidString)")
        XCTAssertEqual(mkfifo(path.path, mode_t(0o600)), 0)
        defer { try? FileManager.default.removeItem(at: path) }

        let readerReady = DispatchSemaphore(value: 0)
        let handle = SensorLineReader.startFIFO(
            path: path.path,
            ingest: { _ in },
            onUnavailable: { _ in
                readerReady.signal()
            }
        )

        // Keep a FIFO writer open so the reader has an active descriptor with
        // no input and would otherwise remain in its read loop.
        var writerFD: Int32 = -1
        let deadline = Date().addingTimeInterval(2.0)
        while writerFD < 0, Date() < deadline {
            writerFD = open(path.path, O_WRONLY | O_NONBLOCK)
            if writerFD < 0 {
                usleep(10_000)
            }
        }
        XCTAssertGreaterThanOrEqual(writerFD, 0)
        _ = readerReady.wait(timeout: .now() + 0.2)

        let started = DispatchTime.now()
        handle.stop()
        handle.stop()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        if writerFD >= 0 {
            close(writerFD)
        }
        XCTAssertLessThan(elapsed, 0.5, "stop must close an active reader without waiting for input")
    }

    func testFIFOWriterCloseAndReopenDeliversBothSamples() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nomas-motion-fifo-reopen-\(UUID().uuidString)")
        XCTAssertEqual(mkfifo(path.path, mode_t(0o600)), 0)
        defer { try? FileManager.default.removeItem(at: path) }

        let collector = RawSampleCollector()
        let received = DispatchSemaphore(value: 0)
        let handle = SensorLineReader.startFIFO(
            path: path.path,
            ingest: { sample in
                collector.append(sample)
                received.signal()
            },
            onUnavailable: { _ in }
        )
        defer { handle.stop() }

        func writeLine(_ line: String) -> Bool {
            let bytes = Array(line.utf8)
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                let writerFD = open(path.path, O_WRONLY | O_NONBLOCK)
                if writerFD >= 0 {
                    let result = bytes.withUnsafeBytes {
                        write(writerFD, $0.baseAddress, bytes.count)
                    }
                    close(writerFD)
                    return result == bytes.count
                }
                guard errno == ENXIO else {
                    return false
                }
                usleep(10_000)
            }
            return false
        }

        XCTAssertTrue(writeLine("1 2 3\n"), "the first writer must connect")
        XCTAssertEqual(received.wait(timeout: .now() + 2.0), .success)

        XCTAssertTrue(writeLine("4 5 6\n"), "the reader must reopen after writer EOF")
        XCTAssertEqual(received.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(collector.values, [
            RawSensorSample(x: 1, y: 2, z: 3),
            RawSensorSample(x: 4, y: 5, z: 6)
        ])
    }

    func testSocketDisconnectAndReconnectDeliversBothSamples() {
        let path = "/tmp/nomas-motion-socket-reconnect-\(UUID().uuidString)"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            XCTFail("could not create Unix-domain listener")
            return
        }
        defer {
            Darwin.close(listener)
            _ = path.withCString { Darwin.unlink($0) }
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            XCTFail("could not bind Unix-domain listener")
            return
        }
        guard listen(listener, 1) == 0 else {
            XCTFail("could not listen on Unix-domain socket")
            return
        }
        guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            XCTFail("could not make Unix-domain listener nonblocking")
            return
        }

        let control = SocketServerControl()
        let serverQueue = DispatchQueue(label: "nomas-motion.socket-test-server")
        serverQueue.async {
            func send(_ line: String, on client: Int32) {
                let bytes = Array(line.utf8)
                bytes.withUnsafeBytes { source in
                    guard let baseAddress = source.baseAddress else { return }
                    var offset = 0
                    while offset < source.count {
                        let count = Darwin.write(
                            client,
                            baseAddress.advanced(by: offset),
                            source.count - offset
                        )
                        guard count > 0 else { return }
                        offset += count
                    }
                }
            }

            for line in ["1 2 3\n", "4 5 6\n"] {
                var client: Int32 = -1
                while client < 0, !control.isStopped {
                    var event = pollfd(
                        fd: listener,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    let result = poll(&event, 1, 100)
                    if result > 0 {
                        client = accept(listener, nil, nil)
                    } else if result < 0, errno != EINTR {
                        return
                    }
                }
                guard client >= 0 else { return }
                send(line, on: client)
                Darwin.close(client)
            }
        }

        let collector = RawSampleCollector()
        let connected = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let handle = SensorLineReader.startSocket(
            path: path,
            onWaiting: {},
            onConnected: { connected.signal() },
            onDisconnected: { disconnected.signal() },
            ingest: { sample in
                collector.append(sample)
                received.signal()
            }
        )
        defer {
            handle.stop()
            control.stop()
            serverQueue.sync {}
        }

        XCTAssertEqual(connected.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(received.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(disconnected.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(connected.wait(timeout: .now() + 4.0), .success)
        XCTAssertEqual(received.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(disconnected.wait(timeout: .now() + 3.0), .success)
        XCTAssertEqual(collector.values, [
            RawSensorSample(x: 1, y: 2, z: 3),
            RawSensorSample(x: 4, y: 5, z: 6)
        ])
    }

    func testVehicleMotionCueIsSendable() {
        func acceptsSendable<T: Sendable>(_ value: T) -> T { value }

        let cue = VehicleMotionCue(screenX: 0.1, screenY: -0.2, hasSamples: true)
        XCTAssertEqual(acceptsSendable(cue).screenX, 0.1, accuracy: 0.000_001)
    }
}
