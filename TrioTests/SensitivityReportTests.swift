import Foundation
import Testing

@testable import Trio

private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

@Suite("Sensitivity report") struct SensitivityReportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// A ratio every 5 minutes on `days` days; `ratio(hour)` gives the value per hour of day.
    private func samples(days: Int, ratio: (Int) -> Decimal) -> [(date: Date, ratio: Decimal)] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        var result: [(date: Date, ratio: Decimal)] = []
        for day in 0 ..< days {
            for step in 0 ..< 288 {
                let date = start.addingTimeInterval(Double(day) * 86400 + Double(step) * 300)
                result.append((date: date, ratio: ratio(calendar.component(.hour, from: date))))
            }
        }
        return result
    }

    private let basal: [SensitivityReport.ScheduleEntry] = [.init(minutes: 0, value: dec("0.8")), .init(minutes: 240, value: 1.0)]
    private let isf: [SensitivityReport.ScheduleEntry] = [.init(minutes: 0, value: 50)]
    private let carbRatio: [SensitivityReport.ScheduleEntry] = [.init(minutes: 0, value: 10)]

    private func build(_ samples: [(date: Date, ratio: Decimal)], days: Int) -> SensitivityReport {
        SensitivityReportBuilder.build(
            samples: samples,
            periodDays: days,
            basal: basal,
            isfMgdl: isf,
            carbRatio: carbRatio,
            isDynamicISF: false,
            calendar: calendar
        )
    }

    @Test("A stable resistant block gets a factor and profile suggestions") func resistantBlock() throws {
        let report = build(samples(days: 7) { $0 >= 3 && $0 < 6 ? dec("1.2") : 1 }, days: 7)
        let block = try #require(report.blocks.first { $0.startHour == 3 })
        #expect(block.verdict == .resistant)
        #expect(block.factor == dec("1.2"))
        // basal entries running in 03-06: 0.8 from 03:00 and 1.0 from 04:00
        #expect(block.basal.map(\.proposed) == [dec("0.95"), dec("1.2")])
        #expect(block.basal.map(\.start) == ["03:00", "04:00"])
        #expect(block.isfMgdl.first?.proposed == 42) // 50 / 1.2 = 41.7
        #expect(block.carbRatio.first?.proposed == dec("8.3")) // 10 / 1.2
        #expect(report.suggestions.count == 1)
        #expect(report.blocks.first { $0.startHour == 0 }?.verdict == .unremarkable)
    }

    @Test("A sensitive block is suggested the other way") func sensitiveBlock() throws {
        let report = build(samples(days: 7) { $0 >= 12 && $0 < 15 ? dec("0.85") : 1 }, days: 7)
        let block = try #require(report.blocks.first { $0.startHour == 12 })
        #expect(block.verdict == .sensitive)
        #expect(block.factor == dec("0.85"))
        #expect(block.isfMgdl.first?.proposed == 59) // 50 / 0.85 = 58.8
    }

    @Test("Small or short-lived deviations give no suggestion") func noSuggestion() {
        // 5 % is below the threshold
        #expect(build(samples(days: 7) { _ in dec("1.05") }, days: 7).suggestions.isEmpty)
        // a single resistant day in a 7-day period: the median stays at 1
        let mixed = samples(days: 7) { _ in 1 }.enumerated().map { index, sample in
            (date: sample.date, ratio: index < 288 ? dec("1.3") : sample.ratio)
        }
        #expect(build(mixed, days: 7).suggestions.isEmpty)
    }

    @Test("Too few days are reported as insufficient") func insufficientData() {
        let report = build(samples(days: 2) { _ in dec("1.3") }, days: 7)
        #expect(report.blocks.allSatisfy { $0.verdict == .insufficientData })
        #expect(SensitivityReportBuilder.minimumDays(for: 7) == 4)
        #expect(SensitivityReportBuilder.minimumDays(for: 3) == 2)
    }

    @Test("Suggestions stay within the autosens range") func clamped() throws {
        let report = build(samples(days: 7) { _ in dec("1.6") }, days: 7)
        #expect(report.blocks.allSatisfy { $0.factor == dec("1.3") })
    }
}
