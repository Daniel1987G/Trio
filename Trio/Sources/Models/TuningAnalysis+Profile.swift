import Foundation

extension TuningAnalysis {
    /// A profile with the suggested factors applied: entries split at the block edges, scaled,
    /// rounded (basal to the pump's 0.05 U/h, ISF to 1 mg/dL, carb ratio to 0.1 g) and merged again.
    static func proposedProfile(from current: ProfileSnapshot, report: Report, name: String) -> ProfileSnapshot {
        var proposed = current
        proposed.id = UUID()
        proposed.name = name
        proposed.created = Date()
        proposed.origin = .manual

        let basalFactors = report.basal.compactMap { block in
            block.suggestion.factor.map { (range: block.startHour * 60 ..< block.endHour * 60, factor: $0) }
        }
        let basal = scaled(
            current.basalProfile.map { (minutes: $0.minutes, value: $0.rate) },
            factors: basalFactors,
            step: Decimal(string: "0.05")!
        )
        proposed.basalProfile = basal.map {
            BasalProfileEntry(start: clock($0.minutes), minutes: $0.minutes, rate: $0.value)
        }

        if let factor = report.isf.factor {
            let isf = scaled(
                current.insulinSensitivities.sensitivities.map { (minutes: $0.offset, value: $0.sensitivity) },
                factors: [(range: 0 ..< 1440, factor: factor)],
                step: current.insulinSensitivities.units == .mmolL ? Decimal(string: "0.1")! : 1
            )
            proposed.insulinSensitivities.sensitivities = isf.map {
                InsulinSensitivityEntry(sensitivity: $0.value, offset: $0.minutes, start: clock($0.minutes))
            }
        }

        let ratioFactors = report.carbRatio.flatMap { block -> [(range: Range<Int>, factor: Decimal)] in
            guard let factor = block.suggestion.factor else { return [] }
            // evening runs past midnight: 16–24 and 0–5
            if block.endHour < block.startHour {
                return [(block.startHour * 60 ..< 1440, factor), (0 ..< block.endHour * 60, factor)]
            }
            return [(block.startHour * 60 ..< block.endHour * 60, factor)]
        }
        let ratios = scaled(
            current.carbRatios.schedule.map { (minutes: $0.offset, value: $0.ratio) },
            factors: ratioFactors,
            step: Decimal(string: "0.1")!
        )
        proposed.carbRatios = CarbRatios(
            units: current.carbRatios.units,
            schedule: ratios.map { CarbRatioEntry(start: clock($0.minutes), offset: $0.minutes, ratio: $0.value) }
        )
        return proposed
    }

    /// Splits the schedule at the ranges' edges, multiplies the values inside, rounds and merges
    /// neighbours with the same value. Edges are kept on whole half hours (Omnipod segments).
    static func scaled(
        _ schedule: [(minutes: Int, value: Decimal)],
        factors: [(range: Range<Int>, factor: Decimal)],
        step: Decimal
    ) -> [(minutes: Int, value: Decimal)] {
        let sorted = schedule.sorted { $0.minutes < $1.minutes }
        guard !sorted.isEmpty, !factors.isEmpty else { return sorted }
        func valueAt(_ minute: Int) -> Decimal {
            sorted.last { $0.minutes <= minute }?.value ?? sorted[0].value
        }
        var edges = Set(sorted.map(\.minutes))
        edges.insert(0)
        for item in factors {
            edges.insert(item.range.lowerBound)
            if item.range.upperBound < 1440 { edges.insert(item.range.upperBound) }
        }
        var result: [(minutes: Int, value: Decimal)] = []
        for edge in edges.sorted() where edge < 1440 {
            var value = valueAt(edge)
            if let factor = factors.first(where: { $0.range.contains(edge) })?.factor {
                value = round(value * factor, step: step)
                if value < step { value = step }
            }
            if let last = result.last, last.value == value { continue }
            result.append((edge, value))
        }
        return result
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }
}
