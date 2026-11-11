import CoreData
import Foundation

/// Reads the last days from Core Data and the settings files into a `TherapyReportInput`.
enum TherapyReportDataSource {
    static func loadInput(days: Int, now: Date = Date(), context: NSManagedObjectContext) async -> TherapyReportInput {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        // temp basals that started shortly before the period still run into it
        let pumpStart = start.addingTimeInterval(-2 * 3600)

        return await context.perform {
            var input = TherapyReportInput(start: start, end: now)

            let glucoseRequest = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
            glucoseRequest.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, now as NSDate)
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            input.glucose = ((try? context.fetch(glucoseRequest)) ?? []).compactMap { reading in
                guard let date = reading.date, reading.glucose > 0 else { return nil }
                return TherapyReportInput.Glucose(date: date, mgdl: Int(reading.glucose))
            }

            let pumpRequest = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            pumpRequest.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", pumpStart as NSDate, now as NSDate)
            pumpRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            pumpRequest.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
            for event in (try? context.fetch(pumpRequest)) ?? [] {
                guard let date = event.timestamp else { continue }
                if let bolus = event.bolus, let amount = bolus.amount, amount.decimalValue > 0, date >= start {
                    input.boluses.append(.init(
                        date: date,
                        units: amount.decimalValue,
                        isSMB: bolus.isSMB,
                        isExternal: bolus.isExternal
                    ))
                }
                if let temp = event.tempBasal, let rate = temp.rate {
                    input.tempBasals.append(.init(date: date, rate: rate.decimalValue, minutes: Int(temp.duration)))
                }
            }

            let carbRequest = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            carbRequest.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, now as NSDate)
            input.carbs = ((try? context.fetch(carbRequest)) ?? []).compactMap { entry in
                guard let date = entry.date, entry.carbs > 0 else { return nil }
                return TherapyReportInput.Carbs(date: date, grams: Decimal(entry.carbs), isEquivalent: entry.isFPU)
            }

            let loopRequest = NSFetchRequest<LoopStatRecord>(entityName: "LoopStatRecord")
            loopRequest.predicate = NSPredicate(format: "start >= %@", start as NSDate)
            input.loops = ((try? context.fetch(loopRequest)) ?? []).compactMap { record in
                guard let date = record.start else { return nil }
                return TherapyReportInput.LoopRun(date: date, succeeded: record.loopStatus == "Success")
            }

            let determinationRequest = NSFetchRequest<OrefDetermination>(entityName: "OrefDetermination")
            determinationRequest.predicate = NSPredicate(format: "deliverAt >= %@", start as NSDate)
            determinationRequest.propertiesToFetch = ["sensitivityRatio", "deliverAt"]
            let determinations = (try? context.fetch(determinationRequest)) ?? []
            input.sensitivityRatios = determinations.compactMap { $0.sensitivityRatio?.decimalValue }
            input.sensitivitySamples = determinations.compactMap { determination in
                guard let date = determination.deliverAt, let ratio = determination.sensitivityRatio?.decimalValue
                else { return nil }
                return (date: date, ratio: ratio)
            }

            let overrideRequest = NSFetchRequest<OverrideRunStored>(entityName: "OverrideRunStored")
            overrideRequest.predicate = NSPredicate(
                format: "startDate <= %@ AND (endDate == nil OR endDate >= %@)",
                now as NSDate,
                start as NSDate
            )
            input.adjustments += ((try? context.fetch(overrideRequest)) ?? []).compactMap { run in
                guard let begin = run.startDate else { return nil }
                return TherapyReportInput.Adjustment(kind: .override, name: run.name ?? "", start: begin, end: run.endDate ?? now)
            }

            let tempTargetRequest = NSFetchRequest<TempTargetRunStored>(entityName: "TempTargetRunStored")
            tempTargetRequest.predicate = NSPredicate(
                format: "startDate <= %@ AND (endDate == nil OR endDate >= %@)",
                now as NSDate,
                start as NSDate
            )
            input.adjustments += ((try? context.fetch(tempTargetRequest)) ?? []).compactMap { run in
                guard let begin = run.startDate else { return nil }
                return TherapyReportInput.Adjustment(
                    kind: .tempTarget,
                    name: run.name ?? "",
                    start: begin,
                    end: run.endDate ?? now
                )
            }

            return input
        }
    }

    /// The settings part of the report from the stored therapy settings.
    static func settings(
        storage: FileStorage,
        trioSettings: TrioSettings,
        preferences: Preferences
    ) -> TherapyReportSettings {
        func mgdl(_ value: Decimal, _ units: GlucoseUnits) -> Decimal {
            units == .mmolL ? TherapyReportBuilder.round(value / GlucoseUnits.exchangeRate, 0) : value
        }

        let pump = storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
        var result = TherapyReportSettings(
            displayUnits: trioSettings.units.rawValue,
            dosingMode: trioSettings.dosingMode.rawValue,
            insulinConcentration: trioSettings.pumpInsulinConcentration.displayName,
            diaHours: pump?.insulinActionCurve,
            maxBolus: pump?.maxBolus,
            maxBasal: pump?.maxBasal,
            preferences: preferences
        )
        result.basalRates = (storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [])
            .map { .init(start: TherapyReportBuilder.clockTime(minutes: $0.minutes), value: $0.rate) }
        if let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) {
            result.isfMgdlPerUnit = isf.sensitivities.map {
                .init(start: TherapyReportBuilder.clockTime(minutes: $0.offset), value: mgdl($0.sensitivity, isf.units))
            }
        }
        if let ratios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) {
            result.carbRatioGramsPerUnit = ratios.schedule.map {
                .init(start: TherapyReportBuilder.clockTime(minutes: $0.offset), value: $0.ratio)
            }
        }
        if let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) {
            result.targets = targets.targets.map {
                .init(
                    start: TherapyReportBuilder.clockTime(minutes: $0.offset),
                    lowMgdl: mgdl($0.low, targets.units),
                    highMgdl: mgdl($0.high, targets.units)
                )
            }
        }
        return result
    }

    /// Scheduled basal as (minutes since midnight, rate) for the basal calculation.
    static func basalProfile(storage: FileStorage) -> [(minutes: Int, rate: Decimal)] {
        (storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [])
            .map { (minutes: $0.minutes, rate: $0.rate) }
            .sorted { $0.minutes < $1.minutes }
    }
}
