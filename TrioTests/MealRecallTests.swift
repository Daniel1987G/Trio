import Foundation
import Testing
@testable import Trio

@Suite("Meal history: bolus from the last time") struct MealRecallTests {
    private let mealDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { mealDate.addingTimeInterval(24 * 60 * 60) }

    private func meal(_ note: String = "Spaghetti Bolognese", hoursAgo: Double? = nil, carbs: Decimal = 60) -> MealRecall.Meal {
        MealRecall.Meal(
            date: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) } ?? mealDate,
            carbs: carbs,
            note: note
        )
    }

    /// Readings every 5 minutes for 4 hours after the meal, from a curve in minutes.
    private func readings(_ curve: (Double) -> Decimal) -> [MealRecall.Reading] {
        stride(from: -10.0, through: 240, by: 5).map {
            MealRecall.Reading(date: mealDate.addingTimeInterval($0 * 60), mgdl: curve(max($0, 0)))
        }
    }

    @Test("same meal regardless of case, accents and spaces; the latest wins") func matching() {
        let meals = [
            meal("spaghetti  bolognese", hoursAgo: 48),
            meal("Spaghetti Bolognese", hoursAgo: 24),
            meal("Pizza", hoursAgo: 20),
            meal("Spaghetti Bolognese", hoursAgo: 2) // still being judged
        ]
        #expect(MealRecall.lastMatch(note: " SPAGHETTI bolognese ", in: meals, now: now) == meals[1])
        #expect(MealRecall.normalized("Crème brûlée") == MealRecall.normalized("creme brulee"))
        #expect(MealRecall.lastMatch(note: "ab", in: [meal("ab", hoursAgo: 24)], now: now) == nil)
        #expect(MealRecall.lastMatch(note: "Pizza", in: [meal("Pizza", hoursAgo: 24 * 100)], now: now) == nil)
    }

    @Test("dose: boluses from 30 minutes before to 60 minutes after") func dose() {
        let boluses = [
            MealRecall.Bolus(date: mealDate.addingTimeInterval(-40 * 60), units: 1),
            MealRecall.Bolus(date: mealDate.addingTimeInterval(-10 * 60), units: 4),
            MealRecall.Bolus(date: mealDate.addingTimeInterval(45 * 60), units: 0.5),
            MealRecall.Bolus(date: mealDate.addingTimeInterval(90 * 60), units: 2)
        ]
        #expect(MealRecall.dose(for: meal(), boluses: boluses) == 4.5)
    }

    @Test("a rise of more than 80 mg/dL asks for one step more") func highRise() {
        let recall = MealRecall.recall(
            meal: meal(),
            boluses: [MealRecall.Bolus(date: mealDate, units: 4)],
            readings: readings { $0 <= 60 ? 110 + Decimal($0) * 2 : 230 },
            otherMeals: [],
            lowMgdl: 70,
            isf: 50,
            increment: 0.05
        )
        if case let .highRise(_, rise) = recall.outcome { #expect(rise > 80) } else { Issue.record("\(recall.outcome)") }
        #expect(recall.step == 0.5)
        #expect(recall.suggested == 4.5)
    }

    @Test("a low after the first 30 minutes asks for one step less") func low() {
        let recall = MealRecall.recall(
            meal: meal(),
            boluses: [MealRecall.Bolus(date: mealDate, units: 4)],
            readings: readings { $0 < 120 ? 120 : 65 },
            otherMeals: [],
            lowMgdl: 70,
            isf: 50,
            increment: 0.05
        )
        if case .low = recall.outcome {} else { Issue.record("\(recall.outcome)") }
        #expect(recall.suggested == 3.5)
    }

    @Test("whichever came first wins") func earliestWins() {
        // rises over 80 first, then crashes
        let outcome = MealRecall.outcome(
            for: meal(),
            readings: readings { $0 < 60 ? 100 + Decimal($0) * 2 : ($0 < 180 ? 200 : 60) },
            otherMeals: [],
            lowMgdl: 70
        )
        if case .highRise = outcome {} else { Issue.record("\(outcome)") }
    }

    @Test("on target keeps the dose; no bolus last time gives no suggestion") func onTargetAndNoBolus() {
        let flat = readings { 110 + min(Decimal($0) / 2, 40) }
        let kept = MealRecall.recall(
            meal: meal(), boluses: [MealRecall.Bolus(date: mealDate, units: 4)], readings: flat,
            otherMeals: [], lowMgdl: 70, isf: 50, increment: 0.05
        )
        #expect(kept.outcome == .onTarget(peakRise: 40))
        #expect(kept.suggested == 4)
        let noBolus = MealRecall.recall(
            meal: meal(), boluses: [], readings: flat, otherMeals: [], lowMgdl: 70, isf: 50, increment: 0.05
        )
        #expect(noBolus.suggested == nil)
    }

    @Test("a next meal within the first hour or missing glucose leaves it unknown") func unknown() {
        let flat = readings { _ in 110 }
        let soon = MealRecall.Meal(date: mealDate.addingTimeInterval(40 * 60), carbs: 30, note: "Dessert")
        #expect(MealRecall.outcome(for: meal(), readings: flat, otherMeals: [soon], lowMgdl: 70) == .unknown)
        #expect(MealRecall.outcome(for: meal(), readings: [], otherMeals: [], lowMgdl: 70) == .unknown)
        // a small snack does not cut the window
        let snack = MealRecall.Meal(date: mealDate.addingTimeInterval(40 * 60), carbs: 5, note: "")
        #expect(MealRecall.outcome(for: meal(), readings: flat, otherMeals: [snack], lowMgdl: 70) == .onTarget(peakRise: 0))
    }

    @Test("the step follows the ISF and the pump increment") func step() {
        #expect(MealRecall.roundTo(Decimal(25) / 45, 0.1) == 0.6)
        let recall = MealRecall.recall(
            meal: meal(), boluses: [MealRecall.Bolus(date: mealDate, units: 0.3)],
            readings: readings { $0 < 120 ? 120 : 65 }, otherMeals: [], lowMgdl: 70, isf: 200, increment: 0.1
        )
        #expect(recall.step == 0.1)
        #expect(recall.suggested == 0.2)
    }
}
