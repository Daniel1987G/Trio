import Foundation
import Testing
@testable import Trio

@Suite("AI therapy report") struct TherapyReportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Midnight UTC.
    private let start = Date(timeIntervalSinceReferenceDate: 799_977_600)

    private func readings(_ values: [Int], from: Date, step: TimeInterval = 300) -> [TherapyReportInput.Glucose] {
        values.enumerated().map { .init(date: from.addingTimeInterval(Double($0.offset) * step), mgdl: $0.element) }
    }

    @Test("Time in ranges and mean") func ranges() {
        let glucose = readings([50, 60, 100, 120, 150, 200, 300, 100, 100, 100], from: start)
        let stats = TherapyReportBuilder.glucoseStats(glucose, periodSeconds: 10 * 300)
        #expect(stats.veryLowPercent == 10)
        #expect(stats.lowPercent == 10)
        #expect(stats.inRangePercent == 60)
        #expect(stats.tightRangePercent == 50)
        #expect(stats.highPercent == 10)
        #expect(stats.veryHighPercent == 10)
        #expect(stats.meanMgdl == 128)
        #expect(stats.coveragePercent == 100)
    }

    @Test("A hypo needs 15 minutes below 70") func hypoMinimum() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(86400))
        // 10 minutes low (two readings), then 20 minutes low (four readings, nadir 52)
        input.glucose = readings([100, 65, 66, 90, 100, 68, 60, 52, 61, 80], from: start.addingTimeInterval(8 * 3600))
        let hypos = TherapyReportBuilder.hypoEpisodes(input.glucose, input: input, calendar: calendar)
        #expect(hypos.count == 1)
        #expect(hypos.first?.minutes == 20)
        #expect(hypos.first?.nadirMgdl == 52)
        #expect(hypos.first?.severe == true)
        #expect(hypos.first?.startTime == "08:25")
        #expect(hypos.first?.day == 1)
    }

    @Test("A sensor gap ends a hypo") func hypoGap() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(86400))
        let first = readings([60, 60, 60], from: start)
        let later = readings([60, 100], from: start.addingTimeInterval(3600))
        input.glucose = first + later
        let hypos = TherapyReportBuilder.hypoEpisodes(input.glucose, input: input, calendar: calendar)
        // 3 readings = 10 min + 5 min after the last one = 15 min; the later one is only 5 min
        #expect(hypos.map(\.minutes) == [15])
    }

    @Test("Hypo context: insulin and carbs before, active adjustment") func hypoContext() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(86400))
        let hypoStart = start.addingTimeInterval(12 * 3600)
        input.glucose = readings([65, 60, 62, 64, 90], from: hypoStart)
        input.boluses = [
            .init(date: hypoStart.addingTimeInterval(-90 * 60), units: 4, isSMB: false, isExternal: false),
            .init(date: hypoStart.addingTimeInterval(-30 * 60), units: Decimal(string: "0.4")!, isSMB: true, isExternal: false),
            .init(date: hypoStart.addingTimeInterval(-3 * 3600), units: 2, isSMB: false, isExternal: false)
        ]
        input.carbs = [.init(date: hypoStart.addingTimeInterval(-100 * 60), grams: 40, isEquivalent: false)]
        input.adjustments = [.init(
            kind: .override,
            name: "Sport",
            start: hypoStart.addingTimeInterval(-600),
            end: hypoStart.addingTimeInterval(3600)
        )]
        let hypo = TherapyReportBuilder.hypoEpisodes(input.glucose, input: input, calendar: calendar).first
        #expect(hypo?.manualBolusUnitsPrev2h == 4)
        #expect(hypo?.smbUnitsPrev2h == Decimal(string: "0.4")!)
        #expect(hypo?.carbsPrev3h == 40)
        #expect(hypo?.activeAdjustment == "override: Sport")
    }

    @Test("Loop runs, success and gaps") func loop() {
        let runs = (0 ..< 10).map { index in
            TherapyReportInput.LoopRun(
                date: start.addingTimeInterval(Double(index) * 300 + (index >= 5 ? 1200 : 0)),
                succeeded: index != 3
            )
        }
        let stats = TherapyReportBuilder.loopStats(runs, dayCount: 1)
        #expect(stats.successPercent == 90)
        #expect(stats.gapsOver15Min == 1)
        #expect(stats.longestGapMinutes == 25)
    }

    @Test("A temp basal ends at its duration or at the next temp") func activeTemp() {
        let temps: [TherapyReportInput.TempBasal] = [
            .init(date: start, rate: 2, minutes: 30),
            .init(date: start.addingTimeInterval(20 * 60), rate: 0, minutes: 30)
        ]
        #expect(TherapyReportBuilder.activeTemp(at: start.addingTimeInterval(10 * 60), temps: temps)?.rate == 2)
        #expect(TherapyReportBuilder.activeTemp(at: start.addingTimeInterval(25 * 60), temps: temps)?.rate == 0)
        #expect(TherapyReportBuilder.activeTemp(at: start.addingTimeInterval(55 * 60), temps: temps) == nil)
        #expect(TherapyReportBuilder.activeTemp(at: start.addingTimeInterval(-60), temps: temps) == nil)
    }

    @Test("Basal by hour compares delivered with scheduled") func basalByHour() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(2 * 3600))
        input.basalProfile = [(minutes: 0, rate: 1)]
        // whole first hour at 2 U/h, second hour scheduled
        input.tempBasals = [.init(date: start, rate: 2, minutes: 60)]
        let hours = TherapyReportBuilder.basalByHour(input, calendar: calendar)
        #expect(hours.first { $0.hour == 0 }?.ratio == 2)
        #expect(hours.first { $0.hour == 1 }?.ratio == 1)

        let insulin = TherapyReportBuilder.insulinStats(input, dayCount: 1, calendar: calendar)
        #expect(insulin.tddMean == 3)
        #expect(insulin.basalPercent == 100)
    }

    @Test("Prompt carries the period, the language and the data") func prompt() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(14 * 86400))
        input.glucose = readings([120, 130], from: start)
        let report = TherapyReportBuilder.build(input, settings: nil, calendar: calendar)
        let prompt = report.prompt(languageCode: "de")
        #expect(report.periodDays == 14)
        #expect(prompt.contains("last 14 days"))
        #expect(prompt.contains("ISO code \"de\""))
        #expect(prompt.contains("\"periodDays\" : 14"))
        #expect(!prompt.contains("only 14 days"))

        var short = TherapyReportInput(start: start, end: start.addingTimeInterval(3 * 86400))
        short.glucose = readings([120, 130], from: start)
        let shortPrompt = TherapyReportBuilder.build(short, settings: nil, calendar: calendar).prompt(languageCode: "de")
        #expect(shortPrompt.contains("The period is only 3 days"))
    }

    @Test("Each topic sends only its parts") func topicParts() {
        var input = TherapyReportInput(start: start, end: start.addingTimeInterval(86400))
        input.glucose = readings([120, 60, 60, 60, 120], from: start)
        let report = TherapyReportBuilder.build(input, settings: nil, calendar: calendar)

        let hypos = report.summaryJSON(for: .hypos)
        #expect(hypos.contains("\"hypos\""))
        #expect(!hypos.contains("\"basalByHour\""))
        #expect(!hypos.contains("\"loop\""))

        let loop = report.summaryJSON(for: .loop)
        #expect(loop.contains("\"loop\""))
        #expect(!loop.contains("\"hypos\""))

        let overall = report.summaryJSON(for: .overall)
        for part in TherapyReport.Part.allCases
            where part != .sensitivityRatio && part != .sensitivityByTime && part != .settings
        {
            #expect(overall.contains("\"\(part.rawValue)\""))
        }

        let prompt = report.prompt(for: .basal, languageCode: "de")
        #expect(prompt.contains("the topic \"basal\" only"))
        #expect(prompt.contains("Night (0 to 6 o'clock)"))
    }

    @Test("Markdown becomes simple HTML for the printed report") func markdownHTML() {
        let html = TherapyReportDocument.markdownToHTML("## Basal\n- **Night** a < b\n- *day*\n\n1. First\n2. Second\nText")
        #expect(
            html == "<h3>Basal</h3><ul><li><b>Night</b> a &lt; b</li><li><i>day</i></li></ul>" +
                "<ol><li>First</li><li>Second</li></ol><p>Text</p>"
        )
    }
}
