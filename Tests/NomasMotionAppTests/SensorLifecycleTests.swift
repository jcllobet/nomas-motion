import AppKit
import Darwin
import NomasMotionCore
import NomasMotionOverlay
import XCTest
@testable import NomasMotion

@MainActor
private final class ControlledDeviceMotionReader: SystemDeviceMotionReading {
    private var onUnavailable: (() -> Void)?

    func start(
        onSample: @escaping (FusedMotionSample) -> Void,
        onUnavailable: @escaping () -> Void
    ) -> Bool {
        self.onUnavailable = onUnavailable
        return true
    }

    func stop() {
        onUnavailable = nil
    }

    func becomeUnavailable() {
        let callback = onUnavailable
        onUnavailable = nil
        callback?()
    }
}

@MainActor
private final class SensorFixture {
    let path = "/tmp/nomas-lifecycle-\(UUID().uuidString)"
    let processor = MotionProcessor()
    let reader = ControlledDeviceMotionReader()
    let controller: AppMenuController
    private let suiteName = "NomasMotionAppTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suiteName)!
        controller = AppMenuController(
            processor: processor,
            overlayController: OverlayController(processor: processor),
            settingsStore: NomasMotionSettingsStore(defaults: defaults),
            statisticsStore: TripStatisticsStore(defaults: defaults),
            socketPath: path,
            makeDeviceMotionReader: { [reader] in reader }
        )
        controller.installMenuBar(startOverlayVisible: false)
    }

    func shutdown() {
        controller.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class SocketListener {
    let descriptor: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(descriptor, 2) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            unlink(path)
            throw POSIXError(.EIO)
        }
    }

    deinit {
        Darwin.close(descriptor)
        unlink(path)
    }
}

@MainActor
final class SensorLifecycleTests: XCTestCase {
    func testHelperDoesNotPreemptPendingSystemMotionStartup() throws {
        let fixture = SensorFixture()
        defer { fixture.shutdown() }
        let listener = try SocketListener(path: fixture.path)

        let earlyClient = waitForConnection(listener, timeout: 1.3)
        if earlyClient >= 0 { Darwin.close(earlyClient) }
        XCTAssertLessThan(earlyClient, 0, "the helper must wait for the system source to become unavailable")

        fixture.reader.becomeUnavailable()
        let client = waitForConnection(listener)
        guard client >= 0 else { return XCTFail("helper did not connect after system fallback") }
        defer { Darwin.close(client) }
        sendRestSample(to: client)
        XCTAssertTrue(waitUntil { fixture.processor.currentCue(maximumSampleAge: 0.5).hasSamples })
        XCTAssertFalse(fixture.controller.overlayVisible)
    }

    func testHelperAppearingAfterSeveralRetriesConnectsWithoutRestart() throws {
        let fixture = SensorFixture()
        defer { fixture.shutdown() }
        fixture.reader.becomeUnavailable()
        XCTAssertFalse(waitUntil(timeout: 3.2) { fixture.processor.currentCue(maximumSampleAge: 0.5).hasSamples })

        let listener = try SocketListener(path: fixture.path)
        let client = waitForConnection(listener)
        guard client >= 0 else { return XCTFail("late helper did not connect") }
        defer { Darwin.close(client) }
        sendRestSample(to: client)
        XCTAssertTrue(waitUntil { fixture.processor.currentCue(maximumSampleAge: 0.5).hasSamples })
        XCTAssertFalse(fixture.controller.overlayVisible)
    }

    func testHelperReconnectsWithoutRestartingController() throws {
        let fixture = SensorFixture()
        defer { fixture.shutdown() }
        let listener = try SocketListener(path: fixture.path)
        fixture.reader.becomeUnavailable()
        let first = waitForConnection(listener)
        guard first >= 0 else { return XCTFail("first helper connection failed") }
        sendRestSample(to: first)
        XCTAssertTrue(waitUntil { fixture.processor.currentCue(maximumSampleAge: 0.5).sampleCount == 1 })
        Darwin.close(first)

        let second = waitForConnection(listener)
        guard second >= 0 else { return XCTFail("helper did not reconnect") }
        defer { Darwin.close(second) }
        sendRestSample(to: second)
        XCTAssertTrue(waitUntil { fixture.processor.currentCue(maximumSampleAge: 0.5).sampleCount == 2 })
        XCTAssertFalse(fixture.controller.overlayVisible)
    }

    func testShutdownCancelsWaitingForHelper() throws {
        let fixture = SensorFixture()
        defer { fixture.shutdown() }
        fixture.reader.becomeUnavailable()
        fixture.shutdown()

        let listener = try SocketListener(path: fixture.path)
        let client = waitForConnection(listener, timeout: 1.3)
        if client >= 0 { Darwin.close(client) }
        XCTAssertLessThan(client, 0, "a stopped controller must not reconnect")
        XCTAssertFalse(fixture.controller.overlayVisible)
    }

    private func waitUntil(timeout: TimeInterval = 2.5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitForConnection(_ listener: SocketListener, timeout: TimeInterval = 2.5) -> Int32 {
        var client: Int32 = -1
        _ = waitUntil(timeout: timeout) {
            client = accept(listener.descriptor, nil, nil)
            return client >= 0
        }
        return client
    }

    private func sendRestSample(to client: Int32) {
        let bytes = Array("0 0 -65536\n".utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        XCTAssertEqual(count, bytes.count)
    }
}
