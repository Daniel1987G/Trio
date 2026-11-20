import CoreData
import Foundation

/// Reads the last time a meal with the same note was eaten from Core Data, for `MealRecall`.
enum MealRecallDataSource {
    static func recall(
        note: String,
        now: Date = Date(),
        lowMgdl: Decimal,
        isfMgdl: Decimal,
        increment: Decimal,
        context: NSManagedObjectContext
    ) async -> MealRecall.Recall? {
        guard MealRecall.normalized(note).count >= MealRecall.minimumNoteLength else { return nil }

        return await context.perform {
            let candidates = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            candidates.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND note != nil AND note != '' AND isFPU == NO",
                now.addingTimeInterval(-MealRecall.lookback) as NSDate,
                now.addingTimeInterval(-MealRecall.minimumAge) as NSDate
            )
            let meals = ((try? context.fetch(candidates)) ?? []).compactMap(Self.meal)
            guard let match = MealRecall.lastMatch(note: note, in: meals, now: now) else { return nil }

            let windowEnd = match.date.addingTimeInterval(MealRecall.window)

            let pumpRequest = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            pumpRequest.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                match.date.addingTimeInterval(-30 * 60) as NSDate,
                match.date.addingTimeInterval(60 * 60) as NSDate
            )
            pumpRequest.relationshipKeyPathsForPrefetching = ["bolus"]
            let boluses: [MealRecall.Bolus] = ((try? context.fetch(pumpRequest)) ?? []).compactMap { event in
                guard let date = event.timestamp, let bolus = event.bolus, !bolus.isSMB,
                      let amount = bolus.amount?.decimalValue, amount > 0
                else { return nil }
                return MealRecall.Bolus(date: date, units: amount)
            }

            let glucoseRequest = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
            glucoseRequest.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                match.date.addingTimeInterval(-15 * 60) as NSDate,
                windowEnd as NSDate
            )
            let readings: [MealRecall.Reading] = ((try? context.fetch(glucoseRequest)) ?? []).compactMap { reading in
                guard let date = reading.date, reading.glucose > 0 else { return nil }
                return MealRecall.Reading(date: date, mgdl: Decimal(Int(reading.glucose)))
            }

            let laterRequest = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            laterRequest.predicate = NSPredicate(
                format: "date > %@ AND date <= %@ AND isFPU == NO",
                match.date as NSDate,
                windowEnd as NSDate
            )
            let otherMeals = ((try? context.fetch(laterRequest)) ?? []).compactMap(Self.meal)

            return MealRecall.recall(
                meal: match,
                boluses: boluses,
                readings: readings,
                otherMeals: otherMeals,
                lowMgdl: lowMgdl,
                isf: isfMgdl,
                increment: increment
            )
        }
    }

    private static func meal(_ entry: CarbEntryStored) -> MealRecall.Meal? {
        guard let date = entry.date, entry.carbs > 0 else { return nil }
        return MealRecall.Meal(date: date, carbs: Decimal(entry.carbs), note: entry.note ?? "")
    }

    /// The scheduled ISF at `date` in mg/dL per U.
    static func isfMgdl(storage: FileStorage, at date: Date = Date(), calendar: Calendar = .current) -> Decimal {
        guard let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) else { return 0 }
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let entry = isf.sensitivities.sorted { $0.offset < $1.offset }.last { $0.offset <= minutes } ??
            isf.sensitivities.first
        guard let value = entry?.sensitivity else { return 0 }
        return isf.units == .mmolL ? value * 18 : value
    }
}
