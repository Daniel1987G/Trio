import Foundation
import Testing
@testable import Trio

/// Profile and autoISF weight suggestions on simulated days: the "true" body differs from the
/// profile in a known way, and the analysis has to find it (damped, half way).
@Suite("Tuning suggestions") struct TuningAnalysisTests {
    typealias Input = TuningAnalysis.Input

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let days = 14
    private var start: Date { Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400)) }

    /// Profile: basal 1 U/h, ISF 50, CR 10, target 100, DIA 6 h, peak 75 min.
    private func baseInput() -> Input {
        var input = Input(start: start, end: start.addingTimeInterval(Double(days) * 86400))
        input.basal = [.init(minutes: 0, value: 1)]
        input.isf = [.init(minutes: 0, value: 50)]
        input.carbRatio = [.init(minutes: 0, value: 10)]
        return input
    }

    /// Readings every 5 minutes from a glucose function.
    private func readings(_ glucose: (Date) -> Double) -> [Input.Reading] {
        stride(from: 0, to: days * 288, by: 1).map { step in
            let date = start.addingTimeInterval(Double(step) * 300)
            return Input.Reading(date: date, mgdl: glucose(date))
        }
    }

    private func hour(_ date: Date) -> Double {
        Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
    }

    /// Glucose drop so far of a dose given at `doseTime` with the true ISF.
    private func insulinEffect(units: Double, doseTime: Date, at date: Date, isf: Double) -> Double {
        let minutes = date.timeIntervalSince(doseTime) / 60
        guard minutes > 0 else { return 0 }
        var absorbed = 0.0
        var t = 0.0
        while t < min(minutes, 360) {
            absorbed += TuningAnalysis.activity(minutesAgo: t + 0.5, peak: 75, diaHours: 6)
            t += 1
        }
        return units * absorbed * isf
    }

    @Test("Glucose rising at night without food → more basal there, nothing elsewhere") func basalAtNight() {
        var input = baseInput()
        // 0–3 h: the body needs 0.2 U/h more → +0.2/12 × 50 = 0.83 mg/dL per 5 min; flat otherwise
        input.readings = readings { date in
            let h = hour(date)
            return h < 3 ? 110 + h * 10 : 140 - min(h - 3, 1) * 30
        }
        let report = TuningAnalysis.build(input, autoISF: nil, calendar: calendar)
        let night = report.basal[0].suggestion
        #expect(night.confidence == .sufficient)
        // measured 1.2 → half way: 1.1
        #expect(night.factor == Decimal(string: "1.1")!)
        // 6–9: flat → no change
        #expect(report.basal[2].suggestion.factor == nil)
        #expect(report.basal[2].suggestion.confidence == .sufficient)
    }

    @Test("Corrections drop less than the ISF expects → smaller ISF") func isfFromCorrections() {
        var input = baseInput()
        var doses: [Input.Dose] = []
        for day in 0 ..< days {
            doses.append(.init(date: start.addingTimeInterval(Double(day) * 86400 + 14 * 3600), units: 2, isSMB: true))
        }
        input.doses = doses
        // true ISF 40 instead of 50
        input.readings = readings { date in
            let dayStart = calendar.startOfDay(for: date)
            let dose = dayStart.addingTimeInterval(14 * 3600)
            let h = hour(date)
            return h >= 13 ? 250 - insulinEffect(units: 2, doseTime: dose, at: date, isf: 40) : 250
        }
        let report = TuningAnalysis.build(input, autoISF: nil, calendar: calendar)
        #expect(report.isf.confidence == .sufficient)
        let measured = report.isf.measured ?? 0
        #expect(abs(measured - 0.8) < 0.03)
        #expect(report.isf.factor == Decimal(string: "0.9")!)
    }

    @Test("Meals end too high → smaller carb ratio for that meal time") func carbRatio() {
        var input = baseInput()
        var carbs: [Input.Carbs] = []
        var doses: [Input.Dose] = []
        for day in 0 ..< days {
            let meal = start.addingTimeInterval(Double(day) * 86400 + 8 * 3600)
            carbs.append(.init(date: meal, grams: 50, isEquivalent: false))
            doses.append(.init(date: meal, units: 5, isSMB: false))
        }
        input.carbs = carbs
        input.doses = doses
        // true CR 8: 50 g need 6.25 U, 5 U given → ends 1.25 × 50 = 62.5 mg/dL higher
        input.readings = readings { date in
            let h = hour(date)
            guard h >= 8 else { return 110 }
            let into = min(h - 8, 4) / 4
            return 110 + 62.5 * into + (h < 12 ? 40 * sin(Double.pi * into) : 0)
        }
        let report = TuningAnalysis.build(input, autoISF: nil, calendar: calendar)
        let morning = report.carbRatio[0].suggestion
        #expect(morning.confidence == .sufficient)
        #expect(abs((morning.measured ?? 0) - 0.8) < 0.02)
        #expect(morning.factor == Decimal(string: "0.9")!)
        #expect(report.carbRatio[1].suggestion.confidence == .tooLittleData)
    }

    @Test("Big changes are limited to 20 % per step, small ones are left out") func damping() {
        #expect(TuningAnalysis.dampedFactor(2) == Decimal(string: "1.2")!)
        #expect(TuningAnalysis.dampedFactor(0.3) == Decimal(string: "0.8")!)
        #expect(TuningAnalysis.dampedFactor(1.08) == nil)
        #expect(TuningAnalysis.dampedFactor(1.12) == Decimal(string: "1.06")!)
    }

    @Test("Too few days: no suggestion") func tooLittleData() {
        var input = baseInput()
        input.readings = readings { _ in 120 }.filter { $0.date < start.addingTimeInterval(2 * 86400) }
        let report = TuningAnalysis.build(input, autoISF: nil, calendar: calendar)
        #expect(report.basal.allSatisfy { $0.suggestion.factor == nil })
        #expect(report.basal.allSatisfy { $0.suggestion.confidence == .tooLittleData })
    }

    // MARK: - autoISF

    private func meals(peak: Double, lateLow: Bool, plateau: Bool = false, factors: Input.AutoISFFactors? = nil) -> Input {
        var input = baseInput()
        input.carbs = (0 ..< days).map { .init(
            date: start.addingTimeInterval(Double($0) * 86400 + 12 * 3600),
            grams: 40,
            isEquivalent: false
        ) }
        input.readings = readings { date in
            let h = hour(date)
            guard h >= 12, h < 18 else { return 110 }
            let t = h - 12
            if plateau { return t < 1 ? 110 + 100 * t : 210 }
            if t < 1 { return 110 + peak * t }
            if t < 3 { return 110 + peak * (1 - (t - 1) / 2) }
            return lateLow && t < 4 ? 110 - 50 * (t - 3) : (lateLow ? 60 : 110)
        }
        if let factors {
            input.autoISF = (0 ..< days).map {
                var copy = factors
                copy = Input.AutoISFFactors(
                    date: start.addingTimeInterval(Double($0) * 86400 + 12.5 * 3600),
                    acce: copy.acce,
                    bg: copy.bg,
                    pp: copy.pp,
                    dura: copy.dura,
                    final: copy.final
                )
                return copy
            }
        }
        return input
    }

    private let weights = TuningAnalysis.AutoISFSettings(
        enabled: true,
        bgAccel: Decimal(string: "0.05")!,
        bgBrake: Decimal(string: "0.025")!,
        pp: Decimal(string: "0.005")!,
        dura: Decimal(string: "0.2")!,
        autoISFmax: 2
    )

    @Test("High peaks, no lows → raise the acceleration weight first") func tooWeak() {
        let report = TuningAnalysis.build(meals(peak: 120, lateLow: false), autoISF: weights, calendar: calendar)
        #expect(report.meals.count == days)
        #expect(report.autoISF?.verdict == .tooWeak)
        #expect(report.autoISF?.weight == .bgAccel)
        // 0.05 × 1.15 = 0.0575 → 0.06 (step 0.005: 0.055 or 0.06)
        #expect(report.autoISF?.proposed == Decimal(string: "0.06")! || report.autoISF?.proposed == Decimal(string: "0.055")!)
    }

    @Test("Late lows with strong dura factors → lower the duration weight") func tooStrong() {
        let factors = Input.AutoISFFactors(date: start, acce: 1.02, bg: 1, pp: 1.05, dura: 1.3, final: 1.4)
        let report = TuningAnalysis.build(meals(peak: 60, lateLow: true, factors: factors), autoISF: weights, calendar: calendar)
        #expect(report.meals.lateLows == days)
        #expect(report.autoISF?.verdict == .tooStrong)
        #expect(report.autoISF?.weight == .dura)
        #expect(report.autoISF?.proposed == Decimal(string: "0.16")!)
    }

    @Test("Long plateaus without lows → raise the duration weight") func plateau() {
        let report = TuningAnalysis.build(meals(peak: 0, lateLow: false, plateau: true), autoISF: weights, calendar: calendar)
        #expect(report.autoISF?.verdict == .plateau || report.autoISF?.verdict == .tooWeak)
    }

    @Test("autoISF off: no weight suggestion") func autoISFOff() {
        var off = weights
        off.enabled = false
        #expect(TuningAnalysis.build(meals(peak: 120, lateLow: false), autoISF: off, calendar: calendar).autoISF == nil)
    }

    @Test("autoISF factors from the reason") func parseReason() {
        let reason =
            "Autosens ratio: 1, ISF: 50→40, SMB Del.Ratio: 0.6, acce-ISF Ratio: 1.08, autoISF, bg-ISF Ratio: 1.1, pp-ISF Ratio: 1.15, Duration: 10, Avg: 134, dura-ISF Ratio: 1.05, final Ratio: 1.25; Eventual BG 120"
        let factors = TuningAnalysis.autoISFFactors(fromReason: reason, date: start)
        #expect(factors?.acce == 1.08)
        #expect(factors?.pp == 1.15)
        #expect(factors?.dura == 1.05)
        #expect(factors?.final == 1.25)
        #expect(TuningAnalysis.autoISFFactors(fromReason: "Autosens ratio: 1, ISF: 50→50; x", date: start) == nil)
    }

    // MARK: - Proposed profile

    @Test("Scaling splits at block edges, rounds and merges") func scaled() {
        let schedule: [(minutes: Int, value: Decimal)] = [(0, Decimal(string: "0.8")!), (360, Decimal(string: "1.2")!)]
        let result = TuningAnalysis.scaled(
            schedule,
            factors: [(range: 0 ..< 180, factor: Decimal(string: "1.1")!)],
            step: Decimal(string: "0.05")!
        )
        // 0–3 h: 0.88 → 0.9; 3–6 h: 0.8 unchanged; from 6 h: 1.2
        #expect(result.map(\.minutes) == [0, 180, 360])
        #expect(result.map(\.value) == [Decimal(string: "0.9")!, Decimal(string: "0.8")!, Decimal(string: "1.2")!])

        // a factor that rounds back to the same value merges the split again
        let merged = TuningAnalysis.scaled(
            [(0, 1)],
            factors: [(range: 180 ..< 360, factor: Decimal(string: "1.02")!)],
            step: Decimal(string: "0.05")!
        )
        #expect(merged.map(\.minutes) == [0])
    }

    @Test("Proposed profile applies basal, ISF and carb ratio factors") func proposedProfile() {
        let current = ProfileSnapshot(
            id: UUID(),
            name: "now",
            created: start,
            origin: .manual,
            basalProfile: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1)],
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 50, offset: 0, start: "00:00:00")]
            ),
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 10)])
        )
        func block(_ start: Int, _ end: Int, _ factor: String?) -> TuningAnalysis.BlockSuggestion {
            .init(startHour: start, endHour: end, suggestion: .init(
                measured: nil,
                factor: factor.map { Decimal(string: $0)! },
                samples: 0,
                days: 0,
                confidence: .sufficient
            ))
        }
        let report = TuningAnalysis.Report(
            periodDays: 14,
            basal: [block(0, 3, "1.1")] + stride(from: 3, to: 24, by: 3).map { block($0, $0 + 3, nil) },
            isf: .init(measured: 0.8, factor: Decimal(string: "0.9")!, samples: 100, days: 7, confidence: .sufficient),
            carbRatio: [block(5, 11, "0.9"), block(11, 16, nil), block(16, 5, "1.1")],
            meals: .init(),
            autoISF: nil
        )
        let proposed = TuningAnalysis.proposedProfile(from: current, report: report, name: "Vorschlag")
        #expect(proposed.name == "Vorschlag")
        #expect(proposed.id != current.id)
        #expect(proposed.basalProfile.map(\.rate) == [Decimal(string: "1.1")!, 1])
        #expect(proposed.basalProfile.map(\.minutes) == [0, 180])
        #expect(proposed.basalProfile.map(\.start) == ["00:00:00", "03:00:00"])
        #expect(proposed.insulinSensitivities.sensitivities.map(\.sensitivity) == [45])
        // evening 16–5 over midnight, morning 5–11
        #expect(proposed.carbRatios.schedule.map(\.offset) == [0, 300, 660, 960])
        #expect(proposed.carbRatios.schedule.map(\.ratio) == [11, 9, 10, 11])
    }
}
