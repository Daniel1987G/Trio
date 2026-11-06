import CoreBluetooth
import Foundation
import HealthKit
import LoopKit

/// CGM driver for the DiaExpert 2 sensor (GX-01F) over the standard Bluetooth CGM profile.
///
/// Safety design:
/// - Glucose comes only from CGM Measurement (0x2AA7), the value the sensor computed; nothing is derived from
///   advertising data, and no calibration curve of our own is applied.
/// - Dates come from the sensor's minute offsets (`DiaExpertSessionClock`); repeated or replayed records are dropped.
/// - Release gate (`requiresReleaseForLoop`): when on, readings reach the loop only after the user compared
///   them with the official app and released them; every new sensor session withdraws the release.
///   Switched off for now at the user's request: readings go to the loop as soon as they pass the checks.
/// - Read-only: nothing is ever written to the sensor.
final class DiaExpertCGMManager: NSObject, CGMManager {
    static let pluginIdentifier = "DiaExpert2"
    static let localizedTitle = "DiaExpert 2 (Beta)"
    /// Temporarily off: readings are handed to the loop without the user's release. Set back to `true`
    /// to require the comparison with the official app again.
    static let requiresReleaseForLoop = false
    var localizedTitle: String { Self.localizedTitle }

    /// Only a lasting connection wakes the app; while listening to the radio signal the pump's heartbeat
    /// has to keep the app running, so the manager must not claim one.
    var providesBLEHeartbeat: Bool { !state.listenOnly }
    let shouldSyncToRemoteService = true
    let managedDataInterval: TimeInterval? = .hours(3)
    /// Radio values go to the loop at most every 5 minutes; the pump heartbeat follows this.
    var expectedGlucoseSampleInterval: TimeInterval { .minutes(Double(state.loopIntervalMinutes)) }
    /// Date of the last standard reading handed to the loop, for `loopIntervalMinutes`.
    private var lastLoopReadingDate: Date?

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()
    /// Bluetooth callbacks and every change of `state` run here.
    let queue = DispatchQueue(label: "org.opentrio.DiaExpertCGMManager", qos: .userInitiated)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var features: DiaExpertFeatures?
    private var measurementCharacteristic: CBCharacteristic?
    private var recordAccessCharacteristic: CBCharacteristic?
    private var specificOpsCharacteristic: CBCharacteristic?
    private var intervalSetRequested = false
    /// Last accepted standard reading; while they arrive, polling and radio values for the loop pause.
    private var lastStandardReadingAt: Date?
    private var statusCharacteristic: CBCharacteristic?
    /// The sensor's minute counter (0x2AA9) and when it was read; anchors the dates of fetched records.
    private var lastStatus: (offset: Int, readAt: Date)?
    private var pollTimer: DispatchSourceTimer?
    /// The sensor does not push readings; the newest stored record is requested this often.
    private static let pollInterval: TimeInterval = 60
    /// Retries per connection of the protected steps; iOS starts pairing on each protected access.
    private var featureAttempts = 0
    private var subscribeAttempts = 0
    private static let maximumAttempts = 4
    private static let retryDelay: TimeInterval = 3

    private let lock = NSLock()
    private var _state: DiaExpertCGMState
    private(set) var state: DiaExpertCGMState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    private var _connectionState: ConnectionState = .idle
    private(set) var connectionState: ConnectionState {
        get { lock.withLock { _connectionState } }
        set {
            let changed = lock.withLock {
                defer { _connectionState = newValue }
                return _connectionState != newValue
            }
            if changed { publishChange() }
        }
    }

    enum ConnectionState: Equatable {
        case idle
        case bluetoothOff
        case searching
        case connecting
        case connected
        case receiving
    }

    /// Called on the main queue after every change, for the settings screen.
    var onChange: (() -> Void)?

    /// Connection steps for the diagnostics in the settings screen, newest last (not persisted).
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }

    /// Raw values from the sensor's advertising, newest last, for comparison only (never sent to the loop).
    private var _advertised: [DiaExpertAdvertisedReading] = []
    var advertisedReadings: [DiaExpertAdvertisedReading] { lock.withLock { _advertised } }

    private var radioFilter = DiaExpertRadioFilter()
    /// Dates the radio values by the sensor's minute counter and drops repeated minutes.
    private var radioClock = DiaExpertSessionClock()
    private var _lastRadioToLoop: (value: Int, at: Date)?
    var lastRadioToLoop: (value: Int, at: Date)? { lock.withLock { _lastRadioToLoop } }
    private var _lastRadioRejection: String?
    var lastRadioRejection: String? { lock.withLock { _lastRadioRejection } }

    private func recordAdvertisement(_ data: Data?) {
        guard let data, let reading = DiaExpertAdvertisedReading(manufacturerData: data, receivedAt: Date()) else { return }
        considerForLoop(reading)
        let added: Bool = lock.withLock {
            // one entry per minute, or when the raw value changes
            if let last = _advertised.last,
               last.raw10 == reading.raw10,
               reading.receivedAt.timeIntervalSince(last.receivedAt) < 55
            {
                return false
            }
            _advertised.append(reading)
            if _advertised.count > 36 { _advertised.removeFirst(_advertised.count - 36) }
            return true
        }
        if added { publishChange() }
    }

    /// Experimental: the radio raw number as mg/dL to the loop, through `DiaExpertRadioFilter`.
    private func considerForLoop(_ reading: DiaExpertAdvertisedReading) {
        let settings = state
        guard settings.radioToLoop else { return }
        // the standard readings come in: the radio values are not needed
        if let last = lastStandardReadingAt, reading.receivedAt.timeIntervalSince(last) < 10 * 60 { return }
        // the measurement time from the sensor's minute counter; without one the value is not used
        guard let minute = reading.sensorMinute else {
            noteRadioRejection("no sensor minute", value: reading.raw10)
            return
        }
        let (decisions, _) = radioClock.decide(offsets: [minute], arrival: reading.receivedAt)
        let measuredAt: Date
        switch decisions.first {
        case let .accept(date): measuredAt = date
        case .duplicate,
             .none: return // the same minute again
        case let .some(other):
            noteRadioRejection("minute \(minute): \(other)", value: reading.raw10)
            return
        }
        let decision = radioFilter.decide(
            value: reading.raw10,
            at: measuredAt,
            maxJumpPerMinute: settings.radioMaxJumpPerMinute
        )
        switch decision {
        case .tooSoon:
            return
        case .deliver:
            break
        default:
            noteRadioRejection("\(decision)", value: reading.raw10)
            return
        }

        let sample = NewGlucoseSample(
            date: measuredAt,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(reading.raw10)),
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "DiaExpertRadio-\(settings.peripheralIdentifier?.uuidString ?? "")-" +
                "\(Int(radioClock.sessionStart?.timeIntervalSince1970 ?? 0))-\(minute)",
            device: device
        )
        lock.withLock {
            _lastRadioToLoop = (reading.raw10, measuredAt)
            _lastRadioRejection = nil
        }
        log("radio value \(reading.raw10) mg/dL sent to the loop")
        delegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.cgmManager(self, hasNew: .newData([sample]))
        }
    }

    private func noteRadioRejection(_ reason: String, value: Int) {
        let changed = lock.withLock {
            defer { _lastRadioRejection = reason }
            return _lastRadioRejection != reason
        }
        if changed { log("radio value \(value) not sent to the loop: \(reason)") }
        publishChange()
    }

    /// Switches the experimental radio values for the loop on or off.
    func setRadioToLoop(_ on: Bool) {
        queue.async {
            var updated = self.state
            updated.radioToLoop = on
            self.state = updated
            self.radioFilter = DiaExpertRadioFilter()
            self.radioClock = DiaExpertSessionClock()
            self.lock.withLock { self._lastRadioRejection = nil }
            self.log(on ? "radio values go to the loop (experimental)" : "radio values no longer go to the loop")
            self.persist()
        }
    }

    func setRadioMaxJump(_ value: Int) {
        queue.async {
            var updated = self.state
            updated.radioMaxJumpPerMinute = min(
                max(value, DiaExpertRadioFilter.maxJumpRange.lowerBound),
                DiaExpertRadioFilter.maxJumpRange.upperBound
            )
            self.state = updated
            self.persist()
        }
    }

    /// Scans for the sensor's advertising; also finds it when iOS does not know it yet.
    private func startScan() {
        guard let central, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: [DiaExpertUUID.cgmService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startScanRefresh()
    }

    /// In the background iOS ignores "allow duplicates" and reports a device once per scan; restarting the
    /// scan lets it report the next radio signal. Done every minute while the app runs and on every wake-up.
    private func restartScan() {
        guard let central, central.state == .poweredOn else { return }
        if central.isScanning { central.stopScan() }
        central.scanForPeripherals(
            withServices: [DiaExpertUUID.cgmService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private var scanRefreshTimer: DispatchSourceTimer?

    private func startScanRefresh() {
        guard scanRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.restartScan() }
        scanRefreshTimer = timer
        timer.resume()
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func log(_ message: String) {
        debug(.deviceManager, "DiaExpert: \(message)")
        let line = "\(Self.eventTimeFormatter.string(from: Date())) \(message)"
        lock.withLock {
            _events.append(line)
            if _events.count > 40 { _events.removeFirst(_events.count - 40) }
        }
        publishChange()
    }

    // MARK: - Lifecycle

    init?(rawState: RawStateValue) {
        guard let restored = DiaExpertCGMState(rawValue: rawState) else { return nil }
        _state = restored
        features = restored.featureBits.map(DiaExpertFeatures.init(bits:))
        super.init()
        if restored.peripheralIdentifier != nil { start() }
    }

    /// A new, not yet paired manager (setup screen).
    override init() {
        _state = DiaExpertCGMState()
        super.init()
    }

    var rawState: RawStateValue { state.rawValue }
    var isOnboarded: Bool { state.peripheralIdentifier != nil }
    override var debugDescription: String {
        "DiaExpertCGMManager(peripheral: \(state.peripheralIdentifier?.uuidString ?? "-"), released: \(state.releasedForLoop), " +
            "session: \(state.sessionStart?.description ?? "-"), lastOffset: \(state.clock.lastOffsetMinutes ?? -1))"
    }

    func initializationComplete(for _: [Pluggable]) {}

    /// Sensor start for Trio's sensor age (status counter, else the measurement clock).
    var sensorStartDate: Date? { state.sensorStart ?? state.sessionStart }
    /// Sensor end for Trio's countdown and warnings.
    var sensorExpiresAt: Date? { state.sensorExpiresAt }
    /// End of the warm-up hour, while it lasts.
    var sensorWarmupEndsAt: Date? {
        guard let start = sensorStartDate else { return nil }
        let end = start.addingTimeInterval(Double(DiaExpertSessionClock.warmupMinutes) * 60)
        return end > Date() ? end : nil
    }

    // MARK: - CGMManager

    var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    var glucoseDisplay: GlucoseDisplayable? { nil }

    var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: state.peripheralIdentifier != nil && (state.sessionStart != nil || state.radioToLoop),
            lastCommunicationDate: [state.lastReading?.date, lastRadioToLoop?.at].compactMap { $0 }.max(),
            device: device
        )
    }

    var device: HKDevice {
        HKDevice(
            name: state.deviceName ?? "DiaExpert 2",
            manufacturer: "DiaExpert",
            model: state.model,
            hardwareVersion: nil,
            firmwareVersion: state.firmware,
            softwareVersion: nil,
            localIdentifier: state.serialNumber,
            udiDeviceIdentifier: nil
        )
    }

    func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // a wake-up (e.g. the pump heartbeat): look for the next radio signal, make sure the connection is up
        queue.async {
            self.restartScan()
            self.connectIfNeeded()
        }
        completion(.noData)
    }

    func delete(completion: @escaping () -> Void) {
        queue.async {
            self.stopPolling()
            self.scanRefreshTimer?.cancel()
            self.scanRefreshTimer = nil
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.central?.stopScan()
            self.peripheral = nil
            self.central = nil
            self.notifyDelegateOfDeletion(completion: completion)
        }
    }

    func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }

    // MARK: - Pairing and release

    /// Binds the manager to the sensor chosen in the setup screen and connects.
    func pair(with identifier: UUID, name: String?) {
        var updated = state
        updated.peripheralIdentifier = identifier
        updated.deviceName = name
        updated.clock.reset()
        updated.releasedForLoop = false
        updated.releasedAt = nil
        updated.recentReadings = []
        state = updated
        persist()
        start()
    }

    /// The user confirmed that the readings match the official app.
    func setReleasedForLoop(_ released: Bool) {
        queue.async {
            var updated = self.state
            updated.releasedForLoop = released
            updated.releasedAt = released ? Date() : nil
            self.state = updated
            self.persist()
        }
    }

    /// How often a standard reading goes to the loop: every minute or every 5 minutes.
    func setLoopInterval(_ minutes: Int) {
        guard DiaExpertCGMState.loopIntervalOptions.contains(minutes) else { return }
        queue.async {
            var updated = self.state
            updated.loopIntervalMinutes = minutes
            self.state = updated
            self.log("readings to the loop every \(minutes) min")
            self.persist()
        }
    }

    /// Listen only (default) or connect for the standard readings.
    func setListenOnly(_ listenOnly: Bool) {
        queue.async {
            var updated = self.state
            updated.listenOnly = listenOnly
            self.state = updated
            self.persist()
            if listenOnly {
                self.stopPolling()
                if let peripheral = self.peripheral, peripheral.state != .disconnected {
                    self.central?.cancelPeripheralConnection(peripheral)
                }
                self.connectionState = .idle
                self.log("listening to the radio signal only, no connection")
            } else {
                self.connectIfNeeded()
            }
        }
    }

    // MARK: - Bluetooth

    private func start() {
        queue.async {
            if self.central == nil {
                // restoration lets iOS relaunch the app for the sensor's signal after it ended it in the background
                self.central = CBCentralManager(
                    delegate: self,
                    queue: self.queue,
                    options: [CBCentralManagerOptionRestoreIdentifierKey: "org.opentrio.DiaExpertCGMManager"]
                )
            } else {
                self.connectIfNeeded()
            }
        }
    }

    private func connectIfNeeded() {
        guard let central, central.state == .poweredOn, let identifier = state.peripheralIdentifier else { return }
        startScan()
        guard !state.listenOnly else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        if let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peripheral = known
            known.delegate = self
            connectionState = .connecting
            log("connecting to known sensor")
            central.connect(known, options: nil)
        } else {
            // not known to this iPhone yet: find it by its CGM service
            connectionState = .searching
            log("sensor not known to iOS, scanning for 181F")
        }
    }

    // MARK: - Readings

    func handleMeasurement(_ data: Data, arrival: Date = Date()) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let parsed = DiaExpertMeasurement.parse(data, features: features)
        var updated = state
        updated.lastPacketHex = hex

        var measurements: [DiaExpertMeasurement] = []
        for result in parsed {
            switch result {
            case let .success(measurement): measurements.append(measurement)
            case let .failure(rejection):
                updated.rejectedCount += 1
                updated.lastRejection = "\(rejection)"
                log("2AA7 record rejected: \(rejection)")
            }
        }
        measurements.sort { $0.timeOffsetMinutes < $1.timeOffsetMinutes }

        var currentOffset: Int?
        if let lastStatus, arrival.timeIntervalSince(lastStatus.readAt) < 180 {
            currentOffset = lastStatus.offset + Int(arrival.timeIntervalSince(lastStatus.readAt) / 60)
        }
        let (decisions, newSession) = updated.clock.decide(
            offsets: measurements.map(\.timeOffsetMinutes),
            arrival: arrival,
            currentOffset: currentOffset
        )
        for (measurement, decision) in zip(measurements, decisions) {
            if case .accept = decision { continue }
            log("2AA7 record (offset \(measurement.timeOffsetMinutes) min) not used: \(decision)")
        }
        if newSession {
            // a new sensor must be compared again before the loop uses it
            updated.releasedForLoop = false
            updated.releasedAt = nil
            updated.recentReadings = []
            notifyEvent(.sensorStart, date: updated.sessionStart ?? arrival)
        }

        var samples: [NewGlucoseSample] = []
        for (measurement, decision) in zip(measurements, decisions) {
            guard case let .accept(date) = decision else { continue }
            let reading = DiaExpertReading(
                date: date,
                glucoseMgdl: measurement.glucoseMgdl,
                isLimit: measurement.condition != nil,
                trendRate: measurement.trendRate
            )
            updated.append(reading)
            samples.append(NewGlucoseSample(
                date: date,
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: measurement.glucoseMgdl),
                condition: measurement.condition
                    .map { $0 == .aboveRange ? GlucoseCondition.aboveRange : GlucoseCondition.belowRange },
                trend: measurement.trend,
                trendRate: measurement.trendRate.map { HKQuantity(
                    unit: HKUnit.milligramsPerDeciliter.unitDivided(by: .minute()),
                    doubleValue: $0
                ) },
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "DiaExpert-\(updated.serialNumber ?? updated.peripheralIdentifier?.uuidString ?? "")-" +
                    "\(Int(updated.sessionStart?.timeIntervalSince1970 ?? 0))-\(measurement.timeOffsetMinutes)",
                device: device
            ))
        }
        let released = updated.releasedForLoop || !Self.requiresReleaseForLoop
        state = updated
        connectionState = .receiving
        persist()

        if !samples.isEmpty { lastStandardReadingAt = arrival }
        guard released, !samples.isEmpty else { return }
        // every reading is kept above; the loop gets one per `loopIntervalMinutes` (10 s slack)
        let spacing = Double(updated.loopIntervalMinutes) * 60 - 10
        var forLoop: [NewGlucoseSample] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            if let last = lastLoopReadingDate, sample.date.timeIntervalSince(last) < spacing { continue }
            forLoop.append(sample)
            lastLoopReadingDate = sample.date
        }
        guard !forLoop.isEmpty else { return }
        delegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.cgmManager(self, hasNew: .newData(forLoop))
        }
    }

    // MARK: - Notifications

    private func persist() {
        delegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.cgmManagerDidUpdateState(self)
        }
        publishChange()
    }

    private func publishChange() {
        DispatchQueue.main.async { self.onChange?() }
    }

    private func notifyEvent(_ type: CgmEventType, date: Date) {
        let identifier = state.serialNumber ?? state.deviceName ?? ""
        delegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.cgmManager(self, hasNew: [PersistedCgmEvent(
                date: date,
                type: type,
                deviceIdentifier: identifier,
                expectedLifetime: nil,
                warmupPeriod: .minutes(Double(DiaExpertSessionClock.warmupMinutes))
            )])
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DiaExpertCGMManager: CBCentralManagerDelegate {
    func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log("restored by iOS (\(restored.count) device(s))")
        if let match = restored.first(where: { $0.identifier == state.peripheralIdentifier }) {
            peripheral = match
            match.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn {
            connectIfNeeded()
        } else {
            connectionState = .bluetoothOff
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard peripheral.identifier == state.peripheralIdentifier else { return }
        recordAdvertisement(advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        guard !state.listenOnly else { return }
        if let current = self.peripheral, current.state == .connected || current.state == .connecting { return }
        log("sensor found")
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        featureAttempts = 0
        subscribeAttempts = 0
        measurementCharacteristic = nil
        intervalSetRequested = false
        log("connected, discovering services")
        // all services, so the log also shows vendor services
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "-")")
        connectionState = .searching
        if let error = error as? CBError, error.code == .peerRemovedPairingInformation {
            log("the sensor deleted its pairing with this iPhone; the iPhone has to be paired with it again; retrying in 30 s")
        }
        // a pause instead of retrying at once, so a refused connection is not hammered
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.state.peripheralIdentifier == peripheral.identifier, !self.state.listenOnly,
                  peripheral.state == .disconnected else { return }
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "-")")
        stopPolling()
        guard state.peripheralIdentifier == peripheral.identifier, !state.listenOnly else { return }
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension DiaExpertCGMManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ", ")
        log("services: \(found.isEmpty ? "none" : found)\(error.map { " (error: \($0.localizedDescription))" } ?? "")")
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case DiaExpertUUID.cgmService:
                // all characteristics, so the log shows the full CGM service
                peripheral.discoverCharacteristics(nil, for: service)
            case DiaExpertUUID.deviceInformation:
                peripheral.discoverCharacteristics(
                    [DiaExpertUUID.model, DiaExpertUUID.serialNumber, DiaExpertUUID.firmware],
                    for: service
                )
            default:
                // vendor services: only listed in the log, never read or written
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        let described = characteristics.map { characteristic in
            var flags: [String] = []
            if characteristic.properties.contains(.read) { flags.append("read") }
            if characteristic.properties.contains(.notify) { flags.append("notify") }
            if characteristic.properties.contains(.indicate) { flags.append("indicate") }
            if characteristic.properties.contains(.write) { flags.append("write") }
            return "\(characteristic.uuid.uuidString)[\(flags.joined(separator: "/"))]"
        }.joined(separator: " ")
        log(
            "\(service.uuid.uuidString): \(described.isEmpty ? "no characteristics" : described)" +
                (error.map { " (error: \($0.localizedDescription))" } ?? "")
        )
        switch service.uuid {
        case DiaExpertUUID.deviceInformation:
            for characteristic in characteristics where characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        case DiaExpertUUID.cgmService:
            measurementCharacteristic = characteristics.first { $0.uuid == DiaExpertUUID.measurement }
            recordAccessCharacteristic = characteristics.first { $0.uuid == DiaExpertUUID.recordAccess }
            specificOpsCharacteristic = characteristics.first { $0.uuid == DiaExpertUUID.specificOps }
            statusCharacteristic = characteristics.first { $0.uuid == DiaExpertUUID.status }
            if measurementCharacteristic == nil { log("2AA7 not found in 181F") }
            // step 1: the encrypted read of the features, which lets iOS pair (encryption) first
            if let feature = characteristics.first(where: { $0.uuid == DiaExpertUUID.feature }) {
                featureAttempts += 1
                peripheral.readValue(for: feature)
            } else {
                subscribe(peripheral)
            }
        default:
            break
        }
    }

    /// Step 2: subscribe to the measurements, which needs an authenticated link.
    private func subscribe(_ peripheral: CBPeripheral) {
        guard let measurement = measurementCharacteristic else { return }
        guard measurement.properties.contains(.notify) || measurement.properties.contains(.indicate) else {
            log("2AA7 offers neither notify nor indicate")
            return
        }
        subscribeAttempts += 1
        peripheral.setNotifyValue(true, for: measurement)
    }

    /// Insufficient authentication or encryption: the sensor wants a paired link.
    private func isSecurityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CBATTErrorDomain else { return false }
        return nsError.code == CBATTError.insufficientAuthentication.rawValue ||
            nsError.code == CBATTError.insufficientEncryption.rawValue
    }

    // MARK: - Communication interval

    /// Writes a CGM Specific Ops Control Point command, with the E2E-CRC (CCITT-FALSE, as the DiaExpert 2 uses)
    /// when the sensor's features ask for one. Only the communication interval is ever read or set.
    private func sendSpecificOps(_ command: [UInt8]) {
        guard let peripheral, peripheral.state == .connected, let ops = specificOpsCharacteristic else { return }
        var bytes = command
        if features?.e2eCRCSupported ?? true {
            let crc = DiaExpertCRC.ccittFalse(bytes)
            bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        }
        peripheral.writeValue(Data(bytes), for: ops, type: .withResponse)
    }

    /// 0x03 = communication interval response (minutes; 0 = the sensor does not send readings by itself),
    /// 0x1C = response code to a command.
    private func handleSpecificOpsResponse(_ data: Data) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        var bytes = [UInt8](data)
        if features?.e2eCRCSupported ?? false, bytes.count >= 3 {
            let received = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
            guard DiaExpertCRC.matches(Array(bytes.dropLast(2)), received: received) else {
                log("2AAC response with wrong CRC ignored: \(hex)")
                return
            }
            bytes.removeLast(2)
        }
        guard let opcode = bytes.first else { return }
        switch opcode {
        case 0x03 where bytes.count >= 2:
            let interval = Int(bytes[1])
            log("communication interval: \(interval) min")
            if interval == 0, !intervalSetRequested {
                intervalSetRequested = true
                log("setting the communication interval to 1 min, so the sensor sends its readings")
                sendSpecificOps([0x01, 0x01])
            }
        case 0x1C where bytes.count >= 3:
            log("2AAC response to 0x\(String(format: "%02X", bytes[1])): \(bytes[2] == 0x01 ? "success" : "code \(bytes[2])")")
        default:
            log("2AAC response: \(hex)")
        }
    }

    // MARK: - Requesting records

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        pollTimer = timer
        timer.resume()
        log("requesting the newest record every \(Int(Self.pollInterval)) s")
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Step 1 of a poll: the sensor's minute counter, so the record that follows gets its real date.
    private func poll() {
        guard let peripheral, peripheral.state == .connected else { return }
        // the sensor pushes its readings: no need to ask
        if let last = lastStandardReadingAt, Date().timeIntervalSince(last) < 150 { return }
        if let status = statusCharacteristic, status.properties.contains(.read) {
            peripheral.readValue(for: status)
        } else {
            requestLastRecord()
        }
    }

    /// Step 2: Record Access Control Point "report stored records" (0x01) with operator "last record" (0x06).
    /// A read request of the standard; no other control point command is ever sent.
    private func requestLastRecord() {
        guard let peripheral, peripheral.state == .connected, let racp = recordAccessCharacteristic,
              racp.isNotifying else { return }
        peripheral.writeValue(Data([0x01, 0x06]), for: racp, type: .withResponse)
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("request \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        }
    }

    private func retry(after delay: TimeInterval, _ step: @escaping (CBPeripheral) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let peripheral = self.peripheral, peripheral.state == .connected else { return }
            step(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == DiaExpertUUID.specificOps {
            if let error {
                log("subscribe 2AAC failed: \(error.localizedDescription)")
            } else if characteristic.isNotifying {
                log("subscribe 2AAC: on, asking for the communication interval")
                sendSpecificOps([0x02])
            }
            return
        }
        if characteristic.uuid == DiaExpertUUID.recordAccess {
            if let error {
                log("subscribe 2A52 failed: \(error.localizedDescription)")
            } else if characteristic.isNotifying {
                log("subscribe 2A52: on")
                startPolling()
            }
            return
        }
        if let error {
            log("subscribe \(characteristic.uuid.uuidString) failed (\(subscribeAttempts)): \(error.localizedDescription)")
            if isSecurityError(error), subscribeAttempts < Self.maximumAttempts {
                retry(after: Self.retryDelay) { self.subscribe($0) }
            } else if isSecurityError(error) {
                log("sensor refuses pairing with this app; no readings possible this way")
            }
        } else {
            log("subscribe \(characteristic.uuid.uuidString): \(characteristic.isNotifying ? "on, waiting for readings" : "off")")
            if characteristic.isNotifying, let ops = specificOpsCharacteristic, ops.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ops)
            }
            if characteristic.isNotifying, let racp = recordAccessCharacteristic {
                if racp.properties.contains(.indicate) || racp.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: racp)
                } else {
                    log("2A52 offers no indications")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("read \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            if characteristic.uuid == DiaExpertUUID.feature {
                if isSecurityError(error), featureAttempts < Self.maximumAttempts {
                    retry(after: Self.retryDelay) { peripheral in
                        self.featureAttempts += 1
                        peripheral.readValue(for: characteristic)
                    }
                } else {
                    // try the measurements anyway; their layout is checked without the features
                    subscribe(peripheral)
                }
            }
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case DiaExpertUUID.measurement:
            // without known features a record is only accepted when its size or its CRC proves the layout
            log("2AA7 received (\(data.count) bytes)")
            handleMeasurement(data)
        case DiaExpertUUID.feature:
            features = DiaExpertFeatures(data)
            log("2AA8 features: \(features.map { String(format: "0x%06X", $0.bits) } ?? "unreadable")")
            updateInfo { $0.featureBits = self.features?.bits }
            subscribe(peripheral)
            // status and run time, read-only, to see whether a sensor session is running
            for uuid in [DiaExpertUUID.status, DiaExpertUUID.sessionRunTime] {
                if let characteristic = characteristic.service?.characteristics?.first(where: { $0.uuid == uuid }),
                   characteristic.properties.contains(.read)
                {
                    peripheral.readValue(for: characteristic)
                }
            }
        case DiaExpertUUID.status:
            // time offset (minutes since session start) and status octets
            let bytes = [UInt8](data)
            let offset = bytes.count >= 2 ? Int(bytes[0]) | (Int(bytes[1]) << 8) : -1
            log("2AA9 status: offset \(offset) min, raw \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            if offset >= 0 {
                let now = Date()
                lastStatus = (offset, now)
                // sensor start; stored only when it moves by more than 2 minutes (new sensor, clock change)
                let start = now.addingTimeInterval(-Double(offset) * 60)
                if state.sensorStart.map({ abs($0.timeIntervalSince(start)) > 120 }) ?? true {
                    updateInfo { $0.sensorStart = start }
                }
                if pollTimer != nil { requestLastRecord() }
            }
        case DiaExpertUUID.specificOps:
            handleSpecificOpsResponse(data)
        case DiaExpertUUID.recordAccess:
            // response: 0x06, operator 0x00, request op code, response code (1 = success, 6 = no records)
            log("2A52 response: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        case DiaExpertUUID.sessionRunTime:
            let bytes = [UInt8](data)
            let hours = bytes.count >= 2 ? Int(bytes[0]) | (Int(bytes[1]) << 8) : -1
            log("2AAB run time: \(hours) h, raw \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            // intended wear time; plausible are 1 to 30 days
            if (24 ... 720).contains(hours), state.sessionLifetimeHours != hours {
                updateInfo { $0.sessionLifetimeHours = hours }
            }
        case DiaExpertUUID.model:
            updateInfo { $0.model = String(data: data, encoding: .utf8) }
        case DiaExpertUUID.serialNumber:
            updateInfo { $0.serialNumber = String(data: data, encoding: .utf8) }
        case DiaExpertUUID.firmware:
            updateInfo { $0.firmware = String(data: data, encoding: .utf8) }
        default:
            break
        }
    }

    private func updateInfo(_ change: (inout DiaExpertCGMState) -> Void) {
        var updated = state
        change(&updated)
        state = updated
        persist()
    }
}
