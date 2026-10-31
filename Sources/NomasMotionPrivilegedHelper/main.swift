import CAccelerometer
import Darwin
import Foundation
import NomasMotionCore

private let defaultSocketPath = "/var/run/nomas-motion-sensor.sock"
private let maximumClientCount = 8

private func removeExistingSocket(at path: String) throws {
    var metadata = stat()
    if lstat(path, &metadata) == 0 {
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK else {
            throw HelperError.message("refusing to replace non-socket at \(path)")
        }
        guard unlink(path) == 0 else {
            throw HelperError.posix("unlink")
        }
    } else if errno != ENOENT {
        throw HelperError.posix("lstat")
    }
}

final class SensorSocketServer: @unchecked Sendable {
    private struct Client {
        let fd: Int32
        var pending: Data?
    }

    private enum SendResult {
        case complete
        case wouldBlock(Data)
        case broken
    }

    private let ioQueue = DispatchQueue(label: "app.nomas.motion.privileged-helper.client-io")
    private let ioQueueKey = DispatchSpecificKey<Void>()
    private var clients: [Client] = []
    private var serverFD: Int32 = -1
    private var socketPath: String?
    private var expectedUID: uid_t = 0
    private var stopping = false
    private var terminationRequested = false
    private var sampleCount = 0
    private var lastReport = Date()

    init() {
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    func start(path: String, expectedUID: uid_t) throws {
        guard path == defaultSocketPath else {
            throw HelperError.message("socket path must be /var/run/nomas-motion-sensor.sock")
        }

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw HelperError.posix("socket")
        }

        try removeExistingSocket(at: path)
        guard nomas_unix_socket_bind(serverFD, path) == 0 else {
            close(serverFD)
            throw HelperError.posix("bind")
        }

        guard chown(path, expectedUID, gid_t.max) == 0 else {
            close(serverFD)
            unlink(path)
            throw HelperError.posix("chown")
        }
        guard chmod(path, 0o600) == 0 else {
            close(serverFD)
            unlink(path)
            throw HelperError.posix("chmod")
        }
        guard fcntl(serverFD, F_SETFL, O_NONBLOCK) == 0 else {
            close(serverFD)
            unlink(path)
            throw HelperError.posix("fcntl")
        }
        guard listen(serverFD, 8) == 0 else {
            close(serverFD)
            unlink(path)
            throw HelperError.posix("listen")
        }

        ioQueue.sync {
            self.serverFD = serverFD
            self.socketPath = path
            self.expectedUID = expectedUID
            self.stopping = false
            self.terminationRequested = false
        }

        fputs("Nomas Motion privileged helper socket listening at \(path) (uid \(expectedUID))\n", stderr)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(serverFD: serverFD)
        }
    }

    func stop() {
        syncOnIOQueue {
            stopOnIOQueue()
        }
    }

    func requestTermination() -> Bool {
        syncOnIOQueue {
            guard !terminationRequested else {
                return false
            }
            terminationRequested = true
            return true
        }
    }

    deinit {
        stop()
    }

    func broadcast(_ sample: RawSensorSample) {
        guard let data = sample.line.data(using: .utf8) else {
            return
        }

        // The sensor callback must return immediately. Client IO and lifecycle
        // changes are serialized on ioQueue, so a closed FD cannot be reused
        // while a broadcast is still sending to it.
        ioQueue.async { [weak self] in
            self?.broadcastOnIOQueue(data)
        }
    }

    func currentSampleCount() -> Int {
        syncOnIOQueue { sampleCount }
    }

    /// Reap disconnected peers even when the sensor is not producing samples.
    /// The process-level monitor calls this once per second, while the queue
    /// wrapper keeps pruning serialized with accepts and broadcasts.
    func pruneDisconnectedClients() {
        syncOnIOQueue {
            pruneDisconnectedClientsOnIOQueue()
        }
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            let (isStopping, expectedUID) = ioQueue.sync {
                (stopping || self.serverFD != serverFD, self.expectedUID)
            }
            if isStopping {
                return
            }

            let client = accept(serverFD, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                return
            }

            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == expectedUID else {
                close(client)
                continue
            }

            guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else {
                close(client)
                continue
            }

            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            ioQueue.async { [weak self] in
                guard let self else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    return
                }
                self.pruneDisconnectedClientsOnIOQueue()
                guard !self.stopping, self.clients.count < maximumClientCount else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    return
                }
                self.clients.append(Client(fd: client, pending: nil))
                fputs("Nomas Motion app connected to privileged helper.\n", stderr)
            }
        }
    }

    private func syncOnIOQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            return body()
        }
        return ioQueue.sync(execute: body)
    }

    private func stopOnIOQueue() {
        guard !stopping || serverFD >= 0 || !clients.isEmpty else {
            return
        }

        stopping = true
        let fd = serverFD
        serverFD = -1
        let path = socketPath
        socketPath = nil
        let clientsToClose = clients
        clients.removeAll(keepingCapacity: false)

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for client in clientsToClose {
            shutdown(client.fd, SHUT_RDWR)
            close(client.fd)
        }
        if let path {
            unlink(path)
        }
    }

    private func broadcastOnIOQueue(_ data: Data) {
        guard !stopping else {
            return
        }

        sampleCount += 1
        let shouldReport = Date().timeIntervalSince(lastReport) >= 2
        if shouldReport {
            lastReport = Date()
        }

        var activeClients: [Client] = []
        activeClients.reserveCapacity(clients.count)
        for var client in clients {
            if let pending = client.pending {
                switch sendAll(pending, to: client.fd) {
                case .complete:
                    client.pending = nil
                case .wouldBlock(let remainder):
                    client.pending = remainder.isEmpty ? nil : remainder
                    activeClients.append(client)
                    continue
                case .broken:
                    closeClient(client.fd)
                    continue
                }
            }

            switch sendAll(data, to: client.fd) {
            case .complete:
                activeClients.append(client)
            case .wouldBlock(let remainder):
                // A full nonblocking socket only drops this sample. Preserve a
                // partial line so the next flush cannot corrupt framing.
                client.pending = remainder.count < data.count ? remainder : nil
                activeClients.append(client)
            case .broken:
                closeClient(client.fd)
            }
        }
        clients = activeClients

        if shouldReport {
            fputs("Nomas Motion privileged helper samples: \(sampleCount), clients: \(clients.count)\n", stderr)
        }
    }

    /// Reap peers even when the accelerometer is quiet. Without this check,
    /// disconnected clients are noticed only by a later sample broadcast and
    /// can consume the eight-client limit indefinitely.
    private func pruneDisconnectedClientsOnIOQueue() {
        clients = clients.filter { client in
            var byte: UInt8 = 0
            let result = recv(client.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if result == 0 {
                closeClient(client.fd)
                return false
            }
            if result < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                closeClient(client.fd)
                return false
            }
            return true
        }
    }

    private func sendAll(_ data: Data, to client: Int32) -> SendResult {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { rawBuffer in
                send(client, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                return .broken
            }

            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK, ENOBUFS:
                return .wouldBlock(data.subdata(in: offset..<data.count))
            default:
                return .broken
            }
        }
        return .complete
    }

    private func closeClient(_ client: Int32) {
        shutdown(client, SHUT_RDWR)
        close(client)
    }
}

enum HelperError: Error, CustomStringConvertible {
    case posix(String)
    case message(String)

    var description: String {
        switch self {
        case .posix(let operation):
            return "\(operation) failed: \(String(cString: strerror(errno)))"
        case .message(let message):
            return message
        }
    }
}

@_cdecl("nomasMotionPrivilegedHelperCallback")
func nomasMotionPrivilegedHelperCallback(_ x: Int32, _ y: Int32, _ z: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let server = Unmanaged<SensorSocketServer>.fromOpaque(context).takeUnretainedValue()
    server.broadcast(RawSensorSample(x: x, y: y, z: z))
}

private func parseUID(_ rawValue: String) -> uid_t? {
    guard let value = UInt32(rawValue), value <= UInt32(uid_t.max) else {
        return nil
    }
    return uid_t(value)
}

private func fallbackSocketUID() -> uid_t {
    var consoleStatus = stat()
    let result = "/dev/console".withCString { path in
        stat(path, &consoleStatus)
    }
    if result == 0 {
        return consoleStatus.st_uid
    }
    return getuid()
}

@main
struct NomasMotionPrivilegedHelper {
    private static let terminationQueue = DispatchQueue(label: "app.nomas.motion.privileged-helper.termination")

    private static func terminationSources(for server: SensorSocketServer) -> [DispatchSourceSignal] {
        Darwin.signal(SIGTERM, SIG_IGN)
        Darwin.signal(SIGINT, SIG_IGN)

        return [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: terminationQueue
            )
            source.setEventHandler {
                guard server.requestTermination() else {
                    return
                }
                server.stop()
                nomas_accel_stop()
                Foundation.exit(0)
            }
            source.resume()
            return source
        }
    }

    static func main() {
        guard geteuid() == 0 else {
            fputs("Nomas Motion privileged helper must run as root via launchd.\n", stderr)
            Foundation.exit(1)
        }

        let arguments = Array(CommandLine.arguments.dropFirst())
        let socketPath = arguments.first ?? defaultSocketPath
        guard socketPath == defaultSocketPath else {
            fputs("Nomas Motion privileged helper only accepts socket path /var/run/nomas-motion-sensor.sock.\n", stderr)
            Foundation.exit(1)
        }
        let expectedUID: uid_t
        if let rawUID = arguments.dropFirst().first {
            guard let parsedUID = parseUID(rawUID) else {
                fputs("Nomas Motion privileged helper received an invalid socket UID: \(rawUID)\n", stderr)
                Foundation.exit(1)
            }
            expectedUID = parsedUID
        } else if let rawUID = ProcessInfo.processInfo.environment["NOMAS_MOTION_SENSOR_UID"], let parsedUID = parseUID(rawUID) {
            expectedUID = parsedUID
        } else {
            // Older launchd plists passed only the path. Prefer the console
            // user so the compatibility path remains user-private.
            expectedUID = fallbackSocketUID()
        }

        let server = SensorSocketServer()
        do {
            try server.start(path: socketPath, expectedUID: expectedUID)
        } catch {
            fputs("Nomas Motion privileged helper failed to start socket: \(error)\n", stderr)
            Foundation.exit(1)
        }

        let terminationSources = terminationSources(for: server)
        let context = Unmanaged.passUnretained(server).toOpaque()
        let result = nomas_accel_start(nomasMotionPrivilegedHelperCallback, context)
        guard result == NOMAS_ACCEL_OK else {
            fputs("Nomas Motion privileged helper sensor failed: \(String(cString: nomas_accel_error_message(result)))\n", stderr)
            fputs("Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
            server.stop()
            Foundation.exit(1)
        }

        fputs("Nomas Motion privileged helper started. Streaming raw samples to socket clients.\n", stderr)
        withExtendedLifetime(terminationSources) {
            while true {
                Thread.sleep(forTimeInterval: 1)
                server.pruneDisconnectedClients()
                if server.currentSampleCount() == 0 {
                    fputs("Nomas Motion privileged helper waiting for samples. Last sensor startup stage: \(String(cString: nomas_accel_last_stage()))\n", stderr)
                }
            }
        }
    }
}
