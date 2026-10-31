import AppKit
import CAccelerometer
import Darwin
import Foundation
import NomasMotionCore
import NomasMotionOverlay

@MainActor
final class AppMenuController {
    private static let maximumAutoSampleAge: TimeInterval = 0.5

    private enum OverlayControlMode {
        case hidden
        case manual
        case automatic
    }

    private let processor: MotionProcessor
    private let overlayController: OverlayController
    private let settingsStore: NomasMotionSettingsStore
    private let fifoPath: String?
    private let socketPath: String
    private let makeDeviceMotionReader: @MainActor () -> any SystemDeviceMotionReading

    private var statusItem: NSStatusItem!
    private var manualOverlayItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var sensorItem: NSMenuItem!
    private var statusTimer: Timer?
    private var autoEnableTimer: Timer?
    private var sensorStarted = false
    private var sensorInput = SensorInputKind.direct
    private var sensorReaderHandle: SensorLineReaderHandle?
    private var socketWaitCount = 0
    private var systemDeviceMotionReader: (any SystemDeviceMotionReading)?
    private var dotColorMode = DotColorMode.gray
    private var tuning: NomasMotionTuning
    private var settingsWindowController: SettingsWindowController?
    private let statisticsStore: TripStatisticsStore
    private var overlayMode = OverlayControlMode.hidden
    private var travelAutoDetector = TravelAutoDetector()
    private let directSensorQueue = DispatchQueue(label: "app.nomas.motion.sensor.direct", qos: .userInitiated)
    private var sensorStartGeneration: UInt64 = 0
    private var isShuttingDown = false

    var overlayVisible: Bool {
        overlayController.isVisible
    }

    func finishStatisticsSession() {
        statisticsStore.finishOpenTrip(now: Date(), atLastFreshSample: true)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        sensorStartGeneration &+= 1
        statusTimer?.invalidate()
        autoEnableTimer?.invalidate()
        statusTimer = nil
        autoEnableTimer = nil
        systemDeviceMotionReader?.stop()
        systemDeviceMotionReader = nil
        sensorReaderHandle?.stop()
        sensorReaderHandle = nil
        stopDirectAccelerometer()
        sensorStarted = false
        overlayController.hide()
        finishStatisticsSession()
    }

    init(
        processor: MotionProcessor,
        overlayController: OverlayController,
        tuning: NomasMotionTuning = .defaults,
        dotColorMode: DotColorMode = .gray,
        settingsStore: NomasMotionSettingsStore,
        statisticsStore: TripStatisticsStore = TripStatisticsStore(),
        socketPath: String = ProcessInfo.processInfo.environment["NOMAS_MOTION_SENSOR_SOCKET"] ?? "/var/run/nomas-motion-sensor.sock",
        makeDeviceMotionReader: @escaping @MainActor () -> any SystemDeviceMotionReading = { SystemDeviceMotionReader() }
    ) {
        self.processor = processor
        self.overlayController = overlayController
        self.settingsStore = settingsStore
        self.statisticsStore = statisticsStore
        self.tuning = tuning
        self.dotColorMode = dotColorMode
        self.fifoPath = ProcessInfo.processInfo.environment["NOMAS_MOTION_SENSOR_PIPE"]
        self.socketPath = socketPath
        self.makeDeviceMotionReader = makeDeviceMotionReader
    }

    func installMenuBar(startOverlayVisible: Bool) {
        setupMenu()
        startSensor()
        startAutoEnableUpdates()
        startStatusUpdates()
        if startOverlayVisible {
            overlayController.show()
            overlayMode = overlayController.isVisible ? .manual : .hidden
        } else {
            overlayMode = .hidden
        }
        updateManualOverlayMenu()
        updateAutomaticCueMenu()
        openLaunchWindowIfRequested()
    }

    func applyTuning(_ newTuning: NomasMotionTuning) {
        let validated = NomasMotionSettingsStore.validated(newTuning)
        travelAutoDetector.reset()
        tuning = validated
        processor.applyTuning(validated)
        overlayController.tuning = validated
        settingsStore.update(tuning: validated, dotColorRawValue: dotColorMode.rawValue)
        if !validated.autoEnableEnabled {
            if overlayMode == .automatic {
                overlayController.hide()
                overlayMode = .hidden
                updateManualOverlayMenu()
            }
        }
        updateAutomaticCueMenu()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.image = Self.makeStatusIcon(active: false)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Nomas Motion"

        let menu = NSMenu()
        manualOverlayItem = NSMenuItem(title: "Show Cues", action: #selector(toggleManualOverlay), keyEquivalent: "")
        manualOverlayItem.target = self
        menu.addItem(manualOverlayItem)

        toggleItem = NSMenuItem(title: "Automatic Cues", action: #selector(toggleAutomaticCues), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let statistics = NSMenuItem(title: "Statistics...", action: #selector(openStatistics), keyEquivalent: "")
        statistics.target = self
        menu.addItem(statistics)

        menu.addItem(.separator())
        sensorItem = NSMenuItem(title: "Sensor: starting", action: nil, keyEquivalent: "")
        sensorItem.isEnabled = false
        menu.addItem(sensorItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nomas Motion", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateManualOverlayMenu()
    }

    private func startSensor() {
        guard !isShuttingDown else { return }
        if let fifoPath, !fifoPath.isEmpty {
            startFifoReader(path: fifoPath)
            return
        }
        if startSystemDeviceMotion() {
            return
        }
        startFallbackSensor()
    }

    private func startSystemDeviceMotion() -> Bool {
        guard !isShuttingDown else { return false }
        let reader = makeDeviceMotionReader()
        let started = reader.start(
            onSample: { [weak self] sample in
                guard let self else { return }
                self.processor.ingest(sample)
                if !self.sensorStarted {
                    self.sensorStarted = true
                    self.sensorInput = .systemDeviceMotion
                    self.sensorItem.title = "Sensor: active (system 6-axis)"
                    fputs("Sensor: using system 6-axis device motion\n", stderr)
                }
            },
            onUnavailable: { [weak self] in
                guard let self else { return }
                self.systemDeviceMotionReader = nil
                if !self.isShuttingDown {
                    self.startFallbackSensor()
                }
            }
        )
        guard started else {
            return false
        }
        systemDeviceMotionReader = reader
        sensorStarted = false
        sensorItem.title = "Sensor: starting system 6-axis"
        return true
    }

    private func startFallbackSensor() {
        guard !isShuttingDown else { return }
        if geteuid() != 0 || FileManager.default.fileExists(atPath: socketPath) {
            startSocketReader(path: socketPath)
        } else {
            startAccelerometer()
        }
    }

    private func startAccelerometer() {
        guard !isShuttingDown else { return }
        sensorReaderHandle?.stop()
        sensorReaderHandle = nil
        sensorInput = .direct
        sensorStarted = false
        sensorItem.title = "Sensor: starting direct fallback"
        sensorStartGeneration &+= 1
        let generation = sensorStartGeneration
        let processor = processor
        directSensorQueue.async { [weak self] in
            let result = startDirectAccelerometer(processor: processor)
            let message = String(cString: nomas_accel_error_message(result))
            let stage = String(cString: nomas_accel_last_stage())
            DispatchQueue.main.async {
                guard let self else {
                    if result == NOMAS_ACCEL_OK { stopDirectAccelerometer() }
                    return
                }
                guard !self.isShuttingDown, self.sensorStartGeneration == generation else {
                    if result == NOMAS_ACCEL_OK { stopDirectAccelerometer() }
                    return
                }
                self.sensorStarted = result == NOMAS_ACCEL_OK
                self.sensorItem.title = result == NOMAS_ACCEL_OK
                    ? "Sensor: active"
                    : "Sensor: \(message) (\(stage))"
            }
        }
    }

    private func startSocketReader(path: String) {
        sensorReaderHandle?.stop()
        sensorStarted = false
        sensorInput = .helperSocket
        socketWaitCount = 0
        sensorItem.title = "Sensor: connecting"
        sensorStartGeneration &+= 1
        let generation = sensorStartGeneration

        sensorReaderHandle = SensorLineReader.startSocket(
            path: path,
            onWaiting: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isShuttingDown,
                          self.sensorInput == .helperSocket,
                          self.sensorStartGeneration == generation else { return }
                    self.sensorStarted = false
                    self.socketWaitCount += 1
                    if self.socketWaitCount >= 3, geteuid() == 0 {
                        self.sensorReaderHandle?.stop()
                        self.sensorReaderHandle = nil
                        self.sensorItem.title = "Sensor: helper unavailable; trying direct"
                        self.startAccelerometer()
                    } else {
                        self.sensorItem.title = "Sensor: waiting for helper"
                    }
                }
            },
            onConnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isShuttingDown,
                          self.sensorInput == .helperSocket,
                          self.sensorStartGeneration == generation else { return }
                    self.socketWaitCount = 0
                    self.sensorStarted = true
                    self.sensorItem.title = "Sensor: connected"
                }
            },
            onDisconnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isShuttingDown,
                          self.sensorInput == .helperSocket,
                          self.sensorStartGeneration == generation else { return }
                    self.sensorStarted = false
                    self.sensorItem.title = "Sensor: helper disconnected"
                }
            },
            ingest: { [processor] sample in
                processor.ingest(sample)
            }
        )
    }

    private func startFifoReader(path: String) {
        sensorReaderHandle?.stop()
        sensorStarted = false
        sensorInput = .fifo
        sensorItem.title = "Sensor: synthetic input"
        sensorStartGeneration &+= 1
        let generation = sensorStartGeneration

        sensorReaderHandle = SensorLineReader.startFIFO(
            path: path,
            ingest: { [processor] sample in
                processor.ingest(sample)
            },
            onUnavailable: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isShuttingDown,
                          self.sensorInput == .fifo,
                          self.sensorStartGeneration == generation else { return }
                    self.sensorStarted = false
                    self.sensorItem.title = "Sensor: \(message)"
                }
            }
        )
    }

    private func startStatusUpdates() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShuttingDown else { return }
                let cue = self.processor.currentCue(maximumSampleAge: Self.maximumAutoSampleAge)
                if self.sensorInput == .fifo {
                    self.sensorStarted = cue.hasSamples
                }
                if self.sensorStarted, cue.hasSamples {
                    self.statisticsStore.record(cue: cue, now: Date(), motionThreshold: self.tuning.autoEnableThreshold)
                }
                if self.sensorStarted || self.sensorInput == .fifo {
                    let directStage = self.sensorInput == .direct ? String(cString: nomas_accel_last_stage()) : nil
                    self.sensorItem.title = sensorStatusMenuTitle(
                        self.processor.statusText(maximumSampleAge: Self.maximumAutoSampleAge),
                        input: self.sensorInput,
                        directIOKitStage: directStage
                    )
                }
                self.updateStatusIcon(cue: cue)
            }
        }
        RunLoop.main.add(statusTimer!, forMode: .common)
    }

    private func startAutoEnableUpdates() {
        autoEnableTimer = Timer.scheduledTimer(withTimeInterval: nomasMotionAutoDetectionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAutoEnable(cue: self.processor.currentCue(maximumSampleAge: Self.maximumAutoSampleAge))
            }
        }
        RunLoop.main.add(autoEnableTimer!, forMode: .common)
    }

    @objc private func toggleAutomaticCues() {
        var updated = tuning
        updated.autoEnableEnabled.toggle()
        applyTuning(updated)
        travelAutoDetector.reset()
        updateStatusIcon(cue: processor.currentCue(maximumSampleAge: Self.maximumAutoSampleAge))
    }

    private func updateAutomaticCueMenu() {
        guard toggleItem != nil else { return }
        toggleItem.title = "Automatic Cues"
        toggleItem.state = tuning.autoEnableEnabled ? .on : .off
    }

    @objc private func toggleManualOverlay() {
        if overlayController.isVisible {
            overlayController.hide()
            overlayMode = .hidden
        } else {
            overlayController.show()
            overlayMode = overlayController.isVisible ? .manual : .hidden
        }
        travelAutoDetector.reset()
        updateManualOverlayMenu()
        updateStatusIcon(cue: processor.currentCue(maximumSampleAge: Self.maximumAutoSampleAge))
    }

    private func updateManualOverlayMenu() {
        guard manualOverlayItem != nil else { return }
        let isVisible = overlayController.isVisible
        manualOverlayItem.title = isVisible ? "Hide Cues" : "Show Cues"
        manualOverlayItem.state = isVisible ? .on : .off
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                tuning: tuning,
                dotColorMode: dotColorMode,
                statisticsStore: statisticsStore,
                currentTuning: { [weak self] in self?.tuning ?? .defaults },
                onChange: { [weak self] newTuning in
                    self?.applyTuning(newTuning)
                },
                onDotColorChange: { [weak self] mode in
                    self?.setDotColorMode(mode)
                }
            )
        }
        settingsWindowController?.show(current: tuning, dotColorMode: dotColorMode, page: .settings)
    }

    @objc private func openStatistics() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                tuning: tuning,
                dotColorMode: dotColorMode,
                statisticsStore: statisticsStore,
                currentTuning: { [weak self] in self?.tuning ?? .defaults },
                onChange: { [weak self] newTuning in
                    self?.applyTuning(newTuning)
                },
                onDotColorChange: { [weak self] mode in
                    self?.setDotColorMode(mode)
                }
            )
        }
        settingsWindowController?.show(current: tuning, dotColorMode: dotColorMode, page: .statistics)
    }

    private func openLaunchWindowIfRequested() {
        if ProcessInfo.processInfo.environment["NOMAS_MOTION_OPEN_STATISTICS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.openStatistics()
            }
        } else if ProcessInfo.processInfo.environment["NOMAS_MOTION_OPEN_SETTINGS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
    }

    private func setDotColorMode(_ mode: DotColorMode) {
        dotColorMode = mode
        overlayController.dotColorMode = mode
        settingsStore.updateDotColorRawValue(mode.rawValue)
    }

    private func updateAutoEnable(cue: VehicleMotionCue) {
        guard sensorStarted, Self.displayIsActive() else {
            travelAutoDetector.reset()
            if overlayMode == .automatic {
                overlayController.hide()
                overlayMode = .hidden
                updateManualOverlayMenu()
            }
            return
        }

        switch travelAutoDetector.update(cue: cue, overlayVisible: overlayController.isVisible, tuning: tuning) {
        case .none:
            break
        case .show:
            overlayController.show()
            overlayMode = overlayController.isVisible ? .automatic : .hidden
            updateManualOverlayMenu()
            updateStatusIcon(cue: cue)
        case .hide:
            if overlayMode == .automatic {
                overlayController.hide()
                overlayMode = .hidden
                travelAutoDetector.reset()
                updateManualOverlayMenu()
                updateStatusIcon(cue: cue)
            }
        }
    }

    private func updateStatusIcon(cue: VehicleMotionCue) {
        let motionActive = cue.hasSamples && hypot(cue.dynamicX, cue.dynamicY) >= tuning.autoEnableThreshold
        statusItem.button?.image = Self.makeStatusIcon(active: overlayController.isVisible || motionActive)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func makeStatusIcon(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let activeAlpha = active ? 0.95 : 0.34
        let inactiveAlpha = active ? 0.30 : 0.14
        for column in 0..<5 {
            let isRail = column == 0 || column == 4
            NSColor.black.withAlphaComponent(isRail ? activeAlpha : inactiveAlpha).setFill()
            for row in 0..<4 {
                let x = 3.0 + Double(column) * 3.0
                let y = 4.0 + Double(row) * 3.2
                NSBezierPath(ovalIn: NSRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func displayIsActive() -> Bool {
        CGDisplayIsActive(CGMainDisplayID()) != 0
    }
}
