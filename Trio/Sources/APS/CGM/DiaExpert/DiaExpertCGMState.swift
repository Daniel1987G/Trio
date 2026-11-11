import Foundation

/// A reading as shown in the comparison list of the settings screen.
struct DiaExpertReading: Codable, Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    let glucoseMgdl: Double
    let isLimit: Bool
    let trendRate: Double?
}

/// Persisted state of the DiaExpert 2 driver (`CGMManager.rawState`).
struct DiaExpertCGMState: Equatable {
    var peripheralIdentifier: UUID?
    var deviceName: String?
    var serialNumber: String?
    var model: String?
    var firmware: String?

    var clock = DiaExpertSessionClock()
    /// The user compared the readings with the official app and released them for the loop.
    /// Withdrawn automatically for every new sensor session.
    var releasedForLoop = false
    /// Only listen to the radio signal, never connect. The sensor does not keep its pairing, so a lasting
    /// connection fails, and while connected it blocks the official app.
    var listenOnly = true
    /// Experimental: hand the radio raw number (as mg/dL) to the loop. Off by default.
    var radioToLoop = false
    /// Largest accepted change of the radio value per minute (mg/dL); bigger jumps are not handed to the loop.
    var radioMaxJumpPerMinute = DiaExpertRadioFilter.defaultMaxJump
    var releasedAt: Date?
    /// Minutes between readings handed to the loop (1 or 5); all readings still appear in the comparison list.
    var loopIntervalMinutes = 5
    /// Sensor start from the status (0x2AA9: now minus the sensor's minute counter).
    var sensorStart: Date?
    /// Intended wear time from 0x2AAB (hours, e.g. 360 = 15 days).
    var sessionLifetimeHours: Int?

    /// Sensor end: start plus the intended wear time.
    var sensorExpiresAt: Date? {
        guard let start = sensorStart ?? sessionStart, let hours = sessionLifetimeHours else { return nil }
        return start.addingTimeInterval(Double(hours) * 3600)
    }

    static let loopIntervalOptions = [1, 5]

    /// Newest last, at most `historyLimit`, also while not released, for the comparison.
    var recentReadings: [DiaExpertReading] = []
    var rejectedCount = 0
    var lastRejection: String?
    var lastPacketHex: String?
    var featureBits: UInt32?

    static let historyLimit = 36

    var lastReading: DiaExpertReading? { recentReadings.last }
    var sessionStart: Date? { clock.sessionStart }

    init() {}

    mutating func append(_ reading: DiaExpertReading) {
        recentReadings.append(reading)
        if recentReadings.count > Self.historyLimit {
            recentReadings.removeFirst(recentReadings.count - Self.historyLimit)
        }
    }
}

extension DiaExpertCGMState: RawRepresentable {
    typealias RawValue = [String: Any]

    private enum Key {
        static let peripheral = "peripheralIdentifier"
        static let name = "deviceName"
        static let serial = "serialNumber"
        static let model = "model"
        static let firmware = "firmware"
        static let clock = "clock"
        static let released = "releasedForLoop"
        static let listenOnly = "listenOnly"
        static let radioToLoop = "radioToLoop"
        static let radioMaxJump = "radioMaxJumpPerMinute"
        static let releasedAt = "releasedAt"
        static let loopInterval = "loopIntervalMinutes"
        static let sensorStart = "sensorStart"
        static let lifetime = "sessionLifetimeHours"
        static let readings = "recentReadings"
        static let features = "featureBits"
    }

    init?(rawValue: RawValue) {
        self.init()
        peripheralIdentifier = (rawValue[Key.peripheral] as? String).flatMap(UUID.init(uuidString:))
        deviceName = rawValue[Key.name] as? String
        serialNumber = rawValue[Key.serial] as? String
        model = rawValue[Key.model] as? String
        firmware = rawValue[Key.firmware] as? String
        releasedForLoop = rawValue[Key.released] as? Bool ?? false
        listenOnly = rawValue[Key.listenOnly] as? Bool ?? true
        radioToLoop = rawValue[Key.radioToLoop] as? Bool ?? false
        if let jump = rawValue[Key.radioMaxJump] as? Int, DiaExpertRadioFilter.maxJumpRange.contains(jump) {
            radioMaxJumpPerMinute = jump
        }
        releasedAt = rawValue[Key.releasedAt] as? Date
        if let interval = rawValue[Key.loopInterval] as? Int, Self.loopIntervalOptions.contains(interval) {
            loopIntervalMinutes = interval
        }
        featureBits = (rawValue[Key.features] as? NSNumber)?.uint32Value
        sensorStart = rawValue[Key.sensorStart] as? Date
        sessionLifetimeHours = rawValue[Key.lifetime] as? Int
        let decoder = PropertyListDecoder()
        if let data = rawValue[Key.clock] as? Data, let clock = try? decoder.decode(DiaExpertSessionClock.self, from: data) {
            self.clock = clock
        }
        if let data = rawValue[Key.readings] as? Data,
           let readings = try? decoder.decode([DiaExpertReading].self, from: data)
        {
            recentReadings = readings
        }
    }

    var rawValue: RawValue {
        var raw: RawValue = [
            Key.released: releasedForLoop,
            Key.listenOnly: listenOnly,
            Key.radioToLoop: radioToLoop,
            Key.radioMaxJump: radioMaxJumpPerMinute,
            Key.loopInterval: loopIntervalMinutes
        ]
        raw[Key.peripheral] = peripheralIdentifier?.uuidString
        raw[Key.name] = deviceName
        raw[Key.serial] = serialNumber
        raw[Key.model] = model
        raw[Key.firmware] = firmware
        raw[Key.releasedAt] = releasedAt
        raw[Key.features] = featureBits.map { NSNumber(value: $0) }
        raw[Key.sensorStart] = sensorStart
        raw[Key.lifetime] = sessionLifetimeHours
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        raw[Key.clock] = try? encoder.encode(clock)
        raw[Key.readings] = try? encoder.encode(recentReadings)
        return raw
    }
}
