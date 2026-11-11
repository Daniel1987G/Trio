import Foundation

/// Suggests, per time of day, by which factor the profile could change: from the sensitivity ratio the loop
/// (autosens or dynamic ISF) calculated over the period. A suggestion only, nothing is changed automatically.
///
/// oref's ratio: above 1 = resistant (more insulin needed), below 1 = sensitive. The suggestion follows oref:
/// basal × factor, ISF ÷ factor, carb ratio ÷ factor.
struct SensitivityReport: Encodable, Equatable {
    struct Change: Encodable, Equatable {
        /// Clock time the profile entry starts.
        let start: String
        let current: Decimal
        let proposed: Decimal
    }

    enum Verdict: String, Encodable {
        case resistant
        case sensitive
        case unremarkable
        case insufficientData
    }

    struct Block: Encodable, Equatable, Identifiable {
        var id: Int { startHour }
        /// Local hours, end exclusive (e.g. 3 to 6).
        let startHour: Int
        let endHour: Int
        let sampleCount: Int
        let dayCount: Int
        /// Median ratio and the middle half of the values (25th to 75th percentile).
        let median: Decimal?
        let lowerQuartile: Decimal?
        let upperQuartile: Decimal?
        /// Share of values clearly above / below 1 (percent).
        let resistantPercent: Int
        let sensitivePercent: Int
        let verdict: Verdict
        /// Suggested factor, rounded; nil without a suggestion.
        let factor: Decimal?
        var basal: [Change] = []
        /// ISF in mg/dL per U.
        var isfMgdl: [Change] = []
        /// Carb ratio in g per U.
        var carbRatio: [Change] = []
    }

    struct ScheduleEntry: Equatable {
        /// Minutes since midnight.
        let minutes: Int
        let value: Decimal
    }

    let periodDays: Int
    let blocks: [Block]
    /// Median over the whole period.
    let overallMedian: Decimal?
    let isDynamicISF: Bool

    var suggestions: [Block] { blocks.filter { $0.factor != nil } }
}

enum SensitivityReportBuilder {
    // exact decimal steps (float literals are not exact as Decimal)
    static let step005 = Decimal(string: "0.05")!
    static let step01 = Decimal(string: "0.1")!
    static let step001 = Decimal(string: "0.01")!
    static let blockHours = 3
    /// A block needs a median at least this far from 1 (8 %)…
    static let minDeviation = Decimal(string: "0.08")!
    /// …and this share of its values clearly on the same side of 1.
    static let minDirectionPercent = 60
    /// Values within 1 ± this count as neither resistant nor sensitive.
    static let neutralBand = Decimal(string: "0.02")!
    /// Suggestions stay within the usual autosens limits.
    static let factorRange: ClosedRange<Decimal> = Decimal(string: "0.7")! ... Decimal(string: "1.3")!

    /// Days a block needs values on: half of the period, at least 2.
    static func minimumDays(for periodDays: Int) -> Int {
        max(2, Int((Double(periodDays) / 2).rounded(.up)))
    }

    static func build(
        samples: [(date: Date, ratio: Decimal)],
        periodDays: Int,
        basal: [SensitivityReport.ScheduleEntry],
        isfMgdl: [SensitivityReport.ScheduleEntry],
        carbRatio: [SensitivityReport.ScheduleEntry],
        isDynamicISF: Bool,
        calendar: Calendar = .current
    ) -> SensitivityReport {
        let valid = samples.filter { $0.ratio > 0 }
        let minDays = minimumDays(for: periodDays)
        // about half of the 5-minute cycles of a block on the required days
        let minSamples = minDays * (blockHours * 12) / 2

        var blocks: [SensitivityReport.Block] = []
        for startHour in stride(from: 0, to: 24, by: blockHours) {
            let endHour = startHour + blockHours
            let inBlock = valid.filter {
                let hour = calendar.component(.hour, from: $0.date)
                return hour >= startHour && hour < endHour
            }
            let ratios = inBlock.map(\.ratio).sorted()
            let days = Set(inBlock.map { calendar.startOfDay(for: $0.date) }).count
            let resistant = ratios.filter { $0 > 1 + neutralBand }.count
            let sensitive = ratios.filter { $0 < 1 - neutralBand }.count
            let resistantPercent = ratios.isEmpty ? 0 : resistant * 100 / ratios.count
            let sensitivePercent = ratios.isEmpty ? 0 : sensitive * 100 / ratios.count
            let median = percentile(ratios, 0.5)

            var verdict: SensitivityReport.Verdict = .unremarkable
            var factor: Decimal?
            if days < minDays || ratios.count < minSamples {
                verdict = .insufficientData
            } else if let median {
                if median >= 1 + minDeviation, resistantPercent >= minDirectionPercent {
                    verdict = .resistant
                } else if median <= 1 - minDeviation, sensitivePercent >= minDirectionPercent {
                    verdict = .sensitive
                }
                if verdict != .unremarkable {
                    let rounded = clamp(round(median, step: step005))
                    factor = rounded == 1 ? nil : rounded
                    if factor == nil { verdict = .unremarkable }
                }
            }

            var block = SensitivityReport.Block(
                startHour: startHour,
                endHour: endHour,
                sampleCount: ratios.count,
                dayCount: days,
                median: median.map { round($0, step: step001) },
                lowerQuartile: percentile(ratios, 0.25).map { round($0, step: step001) },
                upperQuartile: percentile(ratios, 0.75).map { round($0, step: step001) },
                resistantPercent: resistantPercent,
                sensitivePercent: sensitivePercent,
                verdict: verdict,
                factor: factor
            )
            if let factor {
                let range = (startHour * 60) ..< (endHour * 60)
                block.basal = changes(basal, in: range) { round($0 * factor, step: step005) }
                block.isfMgdl = changes(isfMgdl, in: range) { round($0 / factor, step: 1) }
                block.carbRatio = changes(carbRatio, in: range) { round($0 / factor, step: step01) }
            }
            blocks.append(block)
        }

        return SensitivityReport(
            periodDays: periodDays,
            blocks: blocks,
            overallMedian: percentile(valid.map(\.ratio).sorted(), 0.5).map { round($0, step: step001) },
            isDynamicISF: isDynamicISF
        )
    }

    /// Profile entries active in a block: the one running at its start and those starting inside it.
    static func changes(
        _ schedule: [SensitivityReport.ScheduleEntry],
        in range: Range<Int>,
        proposed: (Decimal) -> Decimal
    ) -> [SensitivityReport.Change] {
        let sorted = schedule.sorted { $0.minutes < $1.minutes }
        guard !sorted.isEmpty else { return [] }
        var entries: [SensitivityReport.ScheduleEntry] = []
        if let running = sorted.last(where: { $0.minutes <= range.lowerBound }) ?? sorted.last {
            entries.append(.init(minutes: range.lowerBound, value: running.value))
        }
        entries += sorted.filter { $0.minutes > range.lowerBound && range.contains($0.minutes) }
        return entries.map {
            .init(start: TherapyReportBuilder.clockTime(minutes: $0.minutes), current: $0.value, proposed: proposed($0.value))
        }
    }

    /// Linear interpolation between neighbouring values of a sorted list.
    static func percentile(_ sorted: [Decimal], _ p: Double) -> Decimal? {
        guard !sorted.isEmpty else { return nil }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = Decimal(position - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    static func round(_ value: Decimal, step: Decimal) -> Decimal {
        var scaled = value / step
        var result = Decimal()
        NSDecimalRound(&result, &scaled, 0, .plain)
        return result * step
    }

    static func clamp(_ value: Decimal) -> Decimal {
        min(max(value, factorRange.lowerBound), factorRange.upperBound)
    }

    /// "06:30" → 390.
    static func minutes(fromClock text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func schedule(_ items: [TherapyReportSettings.ScheduleItem]) -> [SensitivityReport.ScheduleEntry] {
        items.compactMap { item in minutes(fromClock: item.start).map { .init(minutes: $0, value: item.value) } }
    }
}
