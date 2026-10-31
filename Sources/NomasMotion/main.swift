import AppKit
import Darwin
import Foundation
import NomasMotionCore
import NomasMotionOverlay

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processor = MotionProcessor()
    private let settingsStore = NomasMotionSettingsStore()
    private var overlayController: OverlayController!
    private var menuController: AppMenuController!
    private let startOverlayVisible = ProcessInfo.processInfo.environment["NOMAS_MOTION_START_VISIBLE"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let launchAtLoginError = LaunchAtLoginController.registerIfAppropriate() {
            fputs("Launch-at-login registration skipped: \(launchAtLoginError)\n", stderr)
        }
        let settings = settingsStore.settings
        let dotColorMode = DotColorMode(rawValue: settings.dotColorRawValue) ?? .gray
        let tuning = settings.tuning
        processor.applyTuning(tuning)
        overlayController = OverlayController(processor: processor, dotColorMode: dotColorMode, tuning: tuning)
        menuController = AppMenuController(
            processor: processor,
            overlayController: overlayController,
            tuning: tuning,
            dotColorMode: dotColorMode,
            settingsStore: settingsStore
        )
        menuController.installMenuBar(startOverlayVisible: startOverlayVisible)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuController?.shutdown()
    }
}

if CommandLine.arguments.dropFirst().contains("--unregister-login-item") {
    if let error = LaunchAtLoginController.unregister() {
        fputs("Could not unregister Nomas Motion launch item: \(error)\n", stderr)
        Foundation.exit(1)
    }
    Foundation.exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

func terminationSignalSource(for signalNumber: Int32) -> DispatchSourceSignal {
    Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            NSApp.terminate(nil)
        }
    }
    source.resume()
    return source
}

let terminationSignalSources = [
    terminationSignalSource(for: SIGTERM),
    terminationSignalSource(for: SIGINT),
]
withExtendedLifetime(terminationSignalSources) {
    app.run()
}
