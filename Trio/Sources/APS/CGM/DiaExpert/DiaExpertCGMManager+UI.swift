import CoreBluetooth
import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI

// MARK: - CGMManagerUI

extension DiaExpertCGMManager: CGMManagerUI {
    static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .userInteractionRequired(DiaExpertUIController(
            manager: DiaExpertCGMManager(),
            isSetup: true,
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference
        ))
    }

    func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> CGMManagerViewController {
        DiaExpertUIController(
            manager: self,
            isSetup: false,
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference
        )
    }

    static var onboardingImage: UIImage? { UIImage(systemName: "sensor.tag.radiowaves.forward") }
    var smallImage: UIImage? { UIImage(systemName: "sensor.tag.radiowaves.forward") }

    var cgmStatusHighlight: DeviceStatusHighlight? {
        if Self.requiresReleaseForLoop, !state.releasedForLoop, state.peripheralIdentifier != nil {
            return DiaExpertStatusHighlight(
                localizedMessage: String(localized: "Not Released", comment: "DiaExpert: readings not yet used by the loop"),
                imageName: "hand.raised",
                state: .warning
            )
        }
        if let start = state.sessionStart,
           Date().timeIntervalSince(start) < Double(DiaExpertSessionClock.warmupMinutes) * 60
        {
            return DiaExpertStatusHighlight(
                localizedMessage: String(localized: "Sensor\nWarmup", comment: "DiaExpert: sensor warming up"),
                imageName: "clock",
                state: .normalCGM
            )
        }
        return nil
    }

    /// Like other CGMs: the bar in the last 3 days, as a warning in the last 24 hours.
    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        guard let start = sensorStartDate, let end = sensorExpiresAt, end > start else { return nil }
        let now = Date()
        guard end.addingTimeInterval(-3 * 86400) <= now else { return nil }
        let progress = min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        return DiaExpertLifecycleProgress(
            percentComplete: progress,
            progressState: end.addingTimeInterval(-86400) <= now ? .warning : .normalCGM
        )
    }

    var cgmStatusBadge: DeviceStatusBadge? { nil }
}

private struct DiaExpertLifecycleProgress: DeviceLifecycleProgress {
    var percentComplete: Double
    var progressState: DeviceLifecycleProgressState
}

private struct DiaExpertStatusHighlight: DeviceStatusHighlight {
    var localizedMessage: String
    var imageName: String
    var state: DeviceStatusHighlightState
}

// MARK: - Controller

final class DiaExpertUIController: UINavigationController, CGMManagerOnboarding, CompletionNotifying {
    var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private let manager: DiaExpertCGMManager
    private let isSetup: Bool
    private let colorPalette: LoopUIColorPalette
    private let displayGlucosePreference: DisplayGlucosePreference

    init(
        manager: DiaExpertCGMManager,
        isSetup: Bool,
        colorPalette: LoopUIColorPalette,
        displayGlucosePreference: DisplayGlucosePreference
    ) {
        self.manager = manager
        self.isSetup = isSetup
        self.colorPalette = colorPalette
        self.displayGlucosePreference = displayGlucosePreference
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        let root: UIViewController
        if isSetup {
            root = host(
                DiaExpertSetupView(onSelect: { [weak self] identifier, name in self?.finishSetup(identifier, name) }),
                title: String(localized: "DiaExpert 2", comment: "DiaExpert setup title")
            )
        } else {
            root = host(
                DiaExpertSettingsView(model: DiaExpertSettingsModel(manager: manager), onDelete: { [weak self] in
                    self?.deleteManager()
                }, onDone: { [weak self] in
                    guard let self else { return }
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                }),
                title: DiaExpertCGMManager.localizedTitle
            )
        }
        setViewControllers([root], animated: false)
    }

    private func host(_ view: some View, title: String) -> UIViewController {
        let controller = DismissibleHostingController(
            content: view.environmentObject(displayGlucosePreference),
            colorPalette: colorPalette
        )
        controller.navigationItem.title = title
        return controller
    }

    private func finishSetup(_ identifier: UUID, _ name: String?) {
        manager.pair(with: identifier, name: name)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func deleteManager() {
        manager.delete { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
        }
    }
}

// MARK: - Setup: find the sensor

/// Lists nearby devices offering the CGM service; nothing is connected or written here.
final class DiaExpertScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String?
        var rssi: Int
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var bluetoothOn = true
    private var central: CBCentralManager?

    func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func stop() {
        central?.stopScan()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOn = central.state == .poweredOn
        if bluetoothOn {
            central.scanForPeripherals(withServices: [DiaExpertUUID.cgmService], options: nil)
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = rssi.intValue
        } else {
            devices.append(Device(id: peripheral.identifier, name: name, rssi: rssi.intValue))
        }
    }
}

struct DiaExpertSetupView: View {
    let onSelect: (UUID, String?) -> Void
    @StateObject private var scanner = DiaExpertScanner()

    var body: some View {
        List {
            Section {
                if DiaExpertCGMManager.requiresReleaseForLoop {
                    Text(
                        "This driver reads the standard Bluetooth CGM data of the DiaExpert 2 sensor. It is a beta: the readings are only used by the loop after you have compared them with the official app and released them."
                    )
                    .font(.footnote)
                } else {
                    Text(
                        "This driver reads the standard Bluetooth CGM data of the DiaExpert 2 sensor. It is a beta, and its readings go to the loop right away: compare them with the official app, especially during the first hours."
                    )
                    .font(.footnote)
                }
            }
            Section(
                header: Text("Sensors Nearby"),
                footer: Text("Keep the iPhone close to the sensor. The official DiaExpert app can stay installed.")
            ) {
                if !scanner.bluetoothOn {
                    Text("Bluetooth is off.").foregroundStyle(.orange)
                } else if scanner.devices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                ForEach(scanner.devices) { device in
                    Button {
                        scanner.stop()
                        onSelect(device.id, device.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name ?? String(localized: "Unnamed Sensor", comment: "DiaExpert scan"))
                                    .foregroundStyle(Color.primary)
                                Text(device.id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }
}

// MARK: - Settings

final class DiaExpertSettingsModel: ObservableObject {
    let manager: DiaExpertCGMManager
    @Published private(set) var state: DiaExpertCGMState
    @Published private(set) var connection: DiaExpertCGMManager.ConnectionState
    @Published private(set) var events: [String] = []
    @Published private(set) var advertised: [DiaExpertAdvertisedReading] = []
    @Published var now = Date()
    private var timer: Timer?

    init(manager: DiaExpertCGMManager) {
        self.manager = manager
        state = manager.state
        connection = manager.connectionState
        events = manager.events
        advertised = manager.advertisedReadings
        manager.onChange = { [weak self, weak manager] in
            guard let self, let manager else { return }
            self.state = manager.state
            self.connection = manager.connectionState
            self.events = manager.events
            self.advertised = manager.advertisedReadings
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.now = Date() }
    }

    deinit {
        timer?.invalidate()
    }

    func setReleased(_ released: Bool) {
        manager.setReleasedForLoop(released)
    }

    func setListenOnly(_ listenOnly: Bool) {
        manager.setListenOnly(listenOnly)
    }

    func setLoopInterval(_ minutes: Int) {
        manager.setLoopInterval(minutes)
    }

    func setRadioToLoop(_ on: Bool) {
        manager.setRadioToLoop(on)
    }

    func setRadioMaxJump(_ value: Int) {
        manager.setRadioMaxJump(value)
    }

    var lastRadioToLoop: (value: Int, at: Date)? { manager.lastRadioToLoop }
    var lastRadioRejection: String? { manager.lastRadioRejection }
}

struct DiaExpertSettingsView: View {
    @ObservedObject var model: DiaExpertSettingsModel
    let onDelete: () -> Void
    let onDone: () -> Void

    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @State private var showRelease = false
    @State private var showRadioWarning = false
    @State private var readingsExpanded = true
    @State private var diagnosticsExpanded = false
    @State private var showDelete = false

    private var state: DiaExpertCGMState { model.state }

    var body: some View {
        List {
            statusSection
            releaseSection
            readingsSection
            advertisedSection
            diagnosticsSection
            Section {
                Button(String(localized: "Delete CGM", comment: "DiaExpert"), role: .destructive) { showDelete = true }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { onDone() }
            }
        }
        .confirmationDialog(
            String(localized: "Release Readings for the Loop?", comment: "DiaExpert"),
            isPresented: $showRelease,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Release", comment: "DiaExpert")) { model.setReleased(true) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                "Only release when the readings in the list have matched the official DiaExpert app over several hours, including low and high values. From then on the loop doses insulin based on these readings. A new sensor has to be released again."
            )
        }
        .confirmationDialog(
            String(localized: "Delete CGM?", comment: "DiaExpert"),
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete CGM", comment: "DiaExpert"), role: .destructive) { onDelete() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private var statusSection: some View {
        Section(header: Text("Sensor")) {
            row(String(localized: "Name", comment: "DiaExpert"), state.deviceName ?? "–")
            if let serial = state.serialNumber { row(String(localized: "Serial Number", comment: "DiaExpert"), serial) }
            row(String(localized: "Connection", comment: "DiaExpert"), connectionText)
            if let start = state.sensorStart ?? state.sessionStart {
                row(
                    String(localized: "Sensor Started", comment: "DiaExpert"),
                    start.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let end = state.sensorExpiresAt {
                row(
                    String(localized: "Sensor Ends", comment: "DiaExpert"),
                    end.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let reading = state.lastReading {
                row(String(localized: "Last Reading", comment: "DiaExpert"), glucoseText(reading) + " · " + ageText(reading.date))
            }
        }
    }

    private var releaseSection: some View {
        Section(
            header: Text("Use by the Loop"),
            footer: Text(
                "The readings come from the sensor itself (Bluetooth CGM standard, no calibration curve of OpenTrio). Readings of the first hour after a sensor start are not used."
            )
        ) {
            Picker(
                String(localized: "To the Loop", comment: "DiaExpert"),
                selection: Binding(get: { state.loopIntervalMinutes }, set: { model.setLoopInterval($0) })
            ) {
                Text("Every Minute").tag(1)
                Text("Every 5 Minutes").tag(5)
            }
            .pickerStyle(.segmented)
            Text(
                "The sensor sends every minute; all readings appear in the comparison list. Every 5 minutes means fewer loop runs and less pod communication."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if !DiaExpertCGMManager.requiresReleaseForLoop {
                Label(
                    String(
                        localized: "Release temporarily switched off: readings go to the loop right away",
                        comment: "DiaExpert"
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Text(
                    "Compare the readings with the official app anyway, especially during the first hours of every sensor."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if state.releasedForLoop {
                Label(
                    String(localized: "Released for the loop", comment: "DiaExpert"),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                if let releasedAt = state.releasedAt {
                    row(
                        String(localized: "Since", comment: "DiaExpert"),
                        releasedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                Button(String(localized: "Withdraw Release", comment: "DiaExpert"), role: .destructive) {
                    model.setReleased(false)
                }
            } else {
                Label(
                    String(localized: "Not released: the loop does not use these readings", comment: "DiaExpert"),
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(.orange)
                Button(String(localized: "Release Readings for the Loop…", comment: "DiaExpert")) { showRelease = true }
                    .disabled(state.recentReadings.count < 12)
                if state.recentReadings.count < 12 {
                    Text(
                        String(
                            localized: "Available after 12 readings (\(state.recentReadings.count) so far).",
                            comment: "DiaExpert"
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var readingsSection: some View {
        Section(footer: Text("Compare these values and times with the official DiaExpert app.")) {
            DisclosureGroup(isExpanded: $readingsExpanded) {
                if state.recentReadings.isEmpty {
                    Text("No readings yet.").foregroundStyle(.secondary)
                }
                ForEach(state.recentReadings.reversed()) { reading in
                    HStack {
                        Text(reading.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                        Spacer()
                        Text(glucoseText(reading)).monospacedDigit()
                    }
                }
            } label: {
                HStack {
                    Text("Readings for Comparison").font(.headline)
                    Spacer()
                    Text("\(state.recentReadings.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var radioToLoopRows: some View {
        Toggle(
            String(localized: "Send Radio Values to the Loop (Experimental)", comment: "DiaExpert"),
            isOn: Binding(
                get: { state.radioToLoop },
                set: { on in
                    if on { showRadioWarning = true } else { model.setRadioToLoop(false) }
                }
            )
        )
        .confirmationDialog(
            String(localized: "Send Radio Values to the Loop?", comment: "DiaExpert"),
            isPresented: $showRadioWarning,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Send to the Loop", comment: "DiaExpert"), role: .destructive) {
                model.setRadioToLoop(true)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                "That the raw number equals mg/dL rests on very few comparisons. If it is off at low or high values, the loop doses wrongly. Check the values with finger sticks, especially during the first days and below 80 mg/dL."
            )
        }
        if state.radioToLoop {
            Stepper(
                value: Binding(get: { state.radioMaxJumpPerMinute }, set: { model.setRadioMaxJump($0) }),
                in: DiaExpertRadioFilter.maxJumpRange
            ) {
                HStack {
                    Text("Largest Change per Minute")
                    Spacer()
                    Text("\(state.radioMaxJumpPerMinute) mg/dL").foregroundStyle(.secondary)
                }
            }
            Text(
                "Sent at most every 5 minutes, only 40–400 mg/dL. Bigger jumps are skipped; a value unchanged for 30 minutes is treated as stuck and not sent."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let last = model.lastRadioToLoop {
                row(
                    String(localized: "Last Sent to the Loop", comment: "DiaExpert"),
                    "\(last.at.formatted(date: .omitted, time: .shortened)) · \(last.value) mg/dL"
                )
            }
            if let reason = model.lastRadioRejection {
                row(String(localized: "Not Sent", comment: "DiaExpert"), reason)
            }
        }
    }

    private var advertisedSection: some View {
        Section(
            header: Text("Radio Raw Values (Comparison Only)"),
            footer: Text(
                "The raw number from the sensor's radio signal, shown as mg/dL; in small print the value after the template's curve. They are never used by the loop. Note pairs with the official app (time, both values), especially below 80 and above 200 mg/dL."
            )
        ) {
            Toggle(
                String(localized: "Listen to the Radio Signal Only", comment: "DiaExpert"),
                isOn: Binding(get: { state.listenOnly }, set: { model.setListenOnly($0) })
            )
            Text(
                "On: OpenTrio never connects and does not block the official app. Off: OpenTrio keeps a connection and receives the sensor's own reading every minute; the official app must stay closed, it takes over the pairing."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            radioToLoopRows
            if model.advertised.isEmpty {
                Text("No radio values received yet.").foregroundStyle(.secondary)
            }
            ForEach(model.advertised.reversed()) { reading in
                HStack {
                    Text(reading.receivedAt.formatted(date: .omitted, time: .standard)).monospacedDigit()
                    Spacer()
                    Text(
                        displayGlucosePreference.format(
                            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(reading.raw10))
                        )
                    )
                    .monospacedDigit()
                    Text("(\(reading.templateMgdl))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                row(String(localized: "Rejected Packets", comment: "DiaExpert"), "\(state.rejectedCount)")
                if let reason = state.lastRejection {
                    row(String(localized: "Last Reason", comment: "DiaExpert"), reason)
                }
                if let bits = state.featureBits {
                    row(String(localized: "Features", comment: "DiaExpert"), String(format: "0x%06X", bits))
                }
                if let hex = state.lastPacketHex {
                    Text(hex).font(.caption2.monospaced()).textSelection(.enabled)
                }
                ForEach(model.advertised.suffix(5).reversed()) { reading in
                    Text(advertisedLine(reading))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                if !model.events.isEmpty {
                    Text(model.events.reversed().joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } label: {
                Text("Diagnostics").font(.headline)
            }
            ShareLink(
                item: diagnosticsReport,
                subject: Text("DiaExpert 2 Diagnostics"),
                preview: SharePreview(Text("DiaExpert 2 Diagnostics"))
            ) {
                Label(String(localized: "Share Diagnostics", comment: "DiaExpert"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private func advertisedLine(_ reading: DiaExpertAdvertisedReading) -> String {
        reading.receivedAt.formatted(date: .omitted, time: .standard) +
            (reading.sensorMinute.map { "  min \($0)" } ?? "") + "  " + reading.hex
    }

    /// Plain text of everything the diagnostics show, plus the full lists, for sharing.
    private var diagnosticsReport: String {
        var lines: [String] = [
            "OpenTrio DiaExpert 2 diagnostics, \(model.now.formatted(date: .abbreviated, time: .standard))",
            "Sensor: \(state.deviceName ?? "-"), serial \(state.serialNumber ?? "-"), model \(state.model ?? "-"), firmware \(state.firmware ?? "-")",
            "Connection: \(connectionText), listen only: \(state.listenOnly), radio to loop: \(state.radioToLoop)",
            "Loop interval: \(state.loopIntervalMinutes) min, max radio jump: \(state.radioMaxJumpPerMinute) mg/dL/min",
            "Session start: \(state.sessionStart?.formatted(date: .abbreviated, time: .standard) ?? "-"), last offset: \(state.clock.lastOffsetMinutes.map(String.init) ?? "-") min",
            "Features: \(state.featureBits.map { String(format: "0x%06X", $0) } ?? "-")",
            "Rejected packets: \(state.rejectedCount), last reason: \(state.lastRejection ?? "-")",
            "Last 2AA7 packet: \(state.lastPacketHex ?? "-")",
            "",
            "Readings (time, mg/dL):"
        ]
        lines += state.recentReadings.map {
            "\($0.date.formatted(date: .omitted, time: .standard))  \(Int($0.glucoseMgdl.rounded()))\($0.isLimit ? " (limit)" : "")"
        }
        lines += ["", "Radio signal (time, sensor minute, raw, manufacturer data):"]
        lines += model.advertised.map {
            "\($0.receivedAt.formatted(date: .omitted, time: .standard))  min \($0.sensorMinute.map(String.init) ?? "-")  raw \($0.raw10)  \($0.hex)"
        }
        lines += ["", "Log (oldest first):"]
        lines += model.events
        return lines.joined(separator: "\n")
    }

    private var connectionText: String {
        switch model.connection {
        case .idle: return String(localized: "Not connected", comment: "DiaExpert connection")
        case .bluetoothOff: return String(localized: "Bluetooth is off", comment: "DiaExpert connection")
        case .searching: return String(localized: "Searching…", comment: "DiaExpert connection")
        case .connecting: return String(localized: "Connecting…", comment: "DiaExpert connection")
        case .connected: return String(localized: "Connected", comment: "DiaExpert connection")
        case .receiving: return String(localized: "Receiving readings", comment: "DiaExpert connection")
        }
    }

    private func glucoseText(_ reading: DiaExpertReading) -> String {
        let text = displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: reading.glucoseMgdl))
        guard reading.isLimit else { return text }
        return reading.glucoseMgdl >= DiaExpertMeasurement.highestReported ? "HI (\(text))" : "LO (\(text))"
    }

    private func ageText(_ date: Date) -> String {
        let minutes = max(0, Int(model.now.timeIntervalSince(date) / 60))
        return String(localized: "\(minutes) min ago", comment: "Age of the latest glucose reading on the watch")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
