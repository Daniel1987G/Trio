import Foundation
import Testing
@testable import Trio

@Suite("DiaExpert 2 CGM") struct DiaExpertCGMTests {
    /// A standard CGM Measurement record: size, flags, glucose SFLOAT, time offset, optional octets, optional CRC.
    private func record(
        glucose: UInt16,
        offset: UInt16,
        status: UInt8? = nil,
        calTemp: UInt8? = nil,
        warning: UInt8? = nil,
        trend: UInt16? = nil,
        withCRC: Bool = false
    ) -> [UInt8] {
        var flags: UInt8 = 0
        if trend != nil { flags |= 0x01 }
        if warning != nil { flags |= 0x20 }
        if calTemp != nil { flags |= 0x40 }
        if status != nil { flags |= 0x80 }
        var body: [UInt8] = [flags, UInt8(glucose & 0xFF), UInt8(glucose >> 8), UInt8(offset & 0xFF), UInt8(offset >> 8)]
        if let status { body.append(status) }
        if let calTemp { body.append(calTemp) }
        if let warning { body.append(warning) }
        if let trend { body += [UInt8(trend & 0xFF), UInt8(trend >> 8)] }
        var bytes = [UInt8(body.count + 1 + (withCRC ? 2 : 0))] + body
        if withCRC {
            let crc = DiaExpertCRC.crc16(bytes)
            bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        }
        return bytes
    }

    private let noCRC = DiaExpertFeatures(bits: 0)
    private let withCRC = DiaExpertFeatures(bits: 1 << 12)

    private func decode(
        _ bytes: [UInt8],
        features: DiaExpertFeatures? = nil
    ) -> Result<DiaExpertMeasurement, DiaExpertMeasurement.Rejection>? {
        DiaExpertMeasurement.parse(Data(bytes), features: features ?? noCRC).first
    }

    // MARK: - Encoding basics

    @Test("SFLOAT with exponent, negative values and special values") func sfloat() {
        #expect(DiaExpertSFloat.decode(0x0078) == 120)
        #expect(DiaExpertSFloat.decode(0xF4B0) == 120) // 1200 × 10^-1
        #expect(DiaExpertSFloat.decode(0xFFF6) == -1) // -10 × 10^-1
        #expect(DiaExpertSFloat.decode(0x07FF) == nil) // NaN
        #expect(DiaExpertSFloat.decode(0x0800) == nil) // NRes
    }

    @Test("E2E-CRC is CRC-16/MCRF4XX") func crc() {
        #expect(DiaExpertCRC.crc16(Array("123456789".utf8)) == 0x6F91)
    }

    // MARK: - Records

    @Test("Real DiaExpert 2 record (CRC-16/CCITT-FALSE)") func realRecord() throws {
        // captured 02.11.2026: 150 mg/dL, minute 2308, trend -0.2 mg/dL/min, quality 99 %
        let bytes: [UInt8] = [0x0F, 0xE3, 0x96, 0x00, 0x04, 0x09, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0x63, 0x00, 0x08, 0xB1]
        let measurement = try decode(bytes, features: withCRC)?.get()
        #expect(measurement?.glucoseMgdl == 150)
        #expect(measurement?.timeOffsetMinutes == 2308)
        #expect(measurement?.trendRate == -0.2)
        #expect(measurement?.condition == nil)
        // one changed byte breaks the CRC
        var broken = bytes
        broken[2] = 0x97
        #expect(decode(broken, features: withCRC) == .failure(.crcMismatch))
    }

    @Test("A plain record gives the sensor's value and offset") func plainRecord() throws {
        let measurement = try decode(record(glucose: 0x0078, offset: 100))?.get()
        #expect(measurement?.glucoseMgdl == 120)
        #expect(measurement?.timeOffsetMinutes == 100)
        #expect(measurement?.condition == nil)
    }

    @Test("Trend rate is read and mapped") func trend() throws {
        let measurement = try decode(record(glucose: 0x0096, offset: 90, trend: 0xF014))?.get() // 20 × 10^-1 = 2 mg/dL/min
        #expect(measurement?.trendRate == 2)
        #expect(measurement?.trend == .upUp)
    }

    @Test("Records with a wrong size are rejected") func sizeChecks() {
        var bytes = record(glucose: 0x0078, offset: 100)
        bytes[0] = 9
        #expect(decode(bytes) == .failure(.sizeMismatch))
        // flags announce a status octet that is missing
        var missing = record(glucose: 0x0078, offset: 100)
        missing[1] = 0x80
        #expect(decode(missing) == .failure(.sizeMismatch))
        #expect(decode([3, 0, 0]) == .failure(.tooShort))
    }

    @Test("With E2E-CRC the CRC must match") func crcRecords() throws {
        let good = record(glucose: 0x0078, offset: 100, withCRC: true)
        #expect(try decode(good, features: withCRC)?.get().glucoseMgdl == 120)
        var bad = good
        bad[2] ^= 0x01
        #expect(decode(bad, features: withCRC) == .failure(.crcMismatch))
        // a record without CRC does not have the size the features announce
        #expect(decode(record(glucose: 0x0078, offset: 100), features: withCRC) == .failure(.sizeMismatch))
    }

    @Test("Without readable features the size or a valid CRC decides the layout") func unknownFeatures() {
        let plain = DiaExpertMeasurement.parse(Data(record(glucose: 0x0078, offset: 100)), features: nil)
        #expect(plain.compactMap { try? $0.get().glucoseMgdl } == [120])
        let withValidCRC = DiaExpertMeasurement.parse(Data(record(glucose: 0x0078, offset: 100, withCRC: true)), features: nil)
        #expect(withValidCRC.compactMap { try? $0.get().glucoseMgdl } == [120])
        var broken = record(glucose: 0x0078, offset: 100, withCRC: true)
        broken[2] ^= 0x01
        #expect(DiaExpertMeasurement.parse(Data(broken), features: nil).first == .failure(.crcMismatch))
    }

    @Test("Sensor faults, missing time sync and special values give no reading") func rejections() {
        #expect(decode(record(glucose: 0x0078, offset: 100, status: 0x08)) == .failure(.sensorFault))
        #expect(decode(record(glucose: 0x0078, offset: 100, status: 0x01)) == .failure(.sensorFault)) // session stopped
        #expect(decode(record(glucose: 0x0078, offset: 100, calTemp: 0x01)) == .failure(.timeSyncRequired))
        #expect(decode(record(glucose: 0x07FF, offset: 100)) == .failure(.specialValue))
        #expect(decode(record(glucose: 900, offset: 100)) == .failure(.outOfRange(900)))
        #expect(decode(record(glucose: 10, offset: 100)) == .failure(.outOfRange(10)))
    }

    @Test("Beyond the sensor's limits: LO and HI") func limits() throws {
        let high = try decode(record(glucose: 0x07FF, offset: 100, warning: 0x80))?.get()
        #expect(high?.glucoseMgdl == 400)
        #expect(high?.condition == .aboveRange)
        let low = try decode(record(glucose: 0x07FF, offset: 100, warning: 0x40))?.get()
        #expect(low?.glucoseMgdl == 39)
        #expect(low?.condition == .belowRange)
        // a battery warning alone does not block the value
        #expect(try decode(record(glucose: 0x0078, offset: 100, status: 0x02))?.get().glucoseMgdl == 120)
    }

    @Test("Several records in one notification") func multipleRecords() {
        let data = Data(record(glucose: 0x0078, offset: 100) + record(glucose: 0x007D, offset: 101))
        let results = DiaExpertMeasurement.parse(data, features: noCRC)
        #expect(results.count == 2)
        #expect(results.compactMap { try? $0.get().glucoseMgdl } == [120, 125])
    }

    // MARK: - Session clock

    private let arrival = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Dates follow the sensor's minute count") func clockDates() {
        var clock = DiaExpertSessionClock()
        let first = clock.decide(offsets: [100], arrival: arrival)
        #expect(first.decisions == [.accept(arrival)])
        #expect(clock.sessionStart == arrival.addingTimeInterval(-100 * 60))
        #expect(!first.newSession)

        // delivered 40 s late: the date still comes from the offset
        let second = clock.decide(offsets: [101], arrival: arrival.addingTimeInterval(100))
        #expect(second.decisions == [.accept(arrival.addingTimeInterval(60))])
    }

    @Test("Repeated or replayed records never look fresh") func clockDuplicates() {
        var clock = DiaExpertSessionClock()
        _ = clock.decide(offsets: [500, 501], arrival: arrival)
        #expect(clock.decide(offsets: [501], arrival: arrival.addingTimeInterval(120)).decisions == [.duplicate])
        // an old record later on, not young enough for a new sensor
        let replay = clock.decide(offsets: [300], arrival: arrival.addingTimeInterval(600))
        #expect(replay.decisions == [.duplicate])
        #expect(!replay.newSession)
        #expect(clock.lastOffsetMinutes == 501)
    }

    @Test("Warm-up readings are not used") func clockWarmup() {
        var clock = DiaExpertSessionClock()
        #expect(clock.decide(offsets: [30], arrival: arrival).decisions == [.warmup])
        #expect(clock.decide(offsets: [61], arrival: arrival.addingTimeInterval(31 * 60)).decisions.first == .accept(
            arrival.addingTimeInterval(31 * 60)
        ))
    }

    @Test("Restarting offsets mean a new sensor") func clockNewSession() {
        var clock = DiaExpertSessionClock()
        _ = clock.decide(offsets: [8000], arrival: arrival)
        let fresh = clock.decide(offsets: [65], arrival: arrival.addingTimeInterval(3600))
        #expect(fresh.newSession)
        #expect(fresh.decisions == [.accept(arrival.addingTimeInterval(3600))])
        #expect(clock.sessionStart == arrival.addingTimeInterval(3600 - 65 * 60))
    }

    @Test("A fetched record keeps its real date when the sensor's counter is known") func clockCurrentOffset() {
        var clock = DiaExpertSessionClock()
        // the sensor's counter says 1206 min, the newest stored record is from minute 1200
        let decisions = clock.decide(offsets: [1200], arrival: arrival, currentOffset: 1206).decisions
        #expect(decisions == [.accept(arrival.addingTimeInterval(-6 * 60))])
        // a record "later" than the counter is refused
        var other = DiaExpertSessionClock()
        #expect(other.decide(offsets: [1215], arrival: arrival, currentOffset: 1206).decisions == [.inFuture])
    }

    @Test("Backfilled records older than 6 hours are not delivered") func clockMaximumAge() {
        var clock = DiaExpertSessionClock()
        let decisions = clock.decide(offsets: [100, 500, 1000], arrival: arrival).decisions
        #expect(decisions == [.tooOld, .tooOld, .accept(arrival)])
    }

    // MARK: - State

    @Test("State survives the round trip through rawState") func stateRoundTrip() {
        var state = DiaExpertCGMState()
        state.peripheralIdentifier = UUID()
        state.deviceName = "GX-01F 1234"
        state.releasedForLoop = true
        state.featureBits = 1 << 12
        _ = state.clock.decide(offsets: [120], arrival: arrival)
        state.append(DiaExpertReading(date: arrival, glucoseMgdl: 120, isLimit: false, trendRate: nil))
        let restored = DiaExpertCGMState(rawValue: state.rawValue)
        #expect(restored == state)
    }

    @Test("Readings are kept for comparison but the loop gets nothing before the release") func notReleased() {
        let manager = DiaExpertCGMManager()
        manager.handleMeasurement(Data(record(glucose: 0x0078, offset: 100)), arrival: arrival)
        #expect(manager.state.recentReadings.map(\.glucoseMgdl) == [120])
        #expect(!manager.state.releasedForLoop)
    }

    @Test("Radio signal carries the sensor's minute counter") func advertisingMinute() {
        // captured 02.11.2026 10:04:47, minute 2398, raw 133
        let hex = "59005E090000FF858064858064858064030 0F0408013 03F405B036".replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        let reading = DiaExpertAdvertisedReading(manufacturerData: Data(bytes), receivedAt: arrival)
        #expect(reading?.sensorMinute == 2398)
        #expect(reading?.raw10 == 133)
    }

    @Test("Radio raw values: decoded like the template, never a reading") func advertising() {
        var bytes = [UInt8](repeating: 0, count: 27)
        // raw 134 with trend bits 1
        let raw16 = 134 | (1 << 10)
        bytes[7] = UInt8(raw16 & 0xFF)
        bytes[8] = UInt8(raw16 >> 8)
        let reading = DiaExpertAdvertisedReading(manufacturerData: Data(bytes), receivedAt: arrival)
        #expect(reading?.raw10 == 134)
        #expect(reading?.trendBits == 1)
        #expect(reading?.templateMgdl == 135) // 7.5 mmol/L per the template's reference point
        bytes[7] = 0xFF
        bytes[8] = 0xFF
        #expect(DiaExpertAdvertisedReading(manufacturerData: Data(bytes), receivedAt: arrival) == nil)
        #expect(DiaExpertAdvertisedReading(manufacturerData: Data(count: 10), receivedAt: arrival) == nil)
    }

    // MARK: - Radio values for the loop

    @Test("Radio filter: range, jump limit, 5-minute spacing") func radioFilter() {
        var filter = DiaExpertRadioFilter()
        let t0 = arrival
        #expect(filter.decide(value: 30, at: t0, maxJumpPerMinute: 15) == .outOfRange)
        #expect(filter.decide(value: 150, at: t0, maxJumpPerMinute: 15) == .deliver)
        #expect(filter.decide(value: 152, at: t0.addingTimeInterval(60), maxJumpPerMinute: 15) == .tooSoon)
        // +20 within a minute is a jump at 15, fine at 25
        #expect(filter.decide(value: 172, at: t0.addingTimeInterval(120), maxJumpPerMinute: 15) == .jump(20))
        #expect(filter.decide(value: 175, at: t0.addingTimeInterval(180), maxJumpPerMinute: 15) == .tooSoon)
        #expect(filter.decide(value: 178, at: t0.addingTimeInterval(300), maxJumpPerMinute: 15) == .deliver)
        var relaxed = DiaExpertRadioFilter()
        _ = relaxed.decide(value: 150, at: t0, maxJumpPerMinute: 25)
        #expect(relaxed.decide(value: 170, at: t0.addingTimeInterval(300), maxJumpPerMinute: 25) == .deliver)
        // 30 mg/dL over 5 minutes is 6 per minute, not a jump
        var slow = DiaExpertRadioFilter()
        _ = slow.decide(value: 120, at: t0, maxJumpPerMinute: 15)
        #expect(slow.decide(value: 150, at: t0.addingTimeInterval(300), maxJumpPerMinute: 15) == .deliver)
    }

    @Test("Radio filter: a number unchanged for 30 minutes is stuck") func radioStuck() {
        var filter = DiaExpertRadioFilter()
        for minute in stride(from: 0, through: 25, by: 5) {
            #expect(
                filter.decide(value: 140, at: arrival.addingTimeInterval(Double(minute) * 60), maxJumpPerMinute: 15) ==
                    .deliver
            )
        }
        #expect(filter.decide(value: 140, at: arrival.addingTimeInterval(30 * 60), maxJumpPerMinute: 15) == .stuck)
        // a change ends it
        #expect(filter.decide(value: 142, at: arrival.addingTimeInterval(31 * 60), maxJumpPerMinute: 15) == .deliver)
        #expect(filter.decide(value: 143, at: arrival.addingTimeInterval(33 * 60), maxJumpPerMinute: 15) == .tooSoon)
    }
}
