import AppKit
import NomasMotionCore
import NomasMotionOverlay

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    enum Page: Int {
        case settings
        case statistics
    }

    private enum SettingPreset: Int, CaseIterable {
        case min
        case less
        case defaultValue
        case more
        case max

        static let labels = ["Min", "Less", "Default", "More", "Max"]
    }

    private enum PreviewScenario {
        case still
        case horizontal
        case vertical
    }

    private struct SettingSpec {
        let key: String
        let title: String
        let detail: String
        let min: Double
        let max: Double
        let decimals: Int
        let previewScenario: PreviewScenario
    }

    private let onChange: (NomasMotionTuning) -> Void
    private let onDotColorChange: (DotColorMode) -> Void
    private let currentTuning: () -> NomasMotionTuning
    private let statisticsStore: TripStatisticsStore
    private var tuning: NomasMotionTuning
    private var lastShownTuning: NomasMotionTuning
    private var dotColorMode: DotColorMode
    private var pageControl: NSSegmentedControl!
    private var contentStack: NSStackView!
    private var settingControls: [String: NSSegmentedControl] = [:]
    private var settingFields: [String: NSTextField] = [:]
    private var autoEnableCheckbox: NSButton!
    private var dotColorControl: NSPopUpButton!
    private var preview: SettingsOverlayPreviewView!
    private var previewLabel: NSTextField!
    private var activePreviewKey = "horizontalGain"
    private var statisticsEnabledCheckbox: NSButton!
    private var summaryLabel: NSTextField!
    private var tripStack: NSStackView!
    private var commentField: NSTextField!

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(
        tuning: NomasMotionTuning,
        dotColorMode: DotColorMode,
        statisticsStore: TripStatisticsStore,
        currentTuning: @escaping () -> NomasMotionTuning,
        onChange: @escaping (NomasMotionTuning) -> Void,
        onDotColorChange: @escaping (DotColorMode) -> Void
    ) {
        self.tuning = tuning
        self.dotColorMode = dotColorMode
        self.statisticsStore = statisticsStore
        self.currentTuning = currentTuning
        self.lastShownTuning = tuning
        self.onChange = onChange
        self.onDotColorChange = onDotColorChange

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 680))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nomas Motion"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        super.init(window: window)
        buildShell(in: content)
        statisticsStore.onChange = { [weak self] in
            self?.refreshStatistics()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(current tuning: NomasMotionTuning, dotColorMode: DotColorMode, page: Page) {
        self.tuning = tuning
        self.lastShownTuning = tuning
        self.dotColorMode = dotColorMode
        pageControl.selectedSegment = page.rawValue
        rebuildContent(for: page)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildShell(in content: NSView) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])

        pageControl = NSSegmentedControl(labels: ["Settings", "Statistics"], trackingMode: .selectOne, target: self, action: #selector(pageChanged(_:)))
        pageControl.selectedSegment = Page.settings.rawValue
        root.addArrangedSubview(pageControl)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentStack)
        contentStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func rebuildContent(for page: Page) {
        settingControls = [:]
        settingFields = [:]
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch page {
        case .settings:
            buildSettingsPage()
            updateControlValues()
        case .statistics:
            buildStatisticsPage()
            refreshStatistics()
        }
    }

    private func buildSettingsPage() {
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 20
        contentStack.addArrangedSubview(columns)

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        columns.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalToConstant: 720).isActive = true

        let previewStack = NSStackView()
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 8
        columns.addArrangedSubview(previewStack)

        let topControls = NSStackView()
        topControls.orientation = .horizontal
        topControls.alignment = .centerY
        topControls.spacing = 14
        controls.addArrangedSubview(topControls)

        dotColorControl = NSPopUpButton()
        dotColorControl.addItems(withTitles: ["Gray dots", "Black dots", "White dots"])
        dotColorControl.target = self
        dotColorControl.action = #selector(dotColorChanged(_:))
        topControls.addArrangedSubview(labeledControl(title: "Dot color", detail: "Choose a fixed dot color for your workspace.", control: dotColorControl))

        autoEnableCheckbox = NSButton(checkboxWithTitle: "Auto mode", target: self, action: #selector(autoEnableChanged(_:)))
        topControls.addArrangedSubview(labeledControl(title: "Passive detection", detail: "Show after about fifteen seconds of travel-like motion.", control: autoEnableCheckbox))

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetToDefaults))
        topControls.addArrangedSubview(reset)

        let settingColumns = NSStackView()
        settingColumns.orientation = .horizontal
        settingColumns.alignment = .top
        settingColumns.spacing = 16
        controls.addArrangedSubview(settingColumns)

        let visualColumn = settingsColumn(title: "Overlay")
        let behaviorColumn = settingsColumn(title: "Motion")
        settingColumns.addArrangedSubview(visualColumn)
        settingColumns.addArrangedSubview(behaviorColumn)

        visualSettingSpecs.forEach { addSetting($0, to: visualColumn) }
        behaviorSettingSpecs.forEach { addSetting($0, to: behaviorColumn) }

        let previewTitle = NSTextField(labelWithString: "Preview")
        previewTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        previewStack.addArrangedSubview(previewTitle)

        previewLabel = NSTextField(labelWithString: "")
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11)
        previewStack.addArrangedSubview(previewLabel)

        preview = SettingsOverlayPreviewView(frame: NSRect(x: 0, y: 0, width: 410, height: 300))
        preview.widthAnchor.constraint(equalToConstant: 410).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 300).isActive = true
        previewStack.addArrangedSubview(preview)
    }

    private func settingsColumn(title: String) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.widthAnchor.constraint(equalToConstant: 350).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        column.addArrangedSubview(titleLabel)
        return column
    }

    private func addSetting(_ spec: SettingSpec, to stack: NSStackView) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4

        let titleLabel = NSTextField(labelWithString: spec.title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        group.addArrangedSubview(titleLabel)

        let detailLabel = NSTextField(labelWithString: spec.detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.maximumNumberOfLines = 2
        group.addArrangedSubview(detailLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let presetControl = NSSegmentedControl(labels: SettingPreset.labels, trackingMode: .selectOne, target: self, action: #selector(settingPresetChanged(_:)))
        presetControl.identifier = NSUserInterfaceItemIdentifier(spec.key)
        presetControl.controlSize = .small
        presetControl.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let valueField = NSTextField()
        valueField.identifier = NSUserInterfaceItemIdentifier(spec.key)
        valueField.alignment = .right
        valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueField.stringValue = formattedValue(spec: spec, value: value(for: spec.key))
        valueField.target = self
        valueField.action = #selector(settingFieldChanged(_:))
        valueField.delegate = self
        valueField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        row.addArrangedSubview(presetControl)
        row.addArrangedSubview(valueField)
        group.addArrangedSubview(row)
        stack.addArrangedSubview(group)

        settingControls[spec.key] = presetControl
        settingFields[spec.key] = valueField
    }

    private func labeledControl(title: String, detail: String, control: NSView) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 3
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        group.addArrangedSubview(titleLabel)
        group.addArrangedSubview(detailLabel)
        group.addArrangedSubview(control)
        return group
    }

    private func buildStatisticsPage() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(page)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            page.heightAnchor.constraint(equalToConstant: 410)
        ])

        let title = NSTextField(labelWithString: "Statistics")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(title)

        let explainer = NSTextField(labelWithString: "Trip history is local accelerometer-derived motion data. It never goes to a server and only leaves your Mac if you choose to send a false-positive bug report.")
        explainer.textColor = .secondaryLabelColor
        explainer.font = .systemFont(ofSize: 12)
        explainer.maximumNumberOfLines = 2
        explainer.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(explainer)

        statisticsEnabledCheckbox = NSButton(checkboxWithTitle: "Enable statistics collection", target: self, action: #selector(toggleStatisticsEnabled(_:)))
        statisticsEnabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(statisticsEnabledCheckbox)

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(summaryLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scrollView)

        tripStack = NSStackView()
        tripStack.orientation = .vertical
        tripStack.alignment = .leading
        tripStack.spacing = 8
        tripStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        tripStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tripStack

        commentField = NSTextField()
        commentField.stringValue = ""
        commentField.placeholderString = "Optional false-positive comment"
        commentField.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(commentField)

        let resetButton = NSButton(title: "Reset Statistics", target: self, action: #selector(resetStatistics))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(resetButton)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            title.topAnchor.constraint(equalTo: page.topAnchor),

            explainer.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            explainer.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            explainer.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),

            statisticsEnabledCheckbox.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            statisticsEnabledCheckbox.topAnchor.constraint(equalTo: explainer.bottomAnchor, constant: 12),

            summaryLabel.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: statisticsEnabledCheckbox.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            scrollView.heightAnchor.constraint(equalToConstant: 240),

            tripStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            commentField.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            commentField.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            commentField.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),

            resetButton.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            resetButton.topAnchor.constraint(equalTo: commentField.bottomAnchor, constant: 10)
        ])
    }

    private func updateControlValues() {
        for spec in allSettingSpecs {
            let currentValue = value(for: spec.key)
            settingControls[spec.key]?.selectedSegment = preset(for: currentValue, spec: spec)?.rawValue ?? -1
            settingFields[spec.key]?.stringValue = formattedValue(spec: spec, value: currentValue)
        }
        autoEnableCheckbox?.state = tuning.autoEnableEnabled ? .on : .off
        dotColorControl?.selectItem(at: dotColorMode.rawValue)
        preview?.tuning = tuning
        preview?.dotColorMode = dotColorMode
        focusPreview(for: activePreviewKey)
    }

    private func refreshStatistics() {
        statisticsEnabledCheckbox?.state = statisticsStore.isEnabled ? .on : .off
        let trips = statisticsStore.trips
        let totalSeconds = trips.reduce(0.0) { $0 + $1.durationSeconds }
        summaryLabel?.stringValue = "\(trips.count) trips recorded · \(formatDuration(totalSeconds)) total travel-like motion"
        commentField?.isHidden = trips.isEmpty
        if trips.isEmpty {
            commentField?.stringValue = ""
        }

        tripStack?.arrangedSubviews.forEach { view in
            tripStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if trips.isEmpty {
            let empty = NSTextField(labelWithString: statisticsStore.isEnabled ? "No trips recorded yet." : "Statistics collection is off.")
            empty.textColor = .secondaryLabelColor
            tripStack?.addArrangedSubview(empty)
            return
        }

        for trip in trips.reversed() {
            tripStack?.addArrangedSubview(makeTripRow(trip))
        }
    }

    private func makeTripRow(_ trip: TripRecord) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let label = NSTextField(labelWithString: "\(dateFormatter.string(from: trip.startedAt)) · \(formatDuration(trip.durationSeconds)) · \(trip.sampleCount) snapshots")
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 560).isActive = true
        row.addArrangedSubview(label)

        let report = NSButton(title: "Report", target: self, action: #selector(reportFalsePositive(_:)))
        report.identifier = NSUserInterfaceItemIdentifier(trip.id)
        row.addArrangedSubview(report)
        return row
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    @objc private func pageChanged(_ sender: NSSegmentedControl) {
        rebuildContent(for: Page(rawValue: sender.selectedSegment) ?? .settings)
    }

    @objc private func settingPresetChanged(_ sender: NSSegmentedControl) {
        guard
            let key = sender.identifier?.rawValue,
            let spec = settingSpec(for: key),
            let preset = SettingPreset(rawValue: sender.selectedSegment)
        else {
            return
        }
        applySettingValue(presetValue(preset, spec: spec), spec: spec)
    }

    @objc private func settingFieldChanged(_ sender: NSTextField) {
        commitFieldValue(sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        commitFieldValue(field)
    }

    private func commitFieldValue(_ field: NSTextField) {
        guard
            let key = field.identifier?.rawValue,
            let spec = settingSpec(for: key)
        else {
            return
        }
        let value = Double(field.stringValue) ?? self.value(for: key)
        applySettingValue(value, spec: spec)
    }

    private func applySettingValue(_ rawValue: Double, spec: SettingSpec) {
        syncAutoModeWithOwnerIfUnchanged()
        let clamped = min(spec.max, max(spec.min, rawValue))
        setValue(clamped, for: spec.key)
        settingFields[spec.key]?.stringValue = formattedValue(spec: spec, value: clamped)
        settingControls[spec.key]?.selectedSegment = preset(for: clamped, spec: spec)?.rawValue ?? -1
        preview?.tuning = tuning
        focusPreview(for: spec.key)
        publishTuningChange()
    }

    @objc private func autoEnableChanged(_ sender: NSButton) {
        tuning.autoEnableEnabled = sender.state == .on
        lastShownTuning = tuning
        focusPreview(for: "autoEnableThreshold")
        publishTuningChange()
    }

    @objc private func dotColorChanged(_ sender: NSPopUpButton) {
        guard let mode = DotColorMode(rawValue: sender.indexOfSelectedItem) else {
            return
        }
        dotColorMode = mode
        preview?.dotColorMode = mode
        focusPreview(for: "dotAlphaScale")
        onDotColorChange(mode)
    }

    @objc private func resetToDefaults() {
        tuning = .defaults
        dotColorMode = .gray
        activePreviewKey = "horizontalGain"
        updateControlValues()
        onDotColorChange(.gray)
        publishTuningChange()
    }

    /// The menu-bar toggle can change while this window remains open. Keep
    /// that live value unless this window itself changed auto mode.
    private func syncAutoModeWithOwnerIfUnchanged() {
        let liveTuning = currentTuning()
        guard tuning.autoEnableEnabled == lastShownTuning.autoEnableEnabled else {
            return
        }
        tuning.autoEnableEnabled = liveTuning.autoEnableEnabled
    }

    private func publishTuningChange() {
        onChange(tuning)
        lastShownTuning = tuning
    }

    private func focusPreview(for key: String) {
        activePreviewKey = key
        if let spec = settingSpec(for: key) {
            previewLabel?.stringValue = "\(spec.title): \(formattedValue(spec: spec, value: value(for: key)))"
        }
        updatePreviewMotion()
    }

    private func updatePreviewMotion() {
        preview?.motionOffset = previewMotionOffset()
    }

    private func previewMotionOffset() -> CGSize {
        guard let spec = settingSpec(for: activePreviewKey) else {
            return .zero
        }
        let cueValue = previewCueValue(for: spec)
        let previewSeconds = 0.35
        switch spec.previewScenario {
        case .horizontal:
            let velocity = OverlayController.dotVelocity(
                for: VehicleMotionCue(screenX: cueValue, screenY: 0.0, motion: .turningLeft, hasSamples: true),
                tuning: tuning
            )
            return CGSize(width: velocity.width * previewSeconds, height: velocity.height * previewSeconds)
        case .vertical:
            let velocity = OverlayController.dotVelocity(
                for: VehicleMotionCue(screenX: 0.0, screenY: -cueValue, motion: .acceleratingForward, hasSamples: true),
                tuning: tuning
            )
            return CGSize(width: velocity.width * previewSeconds, height: velocity.height * previewSeconds)
        case .still:
            return .zero
        }
    }

    @objc private func toggleStatisticsEnabled(_ sender: NSButton) {
        statisticsStore.isEnabled = sender.state == .on
    }

    @objc private func resetStatistics() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all statistics?"
        alert.informativeText = "This permanently removes the locally stored trip history."
        alert.addButton(withTitle: "Reset Statistics")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        statisticsStore.resetStatistics()
    }

    @objc private func reportFalsePositive(_ sender: NSButton) {
        guard let tripID = sender.identifier?.rawValue else {
            return
        }
        guard let url = statisticsStore.falsePositiveMailURL(for: tripID, comment: commentField.stringValue) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func value(for key: String) -> Double {
        switch key {
        case "smoothingAlpha": tuning.smoothingAlpha
        case "horizontalGain": tuning.horizontalGain
        case "verticalGain": tuning.verticalGain
        case "motionSpeedScale": tuning.motionSpeedScale
        case "horizontalDeadband": tuning.horizontalDeadband
        case "verticalDeadband": tuning.verticalDeadband
        case "horizontalMaxOffset": tuning.horizontalMaxOffset
        case "verticalMaxOffset": tuning.verticalMaxOffset
        case "motionActivationThresholdMetersPerSecondSquared": tuning.motionActivationThresholdMetersPerSecondSquared
        case "dotAlphaScale": tuning.dotAlphaScale
        case "dotSizeScale": tuning.dotSizeScale
        case "autoEnableThreshold": tuning.autoEnableThreshold
        case "autoEnableWindowSeconds": tuning.autoEnableWindowSeconds
        case "autoDisableQuietSeconds": tuning.autoDisableQuietSeconds
        default: 0.0
        }
    }

    private func setValue(_ value: Double, for key: String) {
        switch key {
        case "smoothingAlpha": tuning.smoothingAlpha = value
        case "horizontalGain": tuning.horizontalGain = value
        case "verticalGain": tuning.verticalGain = value
        case "motionSpeedScale": tuning.motionSpeedScale = value
        case "horizontalDeadband": tuning.horizontalDeadband = value
        case "verticalDeadband": tuning.verticalDeadband = value
        case "horizontalMaxOffset": tuning.horizontalMaxOffset = value
        case "verticalMaxOffset": tuning.verticalMaxOffset = value
        case "motionActivationThresholdMetersPerSecondSquared": tuning.motionActivationThresholdMetersPerSecondSquared = value
        case "dotAlphaScale": tuning.dotAlphaScale = value
        case "dotSizeScale": tuning.dotSizeScale = value
        case "autoEnableThreshold": tuning.autoEnableThreshold = value
        case "autoEnableWindowSeconds": tuning.autoEnableWindowSeconds = value
        case "autoDisableQuietSeconds": tuning.autoDisableQuietSeconds = value
        default: break
        }
    }

    private func previewCueValue(for spec: SettingSpec) -> Double {
        let normalized = spec.max > spec.min ? (value(for: spec.key) - spec.min) / (spec.max - spec.min) : 0.5
        switch spec.key {
        case "smoothingAlpha":
            return max(0.04, min(0.28, 0.18 * value(for: spec.key) / nomasMotionDefaultSmoothingAlpha))
        case "motionActivationThresholdMetersPerSecondSquared":
            return max(0.06, 0.24 - normalized * 0.16)
        case "autoEnableThreshold":
            return max(0.04, 0.22 - normalized * 0.12)
        case "autoEnableWindowSeconds":
            return 0.10 + (1.0 - normalized) * 0.10
        case "autoDisableQuietSeconds":
            return 0.10 + normalized * 0.10
        case "dotAlphaScale", "dotSizeScale":
            return 0.0
        default:
            return 0.18
        }
    }

    private var visualSettingSpecs: [SettingSpec] {
        [
            SettingSpec(key: "dotAlphaScale", title: "Dot visibility", detail: "Overall opacity.", min: 0.2, max: 1.4, decimals: 2, previewScenario: .still),
            SettingSpec(key: "dotSizeScale", title: "Dot size", detail: "Overall dot scale.", min: 0.5, max: 1.6, decimals: 2, previewScenario: .still),
            SettingSpec(key: "motionSpeedScale", title: "Speed multiplier", detail: "Scales how quickly the cues move.", min: 0.3, max: 3.0, decimals: 2, previewScenario: .horizontal),
            SettingSpec(key: "horizontalGain", title: "Horizontal motion", detail: "Sideways point speed per cue unit.", min: 0.0, max: 2_400.0, decimals: 0, previewScenario: .horizontal),
            SettingSpec(key: "verticalGain", title: "Forward/brake motion", detail: "Vertical point speed per cue unit.", min: 0.0, max: 2_400.0, decimals: 0, previewScenario: .vertical),
            SettingSpec(key: "horizontalMaxOffset", title: "Horizontal speed cap", detail: "Maximum sideways point speed.", min: 0.0, max: 1_920.0, decimals: 0, previewScenario: .horizontal),
            SettingSpec(key: "verticalMaxOffset", title: "Vertical speed cap", detail: "Maximum up/down point speed.", min: 0.0, max: 1_920.0, decimals: 0, previewScenario: .vertical)
        ]
    }

    private var behaviorSettingSpecs: [SettingSpec] {
        [
            SettingSpec(key: "horizontalDeadband", title: "Horizontal jitter filter", detail: "Ignore small side-to-side noise.", min: 0.0, max: 0.06, decimals: 3, previewScenario: .horizontal),
            SettingSpec(key: "verticalDeadband", title: "Vertical jitter filter", detail: "Ignore small accel/brake noise.", min: 0.0, max: 0.06, decimals: 3, previewScenario: .vertical),
            SettingSpec(key: "smoothingAlpha", title: "Response speed", detail: "Lower is calmer; higher reacts faster.", min: 0.02, max: 0.30, decimals: 3, previewScenario: .horizontal),
            SettingSpec(key: "motionActivationThresholdMetersPerSecondSquared", title: "Activation threshold", detail: "Minimum acceleration that moves the cues.", min: nomasMotionMinimumActivationThresholdMetersPerSecondSquared, max: 1.50, decimals: 3, previewScenario: .horizontal),
            SettingSpec(key: "autoEnableThreshold", title: "Auto sensitivity", detail: "Lower detects weaker motion.", min: 0.005, max: 0.12, decimals: 3, previewScenario: .horizontal),
            SettingSpec(key: "autoEnableWindowSeconds", title: "Auto show delay", detail: "Accumulated motion time before showing.", min: 2.0, max: 30.0, decimals: 0, previewScenario: .horizontal),
            SettingSpec(key: "autoDisableQuietSeconds", title: "Auto hide quiet", detail: "Quiet time before hiding.", min: 60.0, max: 600.0, decimals: 0, previewScenario: .horizontal)
        ]
    }

    private var allSettingSpecs: [SettingSpec] {
        visualSettingSpecs + behaviorSettingSpecs
    }

    private func settingSpec(for key: String) -> SettingSpec? {
        allSettingSpecs.first { $0.key == key }
    }

    private func defaultValue(for key: String) -> Double {
        let defaults = NomasMotionTuning.defaults
        return switch key {
        case "smoothingAlpha": defaults.smoothingAlpha
        case "horizontalGain": defaults.horizontalGain
        case "verticalGain": defaults.verticalGain
        case "motionSpeedScale": defaults.motionSpeedScale
        case "horizontalDeadband": defaults.horizontalDeadband
        case "verticalDeadband": defaults.verticalDeadband
        case "horizontalMaxOffset": defaults.horizontalMaxOffset
        case "verticalMaxOffset": defaults.verticalMaxOffset
        case "motionActivationThresholdMetersPerSecondSquared": defaults.motionActivationThresholdMetersPerSecondSquared
        case "dotAlphaScale": defaults.dotAlphaScale
        case "dotSizeScale": defaults.dotSizeScale
        case "autoEnableThreshold": defaults.autoEnableThreshold
        case "autoEnableWindowSeconds": defaults.autoEnableWindowSeconds
        case "autoDisableQuietSeconds": defaults.autoDisableQuietSeconds
        default: 0.0
        }
    }

    private func presetValue(_ preset: SettingPreset, spec: SettingSpec) -> Double {
        let defaultValue = defaultValue(for: spec.key)
        switch preset {
        case .min:
            return spec.min
        case .less:
            return spec.min + (defaultValue - spec.min) * 0.5
        case .defaultValue:
            return defaultValue
        case .more:
            return defaultValue + (spec.max - defaultValue) * 0.5
        case .max:
            return spec.max
        }
    }

    private func preset(for value: Double, spec: SettingSpec) -> SettingPreset? {
        let tolerance = max(0.000_001, (spec.max - spec.min) * 0.000_001)
        return SettingPreset.allCases.first { abs(value - presetValue($0, spec: spec)) <= tolerance }
    }

    private func formattedValue(spec: SettingSpec, value: Double) -> String {
        String(format: "%.\(spec.decimals)f", value)
    }
}

private final class SettingsOverlayPreviewView: NSView {
    private let overlayView = DotOverlayView()

    var tuning = NomasMotionTuning.defaults {
        didSet {
            overlayView.tuning = tuning
            needsDisplay = true
        }
    }

    var dotColorMode = DotColorMode.gray {
        didSet {
            overlayView.dotColorMode = dotColorMode
            needsDisplay = true
        }
    }

    var motionOffset = CGSize.zero {
        didSet {
            overlayView.motionOffset = motionOffset
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.tuning = tuning
        overlayView.dotColorMode = dotColorMode
        overlayView.motionOffset = motionOffset
        addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            overlayView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let panel = bounds.insetBy(dx: 8, dy: 8)
        NSColor.separatorColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
    }
}
