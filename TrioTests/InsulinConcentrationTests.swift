import Foundation
import HealthKit
import LoopKit
import MockKit
import Testing
@testable import Trio

@Suite("Insulin Concentration") struct InsulinConcentrationTests {
    /// Spelled out: `.internationalUnitsPerHour` exists in both Trio and LoopKit and is ambiguous here.
    private static let unitsPerHour = HKUnit.internationalUnit().unitDivided(by: .hour())

    // MARK: - Factor

    @Test("U100 is an identity in both directions") func u100Identity() {
        for value in stride(from: 0.0, through: 30.0, by: 0.05) {
            #expect(InsulinConcentration.u100.toPump(value) == value)
            #expect(InsulinConcentration.u100.fromPump(value) == value)
        }
        #expect(InsulinConcentration.u100.toPump(Decimal(string: "1.35")!) == Decimal(string: "1.35")!)
    }

    @Test("U200 halves commands and doubles reports") func u200Direction() {
        let c = InsulinConcentration.u200
        #expect(c.toPump(2.0) == 1.0)
        #expect(c.fromPump(1.0) == 2.0)
        #expect(c.toPump(Decimal(string: "0.3")!) == Decimal(string: "0.15")!)
        #expect(c.fromPump(Decimal(string: "0.05")!) == Decimal(string: "0.1")!)
        #expect(c.unitsPerPumpUnit == 2)
    }

    @Test("U200 conversion is lossless for every 0.025 step up to 35 U") func u200Lossless() {
        let c = InsulinConcentration.u200
        for n in 0 ... 1400 {
            let pump = Double(n) / 40
            #expect(c.toPump(c.fromPump(pump)) == pump)
            // the exact double the pump's own table holds, so no increment is lost to binary error
            #expect(c.toPump(Double(2 * n) / 40) == pump)
        }
    }

    // MARK: - Settings

    @Test("Missing setting decodes as U100; U200 round-trips") func settingsDecoding() throws {
        let empty = try JSONCoding.decoder.decode(TrioSettings.self, from: Data("{}".utf8))
        #expect(empty.pumpInsulinConcentration == .u100)

        var settings = TrioSettings()
        settings.pumpInsulinConcentration = .u200
        let data = try JSONCoding.encoder.encode(settings)
        let decoded = try JSONCoding.decoder.decode(TrioSettings.self, from: data)
        #expect(decoded.pumpInsulinConcentration == .u200)

        let unknown = try JSONCoding.decoder.decode(TrioSettings.self, from: Data(#"{"pumpInsulinConcentration": 300}"#.utf8))
        #expect(unknown.pumpInsulinConcentration == .u100)

        // the unrelated legacy iAPS key must not switch the pump concentration
        let legacy = try JSONCoding.decoder.decode(TrioSettings.self, from: Data(#"{"insulinConcentration": 2}"#.utf8))
        #expect(legacy.pumpInsulinConcentration == .u100)
    }

    // MARK: - Pump reports

    @Test("A bolus reported by the pump is doubled, everything else kept") func bolusDoseConversion() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseEntry(
            type: .bolus,
            startDate: start,
            endDate: start.addingTimeInterval(60),
            value: 1.5,
            unit: .units,
            deliveredUnits: 1.25,
            syncIdentifier: "abc",
            insulinType: .lyumjev,
            automatic: true,
            manuallyEntered: false,
            isMutable: true,
            wasProgrammedByPumpUI: true
        )
        let converted = dose.convertedFromPump(concentration: .u200)

        #expect(converted.programmedUnits == 3.0)
        #expect(converted.deliveredUnits == 2.5)
        #expect(converted.unit == .units)
        #expect(converted.type == .bolus)
        #expect(converted.startDate == dose.startDate)
        #expect(converted.endDate == dose.endDate)
        #expect(converted.syncIdentifier == "abc")
        #expect(converted.insulinType == .lyumjev)
        #expect(converted.automatic == true)
        #expect(converted.isMutable == true)
        #expect(converted.wasProgrammedByPumpUI == true)
    }

    @Test("A temp basal reported by the pump has its rates doubled") func tempBasalDoseConversion() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseEntry(
            type: .tempBasal,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            value: 0.55,
            unit: .unitsPerHour,
            deliveredUnits: nil,
            scheduledBasalRate: HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: 0.4)
        )
        let converted = dose.convertedFromPump(concentration: .u200)

        #expect(converted.unitsPerHour == 1.1)
        #expect(converted.deliveredUnits == nil)
        #expect(converted.scheduledBasalRate?.doubleValue(for: DoseEntry.unitsPerHour) == 0.8)
        #expect(converted.endDate == dose.endDate)
    }

    @Test("U100 leaves a dose untouched") func u100DoseUntouched() {
        let dose = DoseEntry(type: .bolus, startDate: Date(), value: 2, unit: .units, deliveredUnits: 2)
        let converted = dose.convertedFromPump(concentration: .u100)
        #expect(converted.programmedUnits == 2)
        #expect(converted.deliveredUnits == 2)
    }

    @Test("A pump event keeps its identity when converted") func pumpEventConversion() {
        let raw = Data([0x01, 0x02, 0x03])
        let dose = DoseEntry(type: .bolus, startDate: Date(), value: 0.5, unit: .units)
        let event = NewPumpEvent(date: Date(), dose: dose, raw: raw, title: "Bolus", type: .bolus)
        let converted = event.convertedFromPump(concentration: .u200)

        #expect(converted.dose?.programmedUnits == 1.0)
        #expect(converted.dose?.syncIdentifier == event.dose?.syncIdentifier)
        #expect(converted.raw == raw)
        #expect(converted.type == .bolus)
        #expect(converted.title == "Bolus")
    }

    // MARK: - Delivery limits

    @Test("Limits are halved for the pump and capped on the way back") func deliveryLimits() {
        let requested = DeliveryLimits(
            maximumBasalRate: HKQuantity(unit: Self.unitsPerHour, doubleValue: 4),
            maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: 10)
        )
        let toPump = requested.converted(by: InsulinConcentration.u200.toPump)
        #expect(toPump.maximumBasalRate?.doubleValue(for: Self.unitsPerHour) == 2)
        #expect(toPump.maximumBolus?.doubleValue(for: .internationalUnit()) == 5)

        // a Dana-style pump ignores the request and reports its fixed 10 pump U = 20 actual U
        let reported = DeliveryLimits(
            maximumBasalRate: HKQuantity(unit: Self.unitsPerHour, doubleValue: 1),
            maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: 10)
        ).converted(by: InsulinConcentration.u200.fromPump)
        let capped = reported.cappedAt(requested)
        #expect(capped.maximumBolus?.doubleValue(for: .internationalUnit()) == 10)
        #expect(capped.maximumBasalRate?.doubleValue(for: Self.unitsPerHour) == 2)
    }

    // MARK: - Pump manager boundary

    @Test("Rounding never exceeds the request and lands on doubled pump steps") func rounding() {
        let pump = MockPumpManager()
        pump.state.supportedBolusVolumes = (1 ... 250).map { Double($0) / 10 }
        pump.state.supportedBasalRates = (0 ... 700).map { Double($0) / 20 }

        // 0.1 U pump steps are 0.2 U actual steps with U200
        #expect(pump.roundToSupportedBolusVolume(actualUnits: 1.3, concentration: .u200) == 1.2)
        #expect(pump.roundToSupportedBolusVolume(actualUnits: 1.4, concentration: .u200) == 1.4)
        #expect(pump.roundToSupportedBolusVolume(actualUnits: 1.3, concentration: .u100) == 1.3)
        // 0.05 U/h pump steps are 0.1 U/h actual steps
        #expect(pump.roundToSupportedBasalRate(actualUnitsPerHour: 1.15, concentration: .u200) == 1.1)

        #expect(pump.supportedBolusVolumes(concentration: .u200).first == 0.2)
        #expect(pump.supportedBasalRates(concentration: .u200)[1] == 0.1)
    }

    @Test("The basal schedule written to the pump is in pump units") func basalScheduleSync() {
        let pump = MockPumpManager()
        let items = [
            RepeatingScheduleValue(startTime: 0, value: 1.0),
            RepeatingScheduleValue(startTime: 6 * 3600, value: 0.8)
        ]
        pump.syncBasalRateSchedule(actualItems: items, concentration: .u200) { _ in }

        let stored = pump.state.basalRateSchedule?.items.map(\.value)
        #expect(stored == [0.5, 0.4])
    }

    @Test("Basal rates between pump steps are rounded down, never to zero, and reported") func undeliverableRates() {
        let pump = MockPumpManager()
        pump.state.supportedBasalRates = (0 ... 700).map { Double($0) / 20 }

        #expect(pump.undeliverableBasalRates([0.8, 0.85, 1.0, 0.05], concentration: .u200) == [0.85, 0.05])
        #expect(pump.undeliverableBasalRates([0.85, 0.05], concentration: .u100).isEmpty)

        let items = [
            RepeatingScheduleValue(startTime: 0, value: 0.85),
            RepeatingScheduleValue(startTime: 3600, value: 0.05),
            RepeatingScheduleValue(startTime: 7200, value: 1.0)
        ]
        pump.syncBasalRateSchedule(actualItems: items, concentration: .u200) { _ in }
        #expect(pump.state.basalRateSchedule?.items.map(\.value) == [0.4, 0.05, 0.5])
    }

    @Test("A new pump is set up with deliverable rates") func setupRates() {
        #expect(PumpConfig.PumpSetupView.setupRate(forActual: 0.85, .u200) == 0.4)
        #expect(PumpConfig.PumpSetupView.setupRate(forActual: 1.0, .u200) == 0.5)
        #expect(PumpConfig.PumpSetupView.setupRate(forActual: 0.05, .u200) == 0.05)
        #expect(PumpConfig.PumpSetupView.setupRate(forActual: 0.85, .u100) == 0.85)
    }
}
