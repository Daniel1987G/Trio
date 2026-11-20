import Foundation

/// Looks back at the last time the same meal was eaten and suggests a bolus from how it went.
///
/// After GlucOS's meal announcements (King et al., UC Davis), which key the history on the meal's
/// description and adjust run to run: a meal that ended in a low gets one step less, a meal after
/// which glucose rose more than 80 mg/dL gets one step more. A step is 25 mg/dL of glucose turned
/// into insulin through the ISF, so it is worth the same on a small and a large meal.
enum MealRecall {
    struct Meal: Equatable {
        let date: Date
        let carbs: Decimal
        let note: String
    }

    struct Bolus: Equatable {
        let date: Date
        let units: Decimal
    }

    struct Reading: Equatable {
        let date: Date
        let mgdl: Decimal
    }

    enum Outcome: Equatable {
        /// Glucose went below the low threshold (after the first 30 minutes).
        case low(at: Date, mgdl: Decimal)
        /// Glucose rose more than `excursionMgdl` above where it started.
        case highRise(at: Date, rise: Decimal)
        /// Neither happened; the highest rise above the start.
        case onTarget(peakRise: Decimal)
        /// No glucose at the meal, or too little time before the next meal.
        case unknown
    }

    struct Recall: Equatable {
        let meal: Meal
        /// Bolus given for the meal (30 minutes before to 60 minutes after), U.
        let dose: Decimal
        let outcome: Outcome
        /// One adjustment step, U.
        let step: Decimal
        /// The suggestion for today, U; nil when no meal bolus was given last time.
        let suggested: Decimal?
    }

    static let excursionMgdl: Decimal = 80
    static let stepMgdl: Decimal = 25
    static let window: TimeInterval = 4 * 60 * 60
    static let leadIn: TimeInterval = 30 * 60
    /// A meal younger than this is still being judged.
    static let minimumAge: TimeInterval = 4 * 60 * 60
    static let lookback: TimeInterval = 90 * 24 * 60 * 60
    static let minimumNoteLength = 3

    /// Case, accents and spacing do not make a different meal.
    static func normalized(_ note: String) -> String {
        note.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The most recent earlier meal with the same note, old enough to have an outcome.
    static func lastMatch(note: String, in meals: [Meal], now: Date) -> Meal? {
        let key = normalized(note)
        guard key.count >= minimumNoteLength else { return nil }
        return meals
            .filter { $0.date <= now.addingTimeInterval(-minimumAge) && $0.date >= now.addingTimeInterval(-lookback) }
            .filter { normalized($0.note) == key }
            .max { $0.date < $1.date }
    }

    static func dose(for meal: Meal, boluses: [Bolus]) -> Decimal {
        boluses
            .filter { $0.date >= meal.date.addingTimeInterval(-30 * 60) && $0.date <= meal.date.addingTimeInterval(60 * 60) }
            .reduce(0) { $0 + $1.units }
    }

    /// What glucose did after the meal; another meal of 10 g or more cuts the window short.
    static func outcome(
        for meal: Meal,
        readings: [Reading],
        otherMeals: [Meal],
        lowMgdl: Decimal
    ) -> Outcome {
        let nextMeal = otherMeals
            .filter { $0.date > meal.date.addingTimeInterval(leadIn) && $0.carbs >= 10 }
            .map(\.date)
            .min()
        let end = min(meal.date.addingTimeInterval(window), nextMeal ?? .distantFuture)
        guard end.timeIntervalSince(meal.date) >= 60 * 60 else { return .unknown }

        let nearStart = readings.filter { abs($0.date.timeIntervalSince(meal.date)) <= 15 * 60 }
        guard let start = nearStart.min(by: {
            abs($0.date.timeIntervalSince(meal.date)) < abs($1.date.timeIntervalSince(meal.date))
        }) else { return .unknown }

        let after = readings
            .filter { $0.date > meal.date && $0.date <= end }
            .sorted { $0.date < $1.date }
        guard after.count >= 6 else { return .unknown }

        let low = after.first { $0.date >= meal.date.addingTimeInterval(leadIn) && $0.mgdl < lowMgdl }
        let high = after.first { $0.mgdl - start.mgdl > excursionMgdl }
        switch (low, high) {
        case let (low?, high?):
            return low.date <= high.date ?
                .low(at: low.date, mgdl: low.mgdl) :
                .highRise(at: high.date, rise: high.mgdl - start.mgdl)
        case let (low?, nil):
            return .low(at: low.date, mgdl: low.mgdl)
        case let (nil, high?):
            return .highRise(at: high.date, rise: high.mgdl - start.mgdl)
        case (nil, nil):
            let peak = after.map(\.mgdl).max() ?? start.mgdl
            return .onTarget(peakRise: max(peak - start.mgdl, 0))
        }
    }

    /// - Parameters:
    ///   - isf: mg/dL per U now
    ///   - increment: the pump's bolus increment
    static func recall(
        meal: Meal,
        boluses: [Bolus],
        readings: [Reading],
        otherMeals: [Meal],
        lowMgdl: Decimal,
        isf: Decimal,
        increment: Decimal
    ) -> Recall {
        let dose = dose(for: meal, boluses: boluses)
        let outcome = outcome(for: meal, readings: readings, otherMeals: otherMeals, lowMgdl: lowMgdl)
        let increment = increment > 0 ? increment : 0.05
        let step = max(roundTo(isf > 0 ? stepMgdl / isf : 0, increment), increment)
        let suggested: Decimal?
        if dose > 0 {
            switch outcome {
            case .low: suggested = max(roundTo(dose - step, increment), 0)
            case .highRise: suggested = roundTo(dose + step, increment)
            case .onTarget,
                 .unknown: suggested = roundTo(dose, increment)
            }
        } else {
            suggested = nil
        }
        return Recall(meal: meal, dose: dose, outcome: outcome, step: step, suggested: suggested)
    }

    static func roundTo(_ value: Decimal, _ increment: Decimal) -> Decimal {
        guard increment > 0 else { return value }
        var steps = value / increment
        var rounded = Decimal()
        NSDecimalRound(&rounded, &steps, 0, .plain)
        return rounded * increment
    }
}
