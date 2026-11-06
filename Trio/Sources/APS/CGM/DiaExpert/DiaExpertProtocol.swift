import CoreBluetooth
import Foundation
import LoopKit

/// Bluetooth SIG Continuous Glucose Monitoring profile (service 0x181F) as used by the DiaExpert 2 (GX-01F).
///
/// Only the standard characteristics are used, read-only: CGM Measurement (0x2AA7) carries the glucose value the
/// sensor itself computed, in mg/dL, with the minutes since session start. No values are derived from advertising
/// data and no calibration curve of our own is applied. Anything that does not follow the standard yields no reading.
enum DiaExpertUUID {
    static let cgmService = CBUUID(string: "181F")
    static let measurement = CBUUID(string: "2AA7")
    static let feature = CBUUID(string: "2AA8")
    static let status = CBUUID(string: "2AA9")
    static let sessionStart = CBUUID(string: "2AAA")
    static let sessionRunTime = CBUUID(string: "2AAB")
    /// Record Access Control Point: asks the sensor to send stored records over 0x2AA7.
    static let recordAccess = CBUUID(string: "2A52")
    /// CGM Specific Ops Control Point: here only to read and, when it is 0, set the communication interval.
    static let specificOps = CBUUID(string: "2AAC")

    static let deviceInformation = CBUUID(string: "180A")
    static let model = CBUUID(string: "2A24")
    static let serialNumber = CBUUID(string: "2A25")
    static let firmware = CBUUID(string: "2A26")
}

// MARK: - SFLOAT

/// IEEE-11073 16-bit SFLOAT: 4-bit signed exponent, 12-bit signed mantissa.
enum DiaExpertSFloat {
    /// nil for the reserved special values (NaN, NRes, ±INFINITY, reserved).
    static func decode(_ raw: UInt16) -> Double? {
        switch raw {
        case 0x07FE, // +INFINITY
             0x07FF, // NaN
             0x0800, // NRes
             0x0801, // reserved
             0x0802: // -INFINITY
            return nil
        default:
            break
        }
        var mantissa = Int(raw & 0x0FFF)
        if mantissa >= 0x0800 { mantissa -= 0x1000 }
        var exponent = Int(raw >> 12)
        if exponent >= 0x8 { exponent -= 0x10 }
        return Double(mantissa) * pow(10, Double(exponent))
    }
}

// MARK: - CRC

/// E2E-CRC of the CGM profile. Two CCITT variants are in use: CRC-16/MCRF4XX (reflected polynomial 0x8408,
/// seed 0xFFFF; e.g. Accu-Chek SmartGuide) and CRC-16/CCITT-FALSE (polynomial 0x1021, seed 0xFFFF, not reflected;
/// what the DiaExpert 2 sends). Both are stored little-endian. A record is accepted when either matches.
enum DiaExpertCRC {
    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc
    }

    static func ccittFalse(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func matches(_ payload: [UInt8], received: UInt16) -> Bool {
        crc16(payload) == received || ccittFalse(payload) == received
    }
}

// MARK: - Features (0x2AA8)

struct DiaExpertFeatures: Equatable {
    let bits: UInt32

    /// Bit 12: every CGM characteristic value carries an E2E-CRC.
    var e2eCRCSupported: Bool { (bits & (1 << 12)) != 0 }

    /// nil when too short for the 24 feature bits and the type/location byte.
    init?(_ data: Data) {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16)
    }

    init(bits: UInt32) {
        self.bits = bits
    }
}

// MARK: - Measurement (0x2AA7)

struct DiaExpertMeasurement: Equatable {
    /// Why a record yields no reading. Kept for the diagnostics in the settings screen.
    enum Rejection: Error, Equatable {
        case tooShort
        case sizeMismatch
        case crcMismatch
        case specialValue
        case sensorFault
        case timeSyncRequired
        case outOfRange(Double)
    }

    enum Condition: Equatable {
        case belowRange
        case aboveRange
    }

    /// Minutes since the sensor session started, as counted by the sensor.
    let timeOffsetMinutes: Int
    /// mg/dL; for `condition` the clamped limit.
    let glucoseMgdl: Double
    let condition: Condition?
    /// mg/dL per minute, if the sensor sends one.
    let trendRate: Double?
    let calibrationRecommended: Bool

    /// The sensor's reporting limits, clamped values for "lower/higher than the device can process".
    static let lowestReported: Double = 39
    static let highestReported: Double = 400
    /// A plausible value outside this is treated as a decoding error, not as glucose.
    static let plausibleRange: ClosedRange<Double> = 20 ... 500

    /// Splits one notification into records (a notification may hold several, each starting with its size)
    /// and decodes each. A record that fails any check is returned as a rejection, never as a value.
    static func parse(_ data: Data, features: DiaExpertFeatures?) -> [Result<DiaExpertMeasurement, Rejection>] {
        let bytes = [UInt8](data)
        var results: [Result<DiaExpertMeasurement, Rejection>] = []
        var index = 0
        while index < bytes.count {
            let size = Int(bytes[index])
            guard size >= 6, index + size <= bytes.count else {
                results.append(.failure(size < 6 ? .tooShort : .sizeMismatch))
                break
            }
            results.append(decodeRecord(Array(bytes[index ..< index + size]), features: features))
            index += size
        }
        return results
    }

    static func decodeRecord(_ record: [UInt8], features: DiaExpertFeatures?) -> Result<DiaExpertMeasurement, Rejection> {
        guard record.count >= 6, Int(record[0]) == record.count else { return .failure(.sizeMismatch) }
        let flags = record[1]
        let hasTrend = (flags & 0x01) != 0
        let hasQuality = (flags & 0x02) != 0
        let hasWarning = (flags & 0x20) != 0
        let hasCalTemp = (flags & 0x40) != 0
        let hasStatus = (flags & 0x80) != 0
        let withoutCRC = 6 + (hasStatus ? 1 : 0) + (hasCalTemp ? 1 : 0) + (hasWarning ? 1 : 0) +
            (hasTrend ? 2 : 0) + (hasQuality ? 2 : 0)
        let crcBytes: Int
        if let features {
            crcBytes = features.e2eCRCSupported ? 2 : 0
            guard record.count == withoutCRC + crcBytes else { return .failure(.sizeMismatch) }
        } else if record.count == withoutCRC {
            // features unknown (not readable): a record of exactly the announced size has no CRC
            crcBytes = 0
        } else if record.count == withoutCRC + 2 {
            // two bytes more: only accepted when they are a valid E2E-CRC
            crcBytes = 2
        } else {
            return .failure(.sizeMismatch)
        }

        if crcBytes > 0 {
            let payload = Array(record.dropLast(2))
            let received = UInt16(record[record.count - 2]) | (UInt16(record[record.count - 1]) << 8)
            guard DiaExpertCRC.matches(payload, received: received) else { return .failure(.crcMismatch) }
        }

        func le16(_ offset: Int) -> UInt16 { UInt16(record[offset]) | (UInt16(record[offset + 1]) << 8) }

        let offset = Int(le16(4))
        var cursor = 6
        let status = hasStatus ? record[cursor] : 0
        cursor += hasStatus ? 1 : 0
        let calTemp = hasCalTemp ? record[cursor] : 0
        cursor += hasCalTemp ? 1 : 0
        let warning = hasWarning ? record[cursor] : 0
        cursor += hasWarning ? 1 : 0
        let trend = hasTrend ? DiaExpertSFloat.decode(le16(cursor)) : nil

        // Status octet: session stopped (0), sensor type incorrect (2), malfunction (3), general device fault (5)
        let faultBits: UInt8 = 0b0010_1101
        // Cal/Temp octet: time synchronization required (0); without it the offsets cannot be trusted
        let timeSyncRequired = (calTemp & 0x01) != 0
        let calibrationRecommended = (calTemp & 0b0000_1100) != 0
        // Warning octet: lower (6) / higher (7) than the device can process
        let belowDevice = (warning & 0x40) != 0
        let aboveDevice = (warning & 0x80) != 0

        if aboveDevice || belowDevice {
            // a reading beyond the sensor's limits is still a valid statement, as LO/HI
            return .success(DiaExpertMeasurement(
                timeOffsetMinutes: offset,
                glucoseMgdl: aboveDevice ? highestReported : lowestReported,
                condition: aboveDevice ? .aboveRange : .belowRange,
                trendRate: nil,
                calibrationRecommended: calibrationRecommended
            ))
        }
        guard (status & faultBits) == 0 else { return .failure(.sensorFault) }
        guard !timeSyncRequired else { return .failure(.timeSyncRequired) }
        guard let glucose = DiaExpertSFloat.decode(le16(2)) else { return .failure(.specialValue) }
        guard plausibleRange.contains(glucose) else { return .failure(.outOfRange(glucose)) }

        return .success(DiaExpertMeasurement(
            timeOffsetMinutes: offset,
            glucoseMgdl: min(max(glucose, lowestReported), highestReported),
            condition: glucose < lowestReported ? .belowRange : (glucose > highestReported ? .aboveRange : nil),
            trendRate: trend,
            calibrationRecommended: calibrationRecommended
        ))
    }

    var trend: GlucoseTrend? {
        guard let trendRate else { return nil }
        switch trendRate {
        case ...(-3): return .downDownDown
        case ...(-2): return .downDown
        case ...(-1): return .down
        case ..<1: return .flat
        case ..<2: return .up
        case ..<3: return .upUp
        default: return .upUpUp
        }
    }
}

// MARK: - Session clock

/// Turns the sensor's minute offsets into dates without trusting either clock blindly.
///
/// The session start is anchored when a live notification arrives (arrival time minus the record's offset), so
/// the dates follow the sensor's own count of minutes. A record is accepted only once per offset and only in
/// increasing order: a repeated or replayed record can never appear as a fresh reading.
struct DiaExpertSessionClock: Equatable, Codable {
    /// Sensor warm-up: readings in the first hour of a session are not used.
    static let warmupMinutes = 60
    /// A smaller offset than the last one means a new sensor only if the new session is this young.
    static let newSessionMaxOffsetMinutes = 180
    /// The anchor is re-derived when the arrival time disagrees by more than this (phone clock changed).
    static let reanchorTolerance: TimeInterval = 10 * 60
    /// Records older than this are not delivered.
    static let maximumAge: TimeInterval = 6 * 60 * 60

    private(set) var sessionStart: Date?
    private(set) var lastOffsetMinutes: Int?

    enum Decision: Equatable {
        case accept(Date)
        case duplicate
        case warmup
        case tooOld
        case inFuture
    }

    /// Decides about the records of one notification (oldest first); `arrival` is when it was received.
    /// `newSession` is true when the offsets restarted, i.e. a new sensor.
    /// - Parameter currentOffset: the sensor's own minute counter at `arrival` (from 0x2AA9), when known. It anchors
    ///   the dates, so a stored record fetched on request keeps its real, older date.
    mutating func decide(offsets: [Int], arrival: Date, currentOffset: Int? = nil) -> (decisions: [Decision], newSession: Bool) {
        guard let newest = offsets.max() else { return ([], false) }
        var newSession = false

        if let last = lastOffsetMinutes, newest < last {
            guard newest <= Self.newSessionMaxOffsetMinutes else {
                // older than what was already delivered and not a fresh sensor: a replay
                return (offsets.map { _ in .duplicate }, false)
            }
            sessionStart = nil
            lastOffsetMinutes = nil
            newSession = true
        }

        let derivedStart = arrival.addingTimeInterval(-Double(currentOffset ?? newest) * 60)
        if let start = sessionStart, abs(start.timeIntervalSince(derivedStart)) <= Self.reanchorTolerance {
            // keep the anchor: the sensor's minute count stays the reference
        } else {
            sessionStart = derivedStart
        }
        let start = sessionStart ?? derivedStart

        var decisions: [Decision] = []
        for offset in offsets {
            if let last = lastOffsetMinutes, offset <= last {
                decisions.append(.duplicate)
                continue
            }
            let date = start.addingTimeInterval(Double(offset) * 60)
            if offset < Self.warmupMinutes {
                decisions.append(.warmup)
            } else if arrival.timeIntervalSince(date) > Self.maximumAge {
                decisions.append(.tooOld)
            } else if date.timeIntervalSince(arrival) > 120 {
                // later than the sensor's own clock says it is now; not remembered as delivered
                decisions.append(.inFuture)
                continue
            } else {
                decisions.append(.accept(date))
            }
            lastOffsetMinutes = max(lastOffsetMinutes ?? offset, offset)
        }
        return (decisions, newSession)
    }

    mutating func reset() {
        sessionStart = nil
        lastOffsetMinutes = nil
    }
}

// MARK: - Advertising (display only)

/// The raw value the sensor broadcasts in its manufacturer data, as decoded by the LinXMonitor template.
///
/// NOT used for dosing and never handed to the loop: the raw value has no measurement time, and the curve that
/// turns it into mg/dL comes from two finger sticks on one day with one sensor. It is shown next to the official
/// app's values only, so the user can see over days whether the curve holds.
struct DiaExpertAdvertisedReading: Equatable, Identifiable {
    var id: Date { receivedAt }
    let receivedAt: Date
    let raw10: Int
    let trendBits: Int
    /// Bytes 2–3: the sensor's minute counter since session start, the same count as in 0x2AA7
    /// (checked 02.11.2026: minute 2322 over GATT at 08:48, 2398/2399 in the radio signal at 10:04/10:05).
    /// nil when it is not plausible (more than 21 days).
    let sensorMinute: Int?
    /// The whole manufacturer data, for the diagnostics.
    let hex: String

    /// The template's curve: mmol/L = 0.06538 × raw − 1.2615. Unverified.
    var templateMgdl: Int { Int(((0.06538 * Double(raw10) - 1.2615) * 18).rounded()) }

    /// nil for short data and for the warm-up marker 0xFFFF.
    init?(manufacturerData data: Data, receivedAt: Date) {
        let bytes = [UInt8](data)
        guard bytes.count >= 27 else { return nil }
        let raw16 = Int(bytes[7]) | (Int(bytes[8]) << 8)
        guard raw16 != 0xFFFF else { return nil }
        raw10 = raw16 & 0x3FF
        trendBits = (raw16 >> 10) & 0x3
        let minute = Int(bytes[2]) | (Int(bytes[3]) << 8)
        sensorMinute = minute <= 21 * 24 * 60 ? minute : nil
        hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        self.receivedAt = receivedAt
    }
}

// MARK: - Radio values for the loop (experimental)

/// Decides which radio raw values may go to the loop when the user switched that on.
///
/// The raw number is taken as mg/dL as it is (no curve). Accepted are values within 40–400 mg/dL whose change
/// since the previous value is at most `maxJumpPerMinute` per minute; a number that has not changed for 30
/// minutes counts as stuck; at most one value per 5 minutes goes to the loop.
struct DiaExpertRadioFilter: Equatable {
    static let defaultMaxJump = 15
    static let maxJumpRange = 5 ... 30
    static let validRange = 40 ... 400
    static let stuckAfter: TimeInterval = 30 * 60
    /// Five minutes with a little slack, so a value received a few seconds early is not skipped.
    static let minimumSpacing: TimeInterval = 5 * 60 - 10

    enum Decision: Equatable {
        case deliver
        case outOfRange
        case jump(Int)
        case stuck
        case tooSoon
    }

    private(set) var previous: (value: Int, at: Date)?
    private(set) var lastChange: Date?
    private(set) var lastDelivered: Date?

    static func == (lhs: DiaExpertRadioFilter, rhs: DiaExpertRadioFilter) -> Bool {
        lhs.previous?.value == rhs.previous?.value && lhs.previous?.at == rhs.previous?.at &&
            lhs.lastChange == rhs.lastChange && lhs.lastDelivered == rhs.lastDelivered
    }

    mutating func decide(value: Int, at date: Date, maxJumpPerMinute: Int) -> Decision {
        guard Self.validRange.contains(value) else { return .outOfRange }
        defer { previous = (value, date) }

        if let previous {
            if previous.value != value { lastChange = date }
            // a change within less than a minute counts as one minute
            let minutes = max(date.timeIntervalSince(previous.at) / 60, 1)
            let rate = Int((Double(abs(value - previous.value)) / minutes).rounded(.up))
            if rate > maxJumpPerMinute { return .jump(rate) }
        } else {
            lastChange = date
        }
        if let lastChange, date.timeIntervalSince(lastChange) >= Self.stuckAfter { return .stuck }
        if let lastDelivered, date.timeIntervalSince(lastDelivered) < Self.minimumSpacing { return .tooSoon }
        lastDelivered = date
        return .deliver
    }
}
