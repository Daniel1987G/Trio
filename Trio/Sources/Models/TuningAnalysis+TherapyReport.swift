import Foundation

extension TuningAnalysis {
    /// The analysis from the report's data and the stored settings.
    static func build(
        from input: TherapyReportInput,
        settings: TherapyReportSettings,
        calendar: Calendar = .current
    ) -> Report {
        build(analysisInput(input, settings: settings), autoISF: autoISFSettings(settings.preferences), calendar: calendar)
    }

    static func analysisInput(_ input: TherapyReportInput, settings: TherapyReportSettings) -> Input {
        func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
        func schedule(_ items: [TherapyReportSettings.ScheduleItem]) -> [Input.ScheduleEntry] {
            items.compactMap { item in
                SensitivityReportBuilder.minutes(fromClock: item.start).map { .init(minutes: $0, value: double(item.value)) }
            }
        }

        var result = Input(start: input.start, end: input.end)
        result.readings = input.glucose.map { .init(date: $0.date, mgdl: Double($0.mgdl)) }
        result.doses = input.boluses.map { .init(date: $0.date, units: double($0.units), isSMB: $0.isSMB) }
        result.temps = input.tempBasals.sorted { $0.date < $1.date }
            .map { .init(date: $0.date, rate: double($0.rate), minutes: $0.minutes) }
        result.carbs = input.carbs.map { .init(date: $0.date, grams: double($0.grams), isEquivalent: $0.isEquivalent) }
        result.excluded = input.adjustments.map { .init(start: $0.start, end: $0.end) }
        result.autoISF = input.autoISFFactors
        result.basal = input.basalProfile.map { .init(minutes: $0.minutes, value: double($0.rate)) }
        result.isf = schedule(settings.isfMgdlPerUnit)
        result.carbRatio = schedule(settings.carbRatioGramsPerUnit)
        if !settings.targets.isEmpty {
            result.targetMgdl = settings.targets.map { double($0.lowMgdl) }.reduce(0, +) / Double(settings.targets.count)
        }
        if let dia = settings.diaHours, dia > 0 { result.diaHours = double(dia) }
        if let preferences = settings.preferences {
            if preferences.useCustomPeakTime, preferences.insulinPeakTime > 0 {
                result.peakMinutes = double(preferences.insulinPeakTime)
            } else if preferences.curve == .ultraRapid {
                result.peakMinutes = 55
            }
        }
        return result
    }

    static func autoISFSettings(_ preferences: Preferences?) -> AutoISFSettings? {
        guard let preferences else { return nil }
        return AutoISFSettings(
            enabled: preferences.autoisf && !preferences.useNewFormula,
            bgAccel: preferences.bgAccelISFweight,
            bgBrake: preferences.bgBrakeISFweight,
            pp: preferences.postMealISFweight,
            dura: preferences.autoISFhourlyChange,
            autoISFmax: preferences.autoISFmax
        )
    }
}
