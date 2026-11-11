import Foundation
import HealthKit
import LoopKit

// MARK: - Pump boundary for insulin concentration

//
// Everything Trio hands to a `PumpManager` or reads back from it must pass through one of the
// helpers below. Callers always work in actual insulin units; the helpers translate to and from
// the pump's volumetric "U100 units". With `.u100` every helper is an identity.

extension PumpManager {
    // MARK: Capabilities (pump -> actual)

    /// Deliverable basal rates in actual U/h.
    func supportedBasalRates(concentration: InsulinConcentration) -> [Double] {
        supportedBasalRates.map { concentration.fromPump($0) }
    }

    /// Deliverable bolus volumes in actual U.
    func supportedBolusVolumes(concentration: InsulinConcentration) -> [Double] {
        supportedBolusVolumes.map { concentration.fromPump($0) }
    }

    /// Rounds an actual bolus amount to the nearest amount the pump can deliver, in actual U.
    func roundToSupportedBolusVolume(actualUnits: Double, concentration: InsulinConcentration) -> Double {
        concentration.fromPump(roundToSupportedBolusVolume(units: concentration.toPump(actualUnits)))
    }

    /// Rounds an actual basal rate to the nearest rate the pump can deliver, in actual U/h.
    func roundToSupportedBasalRate(actualUnitsPerHour: Double, concentration: InsulinConcentration) -> Double {
        concentration.fromPump(roundToSupportedBasalRate(unitsPerHour: concentration.toPump(actualUnitsPerHour)))
    }

    // MARK: Commands (actual -> pump)

    func enactBolus(
        actualUnits: Double,
        activationType: BolusActivationType,
        concentration: InsulinConcentration,
        completion: @escaping (_ error: PumpManagerError?) -> Void
    ) {
        let pumpUnits = concentration.toPump(actualUnits)
        if !concentration.isStandard {
            debug(
                .deviceManager,
                "Insulin concentration \(concentration.rawValue): bolus \(actualUnits) U -> \(pumpUnits) pump U"
            )
        }
        enactBolus(units: pumpUnits, activationType: activationType, completion: completion)
    }

    func enactTempBasal(
        actualUnitsPerHour: Double,
        for duration: TimeInterval,
        concentration: InsulinConcentration,
        completion: @escaping (_ error: PumpManagerError?) -> Void
    ) {
        let pumpRate = concentration.toPump(actualUnitsPerHour)
        if !concentration.isStandard {
            debug(
                .deviceManager,
                "Insulin concentration \(concentration.rawValue): temp basal \(actualUnitsPerHour) U/h -> \(pumpRate) pump U/h"
            )
        }
        enactTempBasal(unitsPerHour: pumpRate, for: duration, completion: completion)
    }

    /// Writes a basal schedule given in actual U/h to the pump.
    ///
    /// With a concentrated insulin a rate can fall between the pump's steps (0.85 U/h is 0.425 pump U/h,
    /// the Omnipod has 0.05 steps). Such a value is never sent as is: it is rounded down to the pump's
    /// table, but a non-zero rate never becomes zero. Callers should make the rates deliverable first
    /// (see `undeliverableBasalRates`), so this is only a last line of defense.
    func syncBasalRateSchedule(
        actualItems: [RepeatingScheduleValue<Double>],
        concentration: InsulinConcentration,
        completion: @escaping (_ result: Result<BasalRateSchedule, Error>) -> Void
    ) {
        let pumpItems = actualItems.map {
            RepeatingScheduleValue(
                startTime: $0.startTime,
                value: pumpScheduleRate(forActual: $0.value, concentration: concentration)
            )
        }
        syncBasalRateSchedule(items: pumpItems, completion: completion)
    }

    private func pumpScheduleRate(forActual actual: Double, concentration: InsulinConcentration) -> Double {
        let pumpRate = concentration.toPump(actual)
        guard !concentration.isStandard else { return pumpRate }
        let rounded = roundToSupportedBasalRate(unitsPerHour: pumpRate)
        if rounded <= 0, actual > 0, let smallest = supportedBasalRates.first(where: { $0 > 0 }) {
            return smallest
        }
        return rounded
    }

    /// The scheduled rates (actual U/h) the pump cannot deliver exactly at `concentration`.
    func undeliverableBasalRates(_ actualRates: [Double], concentration: InsulinConcentration) -> [Double] {
        actualRates.filter { rate in
            abs(roundToSupportedBasalRate(actualUnitsPerHour: rate, concentration: concentration) - rate) > 1E-9
        }
    }

    /// Writes delivery limits given in actual units to the pump. The limits the pump reports back
    /// (some pumps, e.g. Dana, only report and never accept them) are returned in actual units.
    ///
    /// With a concentrated insulin a pump with fixed limits reports e.g. 10 pump U = 20 actual U. Callers
    /// store the returned limits as the user's settings, so for a non-standard concentration the result is
    /// capped at what was requested: switching to U200 must never silently raise Max Bolus / Max Basal.
    func syncDeliveryLimits(
        actualLimits: DeliveryLimits,
        concentration: InsulinConcentration,
        completion: @escaping (_ result: Result<DeliveryLimits, Error>) -> Void
    ) {
        syncDeliveryLimits(limits: actualLimits.converted(by: concentration.toPump)) { result in
            completion(result.map { reported in
                let reportedActual = reported.converted(by: concentration.fromPump)
                return concentration.isStandard ? reportedActual : reportedActual.cappedAt(actualLimits)
            })
        }
    }
}

// MARK: - Value conversions

extension DeliveryLimits {
    /// Applies `transform` to both limits, keeping their units.
    func converted(by transform: (Double) -> Double) -> DeliveryLimits {
        DeliveryLimits(
            maximumBasalRate: maximumBasalRate.map {
                HKQuantity(
                    unit: .internationalUnitsPerHour,
                    doubleValue: transform($0.doubleValue(for: .internationalUnitsPerHour))
                )
            },
            maximumBolus: maximumBolus.map {
                HKQuantity(unit: .internationalUnit(), doubleValue: transform($0.doubleValue(for: .internationalUnit())))
            }
        )
    }

    /// Each limit lowered to the corresponding limit in `cap`, where both are present.
    func cappedAt(_ cap: DeliveryLimits) -> DeliveryLimits {
        func lower(_ value: HKQuantity?, _ cap: HKQuantity?, unit: HKUnit) -> HKQuantity? {
            guard let value else { return cap }
            guard let cap else { return value }
            return HKQuantity(unit: unit, doubleValue: min(value.doubleValue(for: unit), cap.doubleValue(for: unit)))
        }
        return DeliveryLimits(
            maximumBasalRate: lower(maximumBasalRate, cap.maximumBasalRate, unit: .internationalUnitsPerHour),
            maximumBolus: lower(maximumBolus, cap.maximumBolus, unit: .internationalUnit())
        )
    }
}

extension DoseEntry {
    /// The same dose with every insulin quantity converted from pump units to actual units.
    /// Dates, type, flags and the sync identifier are kept unchanged.
    func convertedFromPump(concentration: InsulinConcentration) -> DoseEntry {
        guard !concentration.isStandard else { return self }

        let value: Double
        switch unit {
        case .units:
            value = concentration.fromPump(programmedUnits)
        case .unitsPerHour:
            value = concentration.fromPump(unitsPerHour)
        }

        let scheduledBasalRate = self.scheduledBasalRate.map {
            HKQuantity(
                unit: DoseEntry.unitsPerHour,
                doubleValue: concentration.fromPump($0.doubleValue(for: DoseEntry.unitsPerHour))
            )
        }

        return DoseEntry(
            type: type,
            startDate: startDate,
            endDate: endDate,
            value: value,
            unit: unit,
            deliveredUnits: deliveredUnits.map { concentration.fromPump($0) },
            description: description,
            syncIdentifier: syncIdentifier,
            scheduledBasalRate: scheduledBasalRate,
            insulinType: insulinType,
            automatic: automatic,
            manuallyEntered: manuallyEntered,
            isMutable: isMutable,
            wasProgrammedByPumpUI: wasProgrammedByPumpUI
        )
    }
}

extension NewPumpEvent {
    /// The same event with its dose (if any) converted from pump units to actual units.
    func convertedFromPump(concentration: InsulinConcentration) -> NewPumpEvent {
        guard !concentration.isStandard, let dose else { return self }

        // NewPumpEvent.init derives dose.syncIdentifier from `raw`, which reproduces the original value.
        return NewPumpEvent(
            date: date,
            dose: dose.convertedFromPump(concentration: concentration),
            raw: raw,
            title: title,
            type: type,
            alarmType: alarmType
        )
    }
}
