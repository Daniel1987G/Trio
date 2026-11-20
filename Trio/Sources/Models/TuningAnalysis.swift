import Foundation

/// Profile and autoISF weight suggestions from the user's own data (computed on the phone).
///
/// Profile part, after the idea of oref's autotune: the effect of the insulin given beyond the
/// scheduled basal (boluses, SMBs, temp basal deviations) is modelled with the exponential insulin
/// curve; what glucose did beyond that ("deviation") tells where the profile is off.
/// - fasting (no carbs or meal bolus for a while): deviations → basal per 3-hour block
/// - fasting while extra insulin works and glucose is high: actual drop vs. expected → ISF
/// - meals: carbs vs. insulin the meal took → carb ratio per meal time
///
/// autoISF part: meals with an outcome (peak, late low, plateau) and the autoISF factors the loop
/// used → one next step for the weights, in the order the FCL e-book tunes them.
///
/// All suggestions are damped (half way to the measured value, at most ±20 %) and need data on
/// several days. Nothing changes without the user.
enum TuningAnalysis {
    // MARK: - Input

    struct Input {
        struct Reading { let date: Date
            let mgdl: Double }

        struct Dose { let date: Date
            let units: Double
            let isSMB: Bool }

        struct Temp { let date: Date
            let rate: Double
            let minutes: Int }

        struct Carbs { let date: Date
            let grams: Double
            let isEquivalent: Bool }

        struct Interval { let start: Date
            let end: Date }

        /// autoISF factors of one loop cycle, read from the determination's reason.
        struct AutoISFFactors: Equatable {
            let date: Date
            var acce: Double?
            var bg: Double?
            var pp: Double?
            var dura: Double?
            var final: Double?
        }

        struct ScheduleEntry { let minutes: Int
            let value: Double }

        var start: Date
        var end: Date
        var readings: [Reading] = []
        var doses: [Dose] = []
        var temps: [Temp] = []
        var carbs: [Carbs] = []
        /// Overrides and temp targets: left out of the profile analysis.
        var excluded: [Interval] = []
        var autoISF: [AutoISFFactors] = []

        var basal: [ScheduleEntry] = []
        /// mg/dL per unit
        var isf: [ScheduleEntry] = []
        /// g per unit
        var carbRatio: [ScheduleEntry] = []
        var targetMgdl: Double = 100
        var diaHours: Double = 6
        var peakMinutes: Double = 75
    }

    struct AutoISFSettings: Equatable {
        var enabled: Bool
        var bgAccel: Decimal
        var bgBrake: Decimal
        var pp: Decimal
        var dura: Decimal
        var autoISFmax: Decimal
    }

    // MARK: - Output

    struct Report: Equatable {
        var periodDays: Int
        var basal: [BlockSuggestion]
        var isf: Suggestion
        var carbRatio: [BlockSuggestion]
        var meals: MealStats
        var autoISF: WeightSuggestion?
    }

    enum Confidence: String, Equatable {
        case sufficient
        case tooLittleData
    }

    struct Suggestion: Equatable {
        /// Measured factor (needed / current), before damping.
        var measured: Double?
        /// Suggested factor for the schedule, damped and limited; nil without a suggestion.
        var factor: Decimal?
        var samples: Int
        var days: Int
        var confidence: Confidence
    }

    struct BlockSuggestion: Equatable, Identifiable {
        var id: Int { startHour }
        var startHour: Int
        var endHour: Int
        var suggestion: Suggestion
    }

    struct MealStats: Equatable {
        var count = 0
        var unannounced = 0
        var medianPeakRise: Double?
        var highPeaks = 0
        var lateLows = 0
        var plateaus = 0
    }

    enum Weight: String, Equatable, CaseIterable {
        case bgAccel
        case bgBrake
        case pp
        case dura
    }

    struct WeightSuggestion: Equatable {
        enum Verdict: String, Equatable {
            /// Late lows after meals: autoISF too strong.
            case tooStrong
            /// High peaks without late lows: autoISF too weak.
            case tooWeak
            /// Glucose stays high for long after meals.
            case plateau
            /// Nothing to change.
            case fine
            case tooFewMeals
            /// autoISF already at autoISF max in most meals: a weight cannot add more.
            case cappedByMax
        }

        var verdict: Verdict
        var weight: Weight?
        var current: Decimal?
        var proposed: Decimal?
    }

    // MARK: - Constants

    static let blockHours = 3
    static let fastingCarbHours: Double = 4
    static let fastingBolusHours: Double = 3
    /// Half way to the measured value…
    static let damping = 0.5
    /// …and at most this far per step.
    static let maxStep = 0.2
    /// Changes smaller than this are not suggested.
    static let minChange = 0.05
    static let minMeals = 4

    static func minimumDays(for periodDays: Int) -> Int { max(3, Int((Double(periodDays) / 2).rounded(.up))) }

    // MARK: - Build

    static func build(_ input: Input, autoISF: AutoISFSettings?, calendar: Calendar = .current) -> Report {
        let periodDays = max(1, Int((input.end.timeIntervalSince(input.start) / 86400).rounded()))
        let steps = deviationSteps(input, calendar: calendar)
        let meals = mealOutcomes(input, calendar: calendar)
        return Report(
            periodDays: periodDays,
            basal: basalBlocks(steps, input: input, periodDays: periodDays, calendar: calendar),
            isf: isfSuggestion(steps, periodDays: periodDays, calendar: calendar),
            carbRatio: carbRatioBlocks(input, meals: meals, periodDays: periodDays, calendar: calendar),
            meals: mealStats(meals),
            autoISF: autoISF.flatMap { $0.enabled ? weightSuggestion(meals: meals, settings: $0, input: input) : nil }
        )
    }

    // MARK: - Schedules and insulin

    static func value(_ schedule: [Input.ScheduleEntry], at date: Date, calendar: Calendar) -> Double {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let sorted = schedule.sorted { $0.minutes < $1.minutes }
        return sorted.last { $0.minutes <= minute }?.value ?? sorted.first?.value ?? 0
    }

    /// Basal rate running at `date`: the last temp basal still active, else the schedule.
    static func deliveredRate(at date: Date, temps: [Input.Temp], basal: [Input.ScheduleEntry], calendar: Calendar) -> Double {
        if let index = temps.lastIndex(where: { $0.date <= date }) {
            let temp = temps[index]
            var end = temp.date.addingTimeInterval(Double(temp.minutes) * 60)
            if index + 1 < temps.count { end = min(end, temps[index + 1].date) }
            if date < end { return temp.rate }
        }
        return value(basal, at: date, calendar: calendar)
    }

    /// Insulin beyond the scheduled basal, in 5-minute buckets: (time, units).
    static func netInsulin(_ input: Input, calendar: Calendar) -> [(date: Date, units: Double)] {
        let temps = input.temps.sorted { $0.date < $1.date }
        var result: [(date: Date, units: Double)] = []
        let begin = input.start.addingTimeInterval(-input.diaHours * 3600)
        var date = begin
        while date < input.end {
            let delivered = deliveredRate(at: date, temps: temps, basal: input.basal, calendar: calendar)
            let scheduled = value(input.basal, at: date, calendar: calendar)
            let deviation = (delivered - scheduled) / 12
            if deviation != 0 { result.append((date, deviation)) }
            date = date.addingTimeInterval(300)
        }
        for dose in input.doses where dose.date >= begin && dose.date < input.end {
            result.append((dose.date, dose.units))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Insulin activity of the exponential curve (fraction of a unit per minute), as oref.
    static func activity(minutesAgo t: Double, peak: Double, diaHours: Double) -> Double {
        let end = diaHours * 60
        guard t > 0, t < end else { return 0 }
        let tau = peak * (1 - peak / end) / (1 - 2 * peak / end)
        let a = 2 * tau / end
        let s = 1 / (1 - a + (1 + a) * exp(-end / tau))
        let value = (s / (tau * tau)) * t * (1 - t / end) * exp(-t / tau)
        return value.isFinite ? max(value, 0) : 0
    }

    // MARK: - Deviations

    struct Step {
        let date: Date
        /// Glucose change over the step, mg/dL per 5 min.
        let delta: Double
        /// Expected change from the net insulin (negative = falling), mg/dL per 5 min.
        let bgi: Double
        let glucose: Double
        let isf: Double
        let fasting: Bool
        var deviation: Double { delta - bgi }
    }

    static func deviationSteps(_ input: Input, calendar: Calendar) -> [Step] {
        let readings = input.readings.sorted { $0.date < $1.date }
        guard readings.count > 2, !input.isf.isEmpty else { return [] }
        let insulin = netInsulin(input, calendar: calendar)
        let carbs = input.carbs.map(\.date).sorted()
        let mealBoluses = input.doses.filter { !$0.isSMB && $0.units >= 0.5 }.map(\.date).sorted()
        let diaSeconds = input.diaHours * 3600

        var steps: [Step] = []
        var low = 0
        for index in 1 ..< readings.count {
            let previous = readings[index - 1]
            let reading = readings[index]
            let gap = reading.date.timeIntervalSince(previous.date)
            guard gap >= 240, gap <= 420, reading.date >= input.start else { continue }
            let isf = value(input.isf, at: reading.date, calendar: calendar)
            guard isf > 0 else { continue }

            // activity of the net insulin at this time, per 5 minutes
            while low < insulin.count, insulin[low].date < reading.date.addingTimeInterval(-diaSeconds) {
                low += 1
            }
            var act = 0.0
            var i = low
            while i < insulin.count, insulin[i].date < reading.date {
                let minutes = reading.date.timeIntervalSince(insulin[i].date) / 60
                act += insulin[i].units * activity(minutesAgo: minutes, peak: input.peakMinutes, diaHours: input.diaHours)
                i += 1
            }
            let bgi = -act * isf * gap / 60

            let date = reading.date
            let fasting = !contains(carbs, from: date.addingTimeInterval(-fastingCarbHours * 3600), to: date) &&
                !contains(mealBoluses, from: date.addingTimeInterval(-fastingBolusHours * 3600), to: date) &&
                !input.excluded.contains { $0.start <= date && date <= $0.end }

            steps.append(Step(
                date: date,
                delta: (reading.mgdl - previous.mgdl) * 300 / gap,
                bgi: bgi * 300 / gap,
                glucose: reading.mgdl,
                isf: isf,
                fasting: fasting
            ))
        }
        return steps
    }

    private static func contains(_ sortedDates: [Date], from: Date, to: Date) -> Bool {
        // binary search for the first date ≥ from
        var low = 0
        var high = sortedDates.count
        while low < high {
            let mid = (low + high) / 2
            if sortedDates[mid] < from { low = mid + 1 } else { high = mid }
        }
        return low < sortedDates.count && sortedDates[low] <= to
    }

    // MARK: - Basal

    static func basalBlocks(_ steps: [Step], input: Input, periodDays: Int, calendar: Calendar) -> [BlockSuggestion] {
        let minDays = minimumDays(for: periodDays)
        return stride(from: 0, to: 24, by: blockHours).map { startHour in
            let endHour = startHour + blockHours
            let inBlock = steps.filter {
                $0.fasting && (startHour ..< endHour).contains(calendar.component(.hour, from: $0.date))
            }
            // per day: mean extra basal needed (U/h) = deviation per hour / ISF
            var perDay: [Date: [Double]] = [:]
            for step in inBlock {
                perDay[calendar.startOfDay(for: step.date), default: []].append(step.deviation * 12 / step.isf)
            }
            let dayValues = perDay.values.filter { $0.count >= 12 }.map { $0.reduce(0, +) / Double($0.count) }
            let samples = inBlock.count
            guard dayValues.count >= minDays else {
                return BlockSuggestion(
                    startHour: startHour,
                    endHour: endHour,
                    suggestion: Suggestion(
                        measured: nil,
                        factor: nil,
                        samples: samples,
                        days: dayValues.count,
                        confidence: .tooLittleData
                    )
                )
            }
            // scheduled basal in the block (mean over its hours)
            let scheduled = (startHour ..< endHour).map { hour in
                value(
                    input.basal,
                    at: calendar.date(bySettingHour: hour, minute: 30, second: 0, of: input.start) ?? input.start,
                    calendar: calendar
                )
            }.reduce(0, +) / Double(blockHours)
            guard scheduled > 0 else {
                return BlockSuggestion(startHour: startHour, endHour: endHour, suggestion: Suggestion(
                    measured: nil, factor: nil, samples: samples, days: dayValues.count, confidence: .tooLittleData
                ))
            }
            let measured = (scheduled + median(dayValues)) / scheduled
            return BlockSuggestion(
                startHour: startHour,
                endHour: endHour,
                suggestion: Suggestion(
                    measured: measured,
                    factor: dampedFactor(measured),
                    samples: samples,
                    days: dayValues.count,
                    confidence: .sufficient
                )
            )
        }
    }

    // MARK: - ISF

    /// Fasting steps with clearly working extra insulin and glucose above target: the drop the
    /// insulin really caused against the drop the ISF expects. Measured factor = ISF needed / ISF.
    static func isfSuggestion(_ steps: [Step], periodDays: Int, calendar: Calendar) -> Suggestion {
        let usable = steps.filter { $0.fasting && $0.bgi <= -1 && $0.glucose >= 120 }
        let days = Set(usable.map { calendar.startOfDay(for: $0.date) }).count
        // 8 hours of such steps over at least the minimum days
        guard usable.count >= 96, days >= minimumDays(for: periodDays) else {
            return Suggestion(measured: nil, factor: nil, samples: usable.count, days: days, confidence: .tooLittleData)
        }
        let actual = usable.map(\.delta).reduce(0, +)
        let expected = usable.map(\.bgi).reduce(0, +)
        // glucose dropping less than expected → ISF is smaller in reality (factor < 1)
        let measured = max(0.3, min(3, actual / expected))
        return Suggestion(
            measured: measured,
            factor: dampedFactor(measured),
            samples: usable.count,
            days: days,
            confidence: .sufficient
        )
    }

    // MARK: - Meals

    struct MealOutcome {
        let date: Date
        let grams: Double
        let announced: Bool
        let startGlucose: Double
        let peakRise: Double
        /// lowest glucose 1.5 to 5 hours after the start
        let lateMin: Double
        /// minutes above 180 mg/dL from 2 to 5 hours after the start
        let lateHighMinutes: Double
        /// glucose 4 hours after the start
        let endGlucose: Double?
        /// insulin beyond the scheduled basal from 15 min before to 4 h after the start
        let netInsulin: Double
        /// another meal or FPU within the 4 hours
        let overlapped: Bool
        var acce: Double?
        var pp: Double?
        var dura: Double?
        var final: Double?
    }

    static func mealOutcomes(_ input: Input, calendar: Calendar) -> [MealOutcome] {
        let readings = input.readings.sorted { $0.date < $1.date }
        guard !readings.isEmpty else { return [] }
        let insulin = netInsulin(input, calendar: calendar)
        let carbs = input.carbs.sorted { $0.date < $1.date }

        // announced meals: carbs ≥ 15 g, entries within 30 min summed
        var starts: [(date: Date, grams: Double, announced: Bool)] = []
        for entry in carbs where !entry.isEquivalent {
            if let last = starts.last, last.announced, entry.date.timeIntervalSince(last.date) <= 1800 {
                starts[starts.count - 1].grams += entry.grams
            } else {
                starts.append((entry.date, entry.grams, true))
            }
        }
        starts = starts.filter { $0.grams >= 15 }

        // unannounced rises (FCL): +30 mg/dL within 30 min, no carbs in the 3 hours before
        var index = 0
        while index < readings.count {
            let reading = readings[index]
            if let later = readings[index...].first(where: { $0.date.timeIntervalSince(reading.date) >= 1800 }),
               later.date.timeIntervalSince(reading.date) <= 2100,
               later.mgdl - reading.mgdl >= 30,
               !carbs.contains(where: { $0.date > reading.date.addingTimeInterval(-3 * 3600) && $0.date <= later.date }),
               !starts.contains(where: { abs($0.date.timeIntervalSince(reading.date)) < 4 * 3600 })
            {
                starts.append((reading.date, 0, false))
                // skip the rest of this rise
                while index < readings.count, readings[index].date < reading.date.addingTimeInterval(3 * 3600) {
                    index += 1
                }
                continue
            }
            index += 1
        }
        starts.sort { $0.date < $1.date }

        return starts.compactMap { start in
            let window = readings.filter { $0.date >= start.date && $0.date <= start.date.addingTimeInterval(5 * 3600) }
            guard window.count >= 36, let first = window.first else { return nil }
            let firstHours = window.filter { $0.date <= start.date.addingTimeInterval(3 * 3600) }
            let late = window.filter { $0.date >= start.date.addingTimeInterval(1.5 * 3600) }
            let after2h = window.filter { $0.date >= start.date.addingTimeInterval(2 * 3600) }
            let end = window.last { $0.date <= start.date.addingTimeInterval(4 * 3600 + 300) }
            let windowEnd = start.date.addingTimeInterval(4 * 3600)
            let net = insulin.filter { $0.date >= start.date.addingTimeInterval(-900) && $0.date < windowEnd }
                .map(\.units).reduce(0, +)
            let overlapped = carbs.contains {
                $0.date > start.date.addingTimeInterval(1800) && $0.date < windowEnd
            } || (start.announced && carbs.contains { $0.isEquivalent && abs($0.date.timeIntervalSince(start.date)) < 4 * 3600 })
            let factors = input.autoISF.filter { $0.date >= start.date && $0.date <= start.date.addingTimeInterval(3 * 3600) }
            func meanAboveOne(_ values: [Double]) -> Double? {
                values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            return MealOutcome(
                date: start.date,
                grams: start.grams,
                announced: start.announced,
                startGlucose: first.mgdl,
                peakRise: (firstHours.map(\.mgdl).max() ?? first.mgdl) - first.mgdl,
                lateMin: late.map(\.mgdl).min() ?? first.mgdl,
                lateHighMinutes: Double(after2h.filter { $0.mgdl > 180 }.count) * 5,
                endGlucose: end?.mgdl,
                netInsulin: net,
                overlapped: overlapped,
                acce: meanAboveOne(factors.compactMap(\.acce)),
                pp: meanAboveOne(factors.compactMap(\.pp)),
                dura: meanAboveOne(factors.compactMap(\.dura)),
                final: meanAboveOne(factors.compactMap(\.final))
            )
        }
    }

    static func mealStats(_ meals: [MealOutcome]) -> MealStats {
        MealStats(
            count: meals.count,
            unannounced: meals.filter { !$0.announced }.count,
            medianPeakRise: meals.isEmpty ? nil : median(meals.map(\.peakRise)),
            highPeaks: meals.filter { $0.peakRise >= 100 || $0.startGlucose + $0.peakRise > 200 }.count,
            lateLows: meals.filter { $0.lateMin < 70 }.count,
            plateaus: meals.filter { $0.lateHighMinutes >= 60 }.count
        )
    }

    // MARK: - Carb ratio

    /// Meal times for the carb ratio: morning 5–11, midday 11–16, evening 16–5.
    static let mealBlocks: [(start: Int, end: Int)] = [(5, 11), (11, 16), (16, 29)]

    static func carbRatioBlocks(
        _ input: Input,
        meals: [MealOutcome],
        periodDays _: Int,
        calendar: Calendar
    ) -> [BlockSuggestion] {
        mealBlocks.map { block in
            let inBlock = meals.filter { meal in
                guard meal.announced, !meal.overlapped, meal.grams >= 20, meal.endGlucose != nil else { return false }
                var hour = calendar.component(.hour, from: meal.date)
                if hour < 5 { hour += 24 }
                return hour >= block.start && hour < block.end
            }
            // carbs ÷ insulin the meal took (net insulin, corrected for where glucose ended up)
            let measured: [Double] = inBlock.compactMap { meal in
                let isf = value(input.isf, at: meal.date, calendar: calendar)
                let ratio = value(input.carbRatio, at: meal.date, calendar: calendar)
                guard isf > 0, ratio > 0, let end = meal.endGlucose else { return nil }
                let needed = meal.netInsulin + (end - meal.startGlucose) / isf
                guard needed > 0.3 else { return nil }
                // CR needed / CR → factor for the ratio (smaller ratio = more insulin)
                return (meal.grams / needed) / ratio
            }
            let days = Set(inBlock.map { calendar.startOfDay(for: $0.date) }).count
            let endHour = block.end % 24
            guard measured.count >= minMeals else {
                return BlockSuggestion(startHour: block.start, endHour: endHour, suggestion: Suggestion(
                    measured: nil, factor: nil, samples: measured.count, days: days, confidence: .tooLittleData
                ))
            }
            let factor = median(measured)
            return BlockSuggestion(startHour: block.start, endHour: endHour, suggestion: Suggestion(
                measured: factor,
                factor: dampedFactor(factor),
                samples: measured.count,
                days: days,
                confidence: .sufficient
            ))
        }
    }

    // MARK: - autoISF weights

    static func weightSuggestion(meals: [MealOutcome], settings: AutoISFSettings, input _: Input) -> WeightSuggestion {
        guard meals.count >= minMeals else { return WeightSuggestion(verdict: .tooFewMeals) }
        let stats = mealStats(meals)
        let lowShare = Double(stats.lateLows) / Double(meals.count)
        let highShare = Double(stats.highPeaks) / Double(meals.count)
        let plateauShare = Double(stats.plateaus) / Double(meals.count)

        func step(_ weight: Weight, up: Bool) -> WeightSuggestion {
            let current: Decimal
            switch weight {
            case .bgAccel: current = settings.bgAccel
            case .bgBrake: current = settings.bgBrake
            case .pp: current = settings.pp
            case .dura: current = settings.dura
            }
            // ±15 % up, −20 % down (the e-book: 10–20 % per step); from 0 start small
            var proposed: Decimal
            if current == 0 {
                proposed = up ? startValue(weight) : 0
            } else {
                proposed = current * (up ? Decimal(string: "1.15")! : Decimal(string: "0.8")!)
            }
            proposed = round(proposed, step: weight == .pp ? Decimal(string: "0.001")! : Decimal(string: "0.005")!)
            return WeightSuggestion(
                verdict: up ? (weight == .dura ? .plateau : .tooWeak) : .tooStrong,
                weight: weight,
                current: current,
                proposed: proposed
            )
        }

        // 1. late lows: too strong — take back what pushed most in those meals
        if stats.lateLows >= 2, lowShare >= 0.2 {
            let lowMeals = meals.filter { $0.lateMin < 70 }
            let dura = lowMeals.compactMap(\.dura).reduce(0, +) / Double(max(lowMeals.count, 1))
            let pp = lowMeals.compactMap(\.pp).reduce(0, +) / Double(max(lowMeals.count, 1))
            let acce = lowMeals.compactMap(\.acce).reduce(0, +) / Double(max(lowMeals.count, 1))
            if dura > 1.05, dura >= pp, settings.dura > 0 { return step(.dura, up: false) }
            if pp > 1.05, pp >= acce, settings.pp > 0 { return step(.pp, up: false) }
            if settings.bgBrake < settings.bgAccel { return step(.bgBrake, up: true).with(verdict: .tooStrong) }
            if settings.bgAccel > 0 { return step(.bgAccel, up: false) }
            return WeightSuggestion(verdict: .tooStrong)
        }

        // 2. high peaks, (almost) no late lows: too weak — acceleration first, then post-meal
        if highShare >= 0.5, stats.lateLows <= 1, lowShare < 0.1 {
            let capped = meals.compactMap(\.final)
                .filter { $0 >= NSDecimalNumber(decimal: settings.autoISFmax).doubleValue - 0.01 }
            if capped.count * 2 >= meals.count { return WeightSuggestion(verdict: .cappedByMax) }
            if settings.bgAccel < Decimal(string: "0.2")! { return step(.bgAccel, up: true) }
            return step(.pp, up: true)
        }

        // 3. long plateaus: duration
        if plateauShare >= 0.3, stats.lateLows == 0 {
            return step(.dura, up: true)
        }

        return WeightSuggestion(verdict: .fine)
    }

    static func startValue(_ weight: Weight) -> Decimal {
        switch weight {
        case .bgAccel: return Decimal(string: "0.05")!
        case .bgBrake: return Decimal(string: "0.025")!
        case .pp: return Decimal(string: "0.005")!
        case .dura: return Decimal(string: "0.2")!
        }
    }

    // MARK: - Reason parsing

    /// autoISF factors from a determination's reason ("acce-ISF Ratio: 1.08, … final Ratio: 1.2").
    static func autoISFFactors(fromReason reason: String, date: Date) -> Input.AutoISFFactors? {
        let tags = reason.components(separatedBy: "; ").first?.components(separatedBy: ", ") ?? []
        func number(_ prefix: String) -> Double? {
            tags.first { $0.hasPrefix(prefix) }.flatMap { Double($0.dropFirst(prefix.count)) }
        }
        var factors = Input.AutoISFFactors(date: date)
        factors.acce = number("acce-ISF Ratio: ")
        factors.bg = number("bg-ISF Ratio: ")
        factors.pp = number("pp-ISF Ratio: ")
        factors.dura = number("dura-ISF Ratio: ")
        factors.final = number("final Ratio: ") ?? (tags.contains("autoISF: not modified") ? 1 : nil)
        return factors.final == nil && factors.acce == nil ? nil : factors
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Half way to the measured factor, at most ±20 %, rounded to 0.01; nil below 5 %.
    static func dampedFactor(_ measured: Double) -> Decimal? {
        let damped = 1 + (measured - 1) * damping
        let limited = min(1 + maxStep, max(1 - maxStep, damped))
        guard abs(limited - 1) >= minChange else { return nil }
        return round(Decimal(limited), step: Decimal(string: "0.01")!)
    }

    static func round(_ value: Decimal, step: Decimal) -> Decimal {
        var scaled = value / step
        var result = Decimal()
        NSDecimalRound(&result, &scaled, 0, .plain)
        return result * step
    }
}

extension TuningAnalysis.Input.AutoISFFactors {
    init(date: Date) { self.init(date: date, acce: nil, bg: nil, pp: nil, dura: nil, final: nil) }
}

extension TuningAnalysis.WeightSuggestion {
    init(verdict: Verdict) { self.init(verdict: verdict, weight: nil, current: nil, proposed: nil) }

    func with(verdict: Verdict) -> Self {
        var copy = self
        copy.verdict = verdict
        return copy
    }
}
