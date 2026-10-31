import CAccelerometer
import Darwin
import Foundation

public enum SensorInputKind: Sendable, Equatable {
    case systemDeviceMotion
    case fifo
    case helperSocket
    case direct
}

public final class SensorLineReaderHandle: @unchecked Sendable {
    fileprivate let state: SensorLineReaderState

    fileprivate init() {
        state = SensorLineReaderState()
    }

    /// Stops the reader and closes its active descriptor. Safe to call more than once.
    public func stop() {
        state.stop()
    }
}

fileprivate final class SensorLineReaderState: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var activeDescriptor: SensorLineReaderDescriptor?
    private var workerActive = false
    private var workerThreadID: UInt32?

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    func workerStarted() {
        condition.lock()
        workerActive = true
        workerThreadID = pthread_mach_thread_np(pthread_self())
        condition.unlock()
    }

    func workerFinished() {
        condition.lock()
        workerActive = false
        workerThreadID = nil
        condition.broadcast()
        condition.unlock()
    }

    func install(_ fd: Int32) -> SensorLineReaderDescriptor? {
        let descriptor = SensorLineReaderDescriptor(fd: fd)
        condition.lock()
        if stopped {
            condition.unlock()
            descriptor.close()
            return nil
        }
        activeDescriptor = descriptor
        condition.unlock()
        return descriptor
    }

    func deactivate(_ descriptor: SensorLineReaderDescriptor) {
        condition.lock()
        if activeDescriptor === descriptor {
            activeDescriptor = nil
        }
        condition.unlock()
        descriptor.close()
    }

    func stop() {
        let callerThreadID = pthread_mach_thread_np(pthread_self())
        condition.lock()
        stopped = true
        let descriptor = activeDescriptor
        let mustWait = workerActive && workerThreadID != callerThreadID
        condition.unlock()
        // The worker owns close(). Interrupt sockets here; FIFO polling has a
        // 100 ms timeout. Closing from this thread could let the OS reuse the
        // numeric fd before the worker returns from poll/read.
        descriptor?.interrupt()

        guard mustWait else { return }
        condition.lock()
        while workerActive {
            condition.wait()
        }
        condition.unlock()
    }
}

fileprivate final class SensorLineReaderDescriptor: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        // shutdown wakes a socket read. It is harmless for a FIFO (and close
        // is still required for both descriptor types).
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    func interrupt() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        lock.unlock()
    }
}

public enum SensorLineReader {
    private static let pollTimeoutMilliseconds: Int32 = 100
    private static let retryInitialDelay: TimeInterval = 0.05
    private static let retryMaximumDelay: TimeInterval = 1.0

    private enum DescriptorWaitResult {
        case ready
        case timedOut
        case failed
    }

    public static func startFIFO(
        path: String,
        ingest: @escaping @Sendable (RawSensorSample) -> Void,
        onUnavailable: @escaping @Sendable (String) -> Void,
        shouldStop: @escaping @Sendable () -> Bool = { false }
    ) -> SensorLineReaderHandle {
        let handle = SensorLineReaderHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            handle.state.workerStarted()
            defer { handle.state.workerFinished() }
            var retryDelay = retryInitialDelay

            while !Self.shouldStop(handle: handle, customStop: shouldStop) {
                let fd = open(path, O_RDONLY | O_NONBLOCK)
                guard fd >= 0 else {
                    if Self.shouldStop(handle: handle, customStop: shouldStop) {
                        return
                    }
                    let errorCode = errno
                    onUnavailable(
                        "cannot open FIFO \(path): \(String(cString: strerror(errorCode)))"
                    )
                    guard Self.waitBeforeRetry(
                        retryDelay,
                        handle: handle,
                        customStop: shouldStop
                    ) else {
                        return
                    }
                    retryDelay = min(retryDelay * 2, retryMaximumDelay)
                    continue
                }

                guard let descriptor = handle.state.install(fd) else {
                    return
                }

                var lineBuffer = SensorLineBuffer()
                var reachedEOF = false
                var readError: String?

                readLoop: while !Self.shouldStop(handle: handle, customStop: shouldStop) {
                    switch Self.waitForReadable(
                        descriptor,
                        handle: handle,
                        customStop: shouldStop
                    ) {
                    case .timedOut:
                        continue
                    case .failed:
                        if !Self.shouldStop(handle: handle, customStop: shouldStop) {
                            readError = "poll failed: \(String(cString: strerror(errno)))"
                        }
                        break readLoop
                    case .ready:
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = read(descriptor.fd, &bytes, bytes.count)
                        if count > 0 {
                            retryDelay = retryInitialDelay
                            let samples = lineBuffer.append(Data(bytes: bytes, count: count))
                            ingestSamples(
                                samples,
                                handle: handle,
                                customStop: shouldStop,
                                ingest: ingest
                            )
                            continue
                        }
                        if count == 0 {
                            reachedEOF = true
                            break readLoop
                        }
                        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                            continue
                        }
                        if !Self.shouldStop(handle: handle, customStop: shouldStop) {
                            readError = "read failed: \(String(cString: strerror(errno)))"
                        }
                        break readLoop
                    }
                }

                handle.state.deactivate(descriptor)
                if Self.shouldStop(handle: handle, customStop: shouldStop) {
                    return
                }
                if reachedEOF {
                    onUnavailable("FIFO \(path) reached EOF")
                } else if let readError {
                    onUnavailable("FIFO \(path) \(readError)")
                }

                guard Self.waitBeforeRetry(
                    retryDelay,
                    handle: handle,
                    customStop: shouldStop
                ) else {
                    return
                }
                retryDelay = min(retryDelay * 2, retryMaximumDelay)
            }
        }
        return handle
    }

    public static func startSocket(
        path: String,
        onWaiting: @escaping @Sendable () -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onDisconnected: @escaping @Sendable () -> Void,
        ingest: @escaping @Sendable (RawSensorSample) -> Void,
        shouldStop: @escaping @Sendable () -> Bool = { false }
    ) -> SensorLineReaderHandle {
        let handle = SensorLineReaderHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            handle.state.workerStarted()
            defer { handle.state.workerFinished() }
            while !Self.shouldStop(handle: handle, customStop: shouldStop) {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    if Self.shouldStop(handle: handle, customStop: shouldStop) {
                        return
                    }
                    guard Self.waitBeforeRetry(
                        1.0,
                        handle: handle,
                        customStop: shouldStop
                    ) else {
                        return
                    }
                    continue
                }

                guard let descriptor = handle.state.install(fd) else {
                    return
                }

                if nomas_unix_socket_connect(fd, path) != 0 {
                    handle.state.deactivate(descriptor)
                    if Self.shouldStop(handle: handle, customStop: shouldStop) {
                        return
                    }
                    onWaiting()
                    guard Self.waitBeforeRetry(
                        1.0,
                        handle: handle,
                        customStop: shouldStop
                    ) else {
                        return
                    }
                    continue
                }

                // Poll before reading so a stop does not leave the worker in
                // a blocking read. The descriptor is also closed by stop().
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)

                if Self.shouldStop(handle: handle, customStop: shouldStop) {
                    handle.state.deactivate(descriptor)
                    return
                }
                onConnected()

                var lineBuffer = SensorLineBuffer()
                readLoop: while !Self.shouldStop(handle: handle, customStop: shouldStop) {
                    switch Self.waitForReadable(
                        descriptor,
                        handle: handle,
                        customStop: shouldStop
                    ) {
                    case .timedOut:
                        continue
                    case .failed:
                        break readLoop
                    case .ready:
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = read(descriptor.fd, &bytes, bytes.count)
                        if count > 0 {
                            let samples = lineBuffer.append(Data(bytes: bytes, count: count))
                            ingestSamples(
                                samples,
                                handle: handle,
                                customStop: shouldStop,
                                ingest: ingest
                            )
                            continue
                        }
                        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                            continue
                        }
                        break readLoop
                    }
                }

                handle.state.deactivate(descriptor)
                if !Self.shouldStop(handle: handle, customStop: shouldStop) {
                    onDisconnected()
                }
                if Self.shouldStop(handle: handle, customStop: shouldStop) {
                    return
                }
                guard Self.waitBeforeRetry(
                    1.0,
                    handle: handle,
                    customStop: shouldStop
                ) else {
                    return
                }
            }
        }
        return handle
    }

    private static func shouldStop(
        handle: SensorLineReaderHandle,
        customStop: @escaping @Sendable () -> Bool
    ) -> Bool {
        handle.state.isStopped || customStop()
    }

    private static func waitBeforeRetry(
        _ delay: TimeInterval,
        handle: SensorLineReaderHandle,
        customStop: @escaping @Sendable () -> Bool
    ) -> Bool {
        var remaining = delay
        while remaining > 0 {
            guard !shouldStop(handle: handle, customStop: customStop) else {
                return false
            }
            let slice = min(remaining, 0.05)
            Thread.sleep(forTimeInterval: slice)
            remaining -= slice
        }
        return !shouldStop(handle: handle, customStop: customStop)
    }

    private static func waitForReadable(
        _ descriptor: SensorLineReaderDescriptor,
        handle: SensorLineReaderHandle,
        customStop: @escaping @Sendable () -> Bool
    ) -> DescriptorWaitResult {
        while !shouldStop(handle: handle, customStop: customStop) {
            var event = pollfd(
                fd: descriptor.fd,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&event, 1, pollTimeoutMilliseconds)
            if result > 0 {
                return .ready
            }
            if result == 0 {
                return .timedOut
            }
            if errno == EINTR {
                continue
            }
            return .failed
        }
        return .failed
    }

    private static func ingestSamples(
        _ samples: [RawSensorSample],
        handle: SensorLineReaderHandle,
        customStop: @escaping @Sendable () -> Bool,
        ingest: @escaping @Sendable (RawSensorSample) -> Void
    ) {
        guard !samples.isEmpty else {
            return
        }
        for sample in samples {
            guard !shouldStop(handle: handle, customStop: customStop) else {
                return
            }
            ingest(sample)
        }
    }
}

public func sensorStatusMenuTitle(
    _ base: String,
    input: SensorInputKind,
    directIOKitStage: String? = nil
) -> String {
    switch input {
    case .systemDeviceMotion:
        return base.replacingOccurrences(of: "Sensor:", with: "Sensor 6-axis:")
    case .fifo:
        return base.replacingOccurrences(of: "Sensor:", with: "Sensor FIFO:")
    case .helperSocket:
        return base.replacingOccurrences(of: "Sensor:", with: "Sensor helper:")
    case .direct:
        if base == "Sensor: waiting for samples" || base == "Sensor: stale samples" {
            return "\(base) (\(directIOKitStage ?? ""))"
        }
        return base
    }
}
