import CoreGraphics
import Foundation
import NomasMotionCore
import NomasMotionOverlay

@MainActor
enum NomasMotionVerifyCommand {
    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "all"

        switch command {
        case "all":
            // Keep the no-argument command useful for existing local scripts,
            // but do not silently duplicate XCTest's production assertions.
            try SnapshotVerify.run(
                outputPath: "/tmp/nomas-motion-overlay-snapshot.png",
                modeName: "dark"
            )
            print("NomasMotionVerify offscreen snapshot passed")
        case "core", "overlay", "scenarios":
            throw VerifyError.failed(
                "\(command) is covered by XCTest; run `swift test` instead of the removed duplicate CLI suite"
            )
        case "snapshot":
            guard arguments.count <= 5 else {
                throw VerifyError.failed("snapshot accepts at most path, mode, dx, and dy")
            }
            let outputPath = arguments.dropFirst().first ?? "/tmp/nomas-motion-overlay-snapshot.png"
            let mode = arguments.dropFirst().dropFirst().first ?? "dark"
            let dx = try parseSnapshotNumber(arguments.dropFirst().dropFirst().dropFirst().first, name: "dx")
            let dy = try parseSnapshotNumber(arguments.dropFirst().dropFirst().dropFirst().dropFirst().first, name: "dy")
            try SnapshotVerify.run(
                outputPath: outputPath,
                modeName: mode,
                motionOffset: CGSize(width: dx, height: dy)
            )
        default:
            fputs(
                """
                Usage: NomasMotionVerify [snapshot [path] [dark|light] [dx] [dy]]
                Production behavior: swift test (requires Xcode.app for XCTest)

                """,
                stderr
            )
            throw VerifyError.failed("unknown command: \(command)")
        }
    }

    private static func parseSnapshotNumber(_ value: String?, name: String) throws -> Double {
        guard let value else { return 0.0 }
        guard let parsed = Double(value), parsed.isFinite else {
            throw VerifyError.failed("snapshot \(name) must be a finite number")
        }
        return parsed
    }
}

do {
    try NomasMotionVerifyCommand.run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
