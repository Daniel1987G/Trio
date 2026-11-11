import Foundation

/// Raw data of the last days for the AI therapy report, as plain values (no Core Data objects).
/// Amounts are actual insulin units, glucose in mg/dL.
struct TherapyReportInput {
    struct Glucose: Equatable {
        let date: Date
        let mgdl: Int
    }

    struct Bolus: Equatable {
        let date: Date
        let units: Decimal
        let isSMB: Bool
        let isExternal: Bool
    }

    struct TempBasal: Equatable {
        let date: Date
        /// U/h
        let rate: Decimal
        let minutes: Int
    }

    struct Carbs: Equatable {
        let date: Date
        let grams: Decimal
        /// Fat-protein or extended bolus carb equivalent.
        let isEquivalent: Bool
    }

    struct LoopRun: Equatable {
        let date: Date
        let succeeded: Bool
    }

    struct Adjustment: Equatable {
        enum Kind: String, Encodable {
            case override
            case tempTarget
        }

        let kind: Kind
        let name: String
        let start: Date
        let end: Date
    }

    var start: Date
    var end: Date
    var glucose: [Glucose] = []
    var boluses: [Bolus] = []
    var tempBasals: [TempBasal] = []
    var carbs: [Carbs] = []
    var loops: [LoopRun] = []
    /// Autosens / dynamic sensitivity ratio per determination.
    var sensitivityRatios: [Decimal] = []
    /// The same ratios with their time, for the evaluation by time of day.
    var sensitivitySamples: [(date: Date, ratio: Decimal)] = []
    var adjustments: [Adjustment] = []
    /// Scheduled basal: start offset in minutes since midnight and rate (U/h).
    var basalProfile: [(minutes: Int, rate: Decimal)] = []
}

/// Settings as sent with the report: profiles by start time, limits and the algorithm preferences.
struct TherapyReportSettings: Encodable {
    struct ScheduleItem: Encodable, Equatable {
        let start: String
        let value: Decimal
    }

    struct TargetItem: Encodable, Equatable {
        let start: String
        let lowMgdl: Decimal
        let highMgdl: Decimal
    }

    var displayUnits: String
    var dosingMode: String
    var insulinConcentration: String?
    var diaHours: Decimal?
    var maxBolus: Decimal?
    var maxBasal: Decimal?
    var basalRates: [ScheduleItem] = []
    var isfMgdlPerUnit: [ScheduleItem] = []
    var carbRatioGramsPerUnit: [ScheduleItem] = []
    var targets: [TargetItem] = []
    var preferences: Preferences?
}

/// Everything computed on the phone for the report. No names, no absolute dates: days are counted
/// from the start of the period, times are local clock times.
struct TherapyReport: Encodable {
    struct GlucoseStats: Encodable, Equatable {
        var readings = 0
        var coveragePercent: Decimal = 0
        var meanMgdl: Decimal = 0
        var sdMgdl: Decimal = 0
        var cvPercent: Decimal = 0
        var gmiPercent: Decimal = 0
        var veryLowPercent: Decimal = 0
        var lowPercent: Decimal = 0
        var inRangePercent: Decimal = 0
        var tightRangePercent: Decimal = 0
        var highPercent: Decimal = 0
        var veryHighPercent: Decimal = 0
    }

    struct HourStats: Encodable, Equatable {
        let hour: Int
        let readings: Int
        let medianMgdl: Int
        let p10Mgdl: Int
        let p90Mgdl: Int
        let lowPercent: Decimal
        let highPercent: Decimal
    }

    struct Hypo: Encodable, Equatable {
        /// 1 = first day of the period.
        let day: Int
        let startTime: String
        let minutes: Int
        let nadirMgdl: Int
        let severe: Bool
        let manualBolusUnitsPrev2h: Decimal
        let smbUnitsPrev2h: Decimal
        let carbsPrev3h: Decimal
        let activeAdjustment: String?
    }

    struct LoopStats: Encodable, Equatable {
        var runsPerDay: Decimal = 0
        let expectedRunsPerDay = 288
        var successPercent: Decimal = 0
        var gapsOver15Min = 0
        var longestGapMinutes = 0
    }

    struct InsulinStats: Encodable, Equatable {
        var tddMean: Decimal = 0
        var basalPercent: Decimal = 0
        var manualBolusPerDay: Decimal = 0
        var smbPerDay: Decimal = 0
        var smbCountPerDay: Decimal = 0
        var zeroTempHoursPerDay: Decimal = 0
    }

    struct BasalHour: Encodable, Equatable {
        let hour: Int
        let profileRate: Decimal
        let deliveredRate: Decimal
        /// delivered / profile; above 1 the loop adds basal at this hour, below 1 it takes basal away.
        let ratio: Decimal
    }

    struct CarbStats: Encodable, Equatable {
        var gramsPerDay: Decimal = 0
        var entriesPerDay: Decimal = 0
    }

    struct SensitivityStats: Encodable, Equatable {
        let mean: Decimal
        let min: Decimal
        let max: Decimal
    }

    var periodDays: Int
    var daysWithGlucose: Int
    var glucose: GlucoseStats
    var glucoseByHour: [HourStats]
    var hypos: [Hypo]
    var hypoCount: Int
    var severeHypoCount: Int
    var loop: LoopStats
    var insulin: InsulinStats
    var basalByHour: [BasalHour]
    var carbs: CarbStats
    var sensitivityRatio: SensitivityStats?
    /// Sensitivity ratio by time of day with suggested profile factors.
    var sensitivityByTime: SensitivityReport?
    var adjustmentsUsed: [String: Int]
    var settings: TherapyReportSettings?
}

// MARK: - Building

enum TherapyReportBuilder {
    static let lowMgdl = 70
    static let veryLowMgdl = 54
    static let highMgdl = 180
    static let veryHighMgdl = 250
    static let tightHighMgdl = 140
    /// A hypo counts when glucose stays below 70 for at least this long.
    static let hypoMinimumMinutes = 15
    /// Readings further apart than this end an episode (sensor gap).
    static let maxReadingGap: TimeInterval = 15 * 60
    /// At most this many hypos are listed (most recent first); the counts include all.
    static let maxListedHypos = 30

    static func build(
        _ input: TherapyReportInput,
        settings: TherapyReportSettings?,
        calendar: Calendar = .current
    ) -> TherapyReport {
        let glucose = input.glucose.sorted { $0.date < $1.date }
        let periodSeconds = max(input.end.timeIntervalSince(input.start), 1)
        let periodDays = max(1, Int((periodSeconds / 86400).rounded()))
        let dayCount = Decimal(periodSeconds / 86400)
        let hypos = hypoEpisodes(glucose, input: input, calendar: calendar)

        return TherapyReport(
            periodDays: periodDays,
            daysWithGlucose: Set(glucose.map { calendar.startOfDay(for: $0.date) }).count,
            glucose: glucoseStats(glucose, periodSeconds: periodSeconds),
            glucoseByHour: hourStats(glucose, calendar: calendar),
            hypos: Array(hypos.reversed().prefix(maxListedHypos)),
            hypoCount: hypos.count,
            severeHypoCount: hypos.filter(\.severe).count,
            loop: loopStats(input.loops, dayCount: dayCount),
            insulin: insulinStats(input, dayCount: dayCount, calendar: calendar),
            basalByHour: basalByHour(input, calendar: calendar),
            carbs: carbStats(input.carbs, dayCount: dayCount),
            sensitivityRatio: sensitivityStats(input.sensitivityRatios),
            sensitivityByTime: settings.map { settings in
                SensitivityReportBuilder.build(
                    samples: input.sensitivitySamples,
                    periodDays: periodDays,
                    basal: SensitivityReportBuilder.schedule(settings.basalRates),
                    isfMgdl: SensitivityReportBuilder.schedule(settings.isfMgdlPerUnit),
                    carbRatio: SensitivityReportBuilder.schedule(settings.carbRatioGramsPerUnit),
                    isDynamicISF: settings.preferences?.useNewFormula ?? false,
                    calendar: calendar
                )
            },
            adjustmentsUsed: Dictionary(grouping: input.adjustments, by: { "\($0.kind.rawValue): \($0.name)" })
                .mapValues(\.count),
            settings: settings
        )
    }

    // MARK: Glucose

    static func glucoseStats(_ glucose: [TherapyReportInput.Glucose], periodSeconds: TimeInterval) -> TherapyReport
        .GlucoseStats
    {
        var stats = TherapyReport.GlucoseStats()
        guard !glucose.isEmpty else { return stats }
        let values = glucose.map { Double($0.mgdl) }
        let count = Double(values.count)
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let sd = variance.squareRoot()
        func percent(_ predicate: (Int) -> Bool) -> Decimal {
            round(Decimal(Double(glucose.filter { predicate($0.mgdl) }.count) / count * 100), 1)
        }
        stats.readings = glucose.count
        stats.coveragePercent = round(Decimal(min(count * 5 * 60 / periodSeconds, 1) * 100), 0)
        stats.meanMgdl = round(Decimal(mean), 0)
        stats.sdMgdl = round(Decimal(sd), 0)
        stats.cvPercent = round(Decimal(mean > 0 ? sd / mean * 100 : 0), 1)
        stats.gmiPercent = round(Decimal(3.31 + 0.02392 * mean), 1)
        stats.veryLowPercent = percent { $0 < veryLowMgdl }
        stats.lowPercent = percent { $0 >= veryLowMgdl && $0 < lowMgdl }
        stats.inRangePercent = percent { $0 >= lowMgdl && $0 <= highMgdl }
        stats.tightRangePercent = percent { $0 >= lowMgdl && $0 <= tightHighMgdl }
        stats.highPercent = percent { $0 > highMgdl && $0 <= veryHighMgdl }
        stats.veryHighPercent = percent { $0 > veryHighMgdl }
        return stats
    }

    static func hourStats(_ glucose: [TherapyReportInput.Glucose], calendar: Calendar) -> [TherapyReport.HourStats] {
        let byHour = Dictionary(grouping: glucose) { calendar.component(.hour, from: $0.date) }
        return (0 ..< 24).compactMap { hour in
            guard let readings = byHour[hour], !readings.isEmpty else { return nil }
            let sorted = readings.map(\.mgdl).sorted()
            let count = Double(sorted.count)
            func percentile(_ p: Double) -> Int { sorted[min(sorted.count - 1, Int((count - 1) * p))] }
            return TherapyReport.HourStats(
                hour: hour,
                readings: sorted.count,
                medianMgdl: percentile(0.5),
                p10Mgdl: percentile(0.1),
                p90Mgdl: percentile(0.9),
                lowPercent: round(Decimal(Double(sorted.filter { $0 < lowMgdl }.count) / count * 100), 1),
                highPercent: round(Decimal(Double(sorted.filter { $0 > highMgdl }.count) / count * 100), 1)
            )
        }
    }

    // MARK: Hypos

    /// Episodes below 70 mg/dL lasting at least 15 minutes, oldest first. An episode ends with the
    /// first reading at or above 70, or with a sensor gap (then it ends 5 minutes after the last low).
    static func hypoEpisodes(
        _ glucose: [TherapyReportInput.Glucose],
        input: TherapyReportInput,
        calendar: Calendar
    ) -> [TherapyReport.Hypo] {
        var episodes: [TherapyReport.Hypo] = []
        var index = 0
        while index < glucose.count {
            guard glucose[index].mgdl < lowMgdl else {
                index += 1
                continue
            }
            let start = glucose[index].date
            var nadir = glucose[index].mgdl
            var end = start.addingTimeInterval(5 * 60)
            var next = index + 1
            while next < glucose.count {
                let reading = glucose[next]
                if reading.date.timeIntervalSince(glucose[next - 1].date) > maxReadingGap {
                    end = glucose[next - 1].date.addingTimeInterval(5 * 60)
                    break
                }
                if reading.mgdl >= lowMgdl {
                    end = reading.date
                    break
                }
                nadir = min(nadir, reading.mgdl)
                end = reading.date.addingTimeInterval(5 * 60)
                next += 1
            }
            let minutes = Int(end.timeIntervalSince(start) / 60)
            if minutes >= hypoMinimumMinutes {
                episodes.append(hypo(start: start, minutes: minutes, nadir: nadir, input: input, calendar: calendar))
            }
            index = max(next, index + 1)
        }
        return episodes
    }

    private static func hypo(
        start: Date,
        minutes: Int,
        nadir: Int,
        input: TherapyReportInput,
        calendar: Calendar
    ) -> TherapyReport.Hypo {
        let twoHoursBefore = start.addingTimeInterval(-2 * 3600)
        let threeHoursBefore = start.addingTimeInterval(-3 * 3600)
        let recentBoluses = input.boluses.filter { $0.date >= twoHoursBefore && $0.date < start }
        let carbs = input.carbs.filter { $0.date >= threeHoursBefore && $0.date < start }.reduce(Decimal(0)) { $0 + $1.grams }
        let adjustment = input.adjustments.first { $0.start <= start && $0.end > start }
        return TherapyReport.Hypo(
            day: Int(start.timeIntervalSince(input.start) / 86400) + 1,
            startTime: clockTime(start, calendar: calendar),
            minutes: minutes,
            nadirMgdl: nadir,
            severe: nadir < veryLowMgdl,
            manualBolusUnitsPrev2h: round(recentBoluses.filter { !$0.isSMB }.reduce(Decimal(0)) { $0 + $1.units }, 2),
            smbUnitsPrev2h: round(recentBoluses.filter(\.isSMB).reduce(Decimal(0)) { $0 + $1.units }, 2),
            carbsPrev3h: round(carbs, 0),
            activeAdjustment: adjustment.map { "\($0.kind.rawValue): \($0.name)" }
        )
    }

    // MARK: Loop

    static func loopStats(_ loops: [TherapyReportInput.LoopRun], dayCount: Decimal) -> TherapyReport.LoopStats {
        var stats = TherapyReport.LoopStats()
        guard !loops.isEmpty else { return stats }
        let sorted = loops.sorted { $0.date < $1.date }
        stats.runsPerDay = round(Decimal(sorted.count) / max(dayCount, 1), 0)
        stats.successPercent = round(Decimal(sorted.filter(\.succeeded).count) / Decimal(sorted.count) * 100, 1)
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.date.timeIntervalSince($0.date) / 60 }
        stats.gapsOver15Min = gaps.filter { $0 > 15 }.count
        stats.longestGapMinutes = Int(gaps.max() ?? 0)
        return stats
    }

    // MARK: Insulin and basal

    static func scheduledRate(at date: Date, profile: [(minutes: Int, rate: Decimal)], calendar: Calendar) -> Decimal {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return profile.sorted { $0.minutes < $1.minutes }.last { $0.minutes <= minute }?.rate ?? profile.first?.rate ?? 0
    }

    static func activeTemp(at date: Date, temps: [TherapyReportInput.TempBasal]) -> TherapyReportInput.TempBasal? {
        // last temp that started at or before `date`
        var low = 0
        var high = temps.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if temps[mid].date <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = found else { return nil }
        let temp = temps[index]
        var end = temp.date.addingTimeInterval(Double(temp.minutes) * 60)
        if index + 1 < temps.count { end = min(end, temps[index + 1].date) }
        return date < end ? temp : nil
    }

    /// Basal delivered in 5-minute steps over the period, per hour of day: (delivered U/h, scheduled U/h).
    private static func basalSamples(
        _ input: TherapyReportInput,
        calendar: Calendar
    ) -> (total: Decimal, zeroMinutes: Int, byHour: [Int: (delivered: Decimal, scheduled: Decimal, steps: Int)]) {
        let temps = input.tempBasals.sorted { $0.date < $1.date }
        var total: Decimal = 0
        var zeroMinutes = 0
        var byHour: [Int: (delivered: Decimal, scheduled: Decimal, steps: Int)] = [:]
        guard !input.basalProfile.isEmpty || !temps.isEmpty else { return (0, 0, [:]) }
        var date = input.start
        while date < input.end {
            let scheduled = scheduledRate(at: date, profile: input.basalProfile, calendar: calendar)
            let rate = activeTemp(at: date, temps: temps)?.rate ?? scheduled
            total += rate / 12
            if rate == 0 { zeroMinutes += 5 }
            let hour = calendar.component(.hour, from: date)
            let current = byHour[hour] ?? (0, 0, 0)
            byHour[hour] = (current.delivered + rate, current.scheduled + scheduled, current.steps + 1)
            date = date.addingTimeInterval(5 * 60)
        }
        return (total, zeroMinutes, byHour)
    }

    static func insulinStats(_ input: TherapyReportInput, dayCount: Decimal, calendar: Calendar) -> TherapyReport.InsulinStats {
        var stats = TherapyReport.InsulinStats()
        let days = max(dayCount, 1)
        let basal = basalSamples(input, calendar: calendar)
        let manual = input.boluses.filter { !$0.isSMB }.reduce(Decimal(0)) { $0 + $1.units }
        let smbs = input.boluses.filter(\.isSMB)
        let smbUnits = smbs.reduce(Decimal(0)) { $0 + $1.units }
        let total = basal.total + manual + smbUnits
        stats.tddMean = round(total / days, 1)
        stats.basalPercent = total > 0 ? round(basal.total / total * 100, 0) : 0
        stats.manualBolusPerDay = round(manual / days, 1)
        stats.smbPerDay = round(smbUnits / days, 1)
        stats.smbCountPerDay = round(Decimal(smbs.count) / days, 0)
        stats.zeroTempHoursPerDay = round(Decimal(basal.zeroMinutes) / 60 / days, 1)
        return stats
    }

    static func basalByHour(_ input: TherapyReportInput, calendar: Calendar) -> [TherapyReport.BasalHour] {
        let samples = basalSamples(input, calendar: calendar).byHour
        return (0 ..< 24).compactMap { hour in
            guard let sample = samples[hour], sample.steps > 0 else { return nil }
            let delivered = sample.delivered / Decimal(sample.steps)
            let scheduled = sample.scheduled / Decimal(sample.steps)
            return TherapyReport.BasalHour(
                hour: hour,
                profileRate: round(scheduled, 2),
                deliveredRate: round(delivered, 2),
                ratio: scheduled > 0 ? round(delivered / scheduled, 2) : 0
            )
        }
    }

    // MARK: Carbs and sensitivity

    static func carbStats(_ carbs: [TherapyReportInput.Carbs], dayCount: Decimal) -> TherapyReport.CarbStats {
        let days = max(dayCount, 1)
        let meals = carbs.filter { !$0.isEquivalent && $0.grams > 0 }
        return TherapyReport.CarbStats(
            gramsPerDay: round(carbs.reduce(Decimal(0)) { $0 + $1.grams } / days, 0),
            entriesPerDay: round(Decimal(meals.count) / days, 1)
        )
    }

    static func sensitivityStats(_ ratios: [Decimal]) -> TherapyReport.SensitivityStats? {
        let values = ratios.filter { $0 > 0 }
        guard let minValue = values.min(), let maxValue = values.max() else { return nil }
        let mean = values.reduce(Decimal(0), +) / Decimal(values.count)
        return TherapyReport.SensitivityStats(mean: round(mean, 2), min: round(minValue, 2), max: round(maxValue, 2))
    }

    // MARK: Helpers

    static func clockTime(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    static func clockTime(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func round(_ value: Decimal, _ scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }
}

// MARK: - Topics

/// The evaluations that can be started on their own; `overall` covers everything in one answer.
enum TherapyReportTopic: String, CaseIterable, Identifiable, Codable {
    case loop
    case basal
    case factors
    case hypos
    case settings
    case overall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: return String(localized: "Loop", comment: "AI report topic")
        case .basal: return String(localized: "Basal Rate", comment: "AI report topic")
        case .factors: return String(localized: "ISF and Carb Ratio", comment: "AI report topic")
        case .hypos: return String(localized: "Hypoglycemia", comment: "AI report topic")
        case .settings: return String(localized: "Settings", comment: "AI report topic")
        case .overall: return String(localized: "Overall Evaluation", comment: "AI report topic")
        }
    }

    var subtitle: String {
        switch self {
        case .loop: return String(localized: "Reliability, gaps and their effect", comment: "AI report topic")
        case .basal: return String(localized: "Basal profile by time of day", comment: "AI report topic")
        case .factors: return String(localized: "Corrections and meals", comment: "AI report topic")
        case .hypos: return String(localized: "Patterns, causes and prevention", comment: "AI report topic")
        case .settings: return String(localized: "Algorithm, SMB, limits and targets", comment: "AI report topic")
        case .overall: return String(localized: "All topics in one evaluation", comment: "AI report topic")
        }
    }

    var systemImage: String {
        switch self {
        case .loop: return "arrow.triangle.2.circlepath"
        case .basal: return "chart.bar.xaxis"
        case .factors: return "divide"
        case .hypos: return "arrow.down.to.line"
        case .settings: return "slider.horizontal.3"
        case .overall: return "doc.text.magnifyingglass"
        }
    }

    /// Parts of the report sent for this topic (the period, glucose overview and settings always).
    var parts: Set<TherapyReport.Part> {
        let common: Set<TherapyReport.Part> = [.periodDays, .daysWithGlucose, .glucose, .settings]
        switch self {
        case .loop: return common.union([.loop, .insulin, .glucoseByHour])
        case .basal: return common.union([.basalByHour, .glucoseByHour, .insulin, .sensitivityRatio, .sensitivityByTime])
        case .factors: return common.union([
                .glucoseByHour,
                .carbs,
                .insulin,
                .sensitivityRatio,
                .sensitivityByTime,
                .basalByHour
            ])
        case .hypos: return common.union([
                .hypos,
                .hypoCount,
                .severeHypoCount,
                .glucoseByHour,
                .adjustmentsUsed,
                .insulin,
                .carbs
            ])
        case .settings: return common.union([
                .loop,
                .insulin,
                .basalByHour,
                .hypoCount,
                .severeHypoCount,
                .sensitivityRatio,
                .glucoseByHour
            ])
        case .overall: return Set(TherapyReport.Part.allCases)
        }
    }

    /// Section headings the answer must use, in order.
    fileprivate var sections: String {
        switch self {
        case .loop:
            return """
            1. Summary (3 to 5 bullet points)
            2. Reliability (runs per day against 288, success rate, gaps and the longest gap)
            3. Effect on glucose control (what missed loops mean, linked to glucoseByHour where possible)
            4. Practical causes and fixes (phone near the pump, background activity, battery, CGM and pump \
            connection, Bluetooth)
            5. Suggestions: at most 5, most important first
            """
        case .basal:
            return """
            1. Summary (3 to 5 bullet points)
            2. Night (0 to 6 o'clock): basalByHour ratio and glucose by hour
            3. Day by time blocks (morning, midday, afternoon, evening)
            4. Where the loop compensates (ratio clearly above or below 1, and for how many hours)
            5. Suggestions for the basal profile by time block: only part of the observed ratio, small steps, \
            and a basal test or night check to confirm
            """
        case .factors:
            return """
            1. Summary (3 to 5 bullet points)
            2. ISF (correction behaviour, periods of high glucose, sensitivityRatio, SMB share)
            3. Carb ratio (glucose after typical meal times by hour, carbs per day)
            4. Interplay of basal, ISF and carb ratio (which one to look at first)
            5. Suggestions: at most 5, most important first, each tied to a time block
            """
        case .hypos:
            return """
            1. Summary (3 to 5 bullet points)
            2. Frequency and severity (count, below 54, time below range)
            3. Patterns by time of day and day of the period
            4. Likely causes from the context (manual bolus, SMB, carbs, overrides, temp targets)
            5. Prevention (settings, targets, behaviour), most effective first
            6. Suggestions: at most 5
            """
        case .settings:
            return """
            1. Summary (3 to 5 bullet points)
            2. Algorithm and SMB (which SMB options are on, max SMB and UAM minutes, autosens and dynamic ISF)
            3. Safety limits (max IOB, max bolus, max basal, DIA) in relation to the total daily dose
            4. Targets and profile structure (number of blocks, jumps between blocks)
            5. Unusual or inconsistent settings
            6. Suggestions: at most 5, most important first
            """
        case .overall:
            return """
            1. Summary (3 to 5 bullet points)
            2. Loop (reliability and what gaps mean for control)
            3. Basal rate (use basalByHour and the night hours of glucoseByHour)
            4. Factors (ISF and carb ratio: patterns after meals and corrections, sensitivityRatio)
            5. Hypoglycemia (patterns by time of day and likely causes from the context)
            6. Settings (SMB, max IOB, targets, DIA and anything unusual)
            7. Suggestions: at most 5, most important first
            """
        }
    }
}

// MARK: - Prompt

extension TherapyReport {
    /// Top-level parts of the report, so each topic sends only what it needs.
    enum Part: String, CodingKey, CaseIterable {
        case periodDays
        case daysWithGlucose
        case glucose
        case glucoseByHour
        case hypos
        case hypoCount
        case severeHypoCount
        case loop
        case insulin
        case basalByHour
        case carbs
        case sensitivityRatio
        case sensitivityByTime
        case adjustmentsUsed
        case settings
    }

    /// The selected parts of a report, encoded under the same keys as the full report.
    private struct Payload: Encodable {
        let report: TherapyReport
        let parts: Set<Part>

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Part.self)
            for part in Part.allCases where parts.contains(part) {
                switch part {
                case .periodDays: try container.encode(report.periodDays, forKey: part)
                case .daysWithGlucose: try container.encode(report.daysWithGlucose, forKey: part)
                case .glucose: try container.encode(report.glucose, forKey: part)
                case .glucoseByHour: try container.encode(report.glucoseByHour, forKey: part)
                case .hypos: try container.encode(report.hypos, forKey: part)
                case .hypoCount: try container.encode(report.hypoCount, forKey: part)
                case .severeHypoCount: try container.encode(report.severeHypoCount, forKey: part)
                case .loop: try container.encode(report.loop, forKey: part)
                case .insulin: try container.encode(report.insulin, forKey: part)
                case .basalByHour: try container.encode(report.basalByHour, forKey: part)
                case .carbs: try container.encode(report.carbs, forKey: part)
                case .sensitivityRatio: try container.encodeIfPresent(report.sensitivityRatio, forKey: part)
                case .sensitivityByTime: try container.encodeIfPresent(report.sensitivityByTime, forKey: part)
                case .adjustmentsUsed: try container.encode(report.adjustmentsUsed, forKey: part)
                case .settings: try container.encodeIfPresent(report.settings, forKey: part)
                }
            }
        }
    }

    /// The data sent for `topic` (sorted keys, so the same data gives the same text).
    func summaryJSON(for topic: TherapyReportTopic = .overall) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Payload(report: self, parts: topic.parts)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Instructions for the AI provider. The answer is Markdown in the user's language.
    static func prompt(
        topic: TherapyReportTopic,
        summaryJSON: String,
        periodDays: Int,
        languageCode: String
    ) -> String {
        let focus = topic == .overall ? "all topics" : "the topic \"\(topic.rawValue)\" only"
        let shortPeriodRule = periodDays < 7 ?
            "\n- The period is only \(periodDays) days: describe patterns as preliminary, single days weigh " +
            "heavily, and suggest no change to basal rates, ISF or carb ratio from this period alone." : ""
        return """
        You are an experienced diabetes data analyst. Review the data of a person with type 1 diabetes \
        who uses OpenTrio, an open-source automated insulin delivery system based on the oref algorithm \
        (temp basals and SMBs, super micro boluses). The JSON below was computed on the phone for the \
        last \(periodDays) days. Glucose is in mg/dL, insulin in units (U), times are local clock times, \
        days are counted from the start of the period. Evaluate \(focus).

        Field notes (only some fields may be present):
        - glucose: time in ranges per international consensus (veryLow < 54, low 54-69, inRange 70-180, \
        tightRange 70-140, high 181-250, veryHigh > 250), cv = coefficient of variation, gmi = glucose \
        management indicator.
        - glucoseByHour: median and 10th/90th percentile per hour of day.
        - hypos: episodes below 70 for at least 15 minutes (most recent first) with manual bolus and SMB \
        insulin in the 2 hours and carbs in the 3 hours before, and an active override or temp target.
        - loop: runs per day (288 expected at 5-minute cycles), success rate, gaps over 15 minutes.
        - basalByHour: scheduled rate vs the basal actually delivered by the loop (temp basals) per hour; \
        ratio > 1 means the loop adds basal at that hour, < 1 means it reduces or suspends it.
        - insulin: total daily dose, basal share, manual bolus and SMB per day, hours per day at zero temp.
        - sensitivityRatio: autosens / dynamic ratio of the algorithm (1 = profile).
        - sensitivityByTime: that ratio in 3-hour blocks (median, quartiles, share of values clearly above / \
        below 1) with a suggested factor where the deviation is clear and stable (basal × factor, ISF and \
        carb ratio ÷ factor). With isDynamicISF the ratio also follows glucose level and total daily dose, \
        so treat it as a hint, not a measurement.
        - settings: basal rates, ISF (mg/dL per U), carb ratio (g per U), targets, DIA, limits and the \
        algorithm preferences.

        Write the evaluation in Markdown in the language with the ISO code "\(languageCode)". Use these \
        sections as level-2 headings, in this order:
        \(topic.sections)

        For each suggestion: what to change, the data behind it, a small step (never more than 10 to 20 \
        percent at once), and how to check the effect afterwards.

        Rules:
        - Base every statement on the data. Say clearly when the data is not sufficient.
        - Do not invent values. Address hypoglycemia before high glucose.
        - No diagnosis. Point out that changes should be discussed with the diabetes team and made one at a time.
        - Keep it under about \(topic == .overall ? 900 : 600) words.\(shortPeriodRule)

        Data:
        \(summaryJSON)
        """
    }

    /// Prompt for `topic` with this report's data.
    func prompt(for topic: TherapyReportTopic = .overall, languageCode: String) -> String {
        Self.prompt(
            topic: topic,
            summaryJSON: summaryJSON(for: topic),
            periodDays: periodDays,
            languageCode: languageCode
        )
    }
}

/// An AI evaluation, kept so it is still there when the screen is opened again.
struct SavedTherapyReport: JSON, Equatable {
    /// nil in evaluations saved before there were topics (then: overall).
    var topic: TherapyReportTopic?
    let date: Date
    let days: Int
    let provider: String
    let model: String
    let text: String
}
