import Foundation
import Testing
@testable import Trio

@Suite("Saved profiles") struct ProfileSnapshotTests {
    private func snapshot(
        basal: [(Int, String)] = [(0, "0.8"), (360, "1.2"), (1320, "0.9")],
        isf: [(Int, String)] = [(0, "45"), (720, "50")],
        ratios: [(Int, String)] = [(0, "10"), (660, "12")]
    ) -> ProfileSnapshot {
        func clock(_ minutes: Int) -> String { String(format: "%02d:%02d:00", minutes / 60, minutes % 60) }
        return ProfileSnapshot(
            id: UUID(),
            name: "Test",
            created: Date(timeIntervalSince1970: 1_800_000_000),
            origin: .manual,
            basalProfile: basal.map { BasalProfileEntry(start: clock($0.0), minutes: $0.0, rate: Decimal(string: $0.1)!) },
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: isf.map {
                    InsulinSensitivityEntry(sensitivity: Decimal(string: $0.1)!, offset: $0.0, start: clock($0.0))
                }
            ),
            carbRatios: CarbRatios(
                units: .grams,
                schedule: ratios.map { CarbRatioEntry(start: clock($0.0), offset: $0.0, ratio: Decimal(string: $0.1)!) }
            )
        )
    }

    @Test("Daily basal adds every rate over its time") func dailyBasal() {
        // 0.8 × 6 h + 1.2 × 16 h + 0.9 × 2 h = 4.8 + 19.2 + 1.8
        #expect(snapshot().dailyBasal == Decimal(string: "25.8")!)
        #expect(snapshot(basal: [(0, "1")]).dailyBasal == 24)
    }

    @Test("Ranges of ISF and carb ratio") func ranges() {
        #expect(snapshot().isfRange == 45 ... 50)
        #expect(snapshot().carbRatioRange == 10 ... 12)
    }

    @Test("Differences per part, independent of order and id") func differences() {
        let a = snapshot()
        var b = snapshot(basal: [(1320, "0.9"), (0, "0.8"), (360, "1.2")])
        b.name = "Other"
        #expect(a.hasSameValues(as: b))

        let changedBasal = snapshot(basal: [(0, "0.8"), (360, "1.25"), (1320, "0.9")])
        #expect(a.differences(from: changedBasal) == .init(basal: true, isf: false, carbRatio: false))
        let changedISF = snapshot(isf: [(0, "45")])
        #expect(a.differences(from: changedISF) == .init(basal: false, isf: true, carbRatio: false))
        let changedCR = snapshot(ratios: [(0, "10"), (660, "11")])
        #expect(a.differences(from: changedCR).carbRatio)
        #expect(a.differences(from: changedCR).any)
    }

    @Test("Saved profiles survive encoding") func codable() throws {
        let saved = [snapshot()]
        let data = try JSONCoding.encoder.encode(saved)
        let loaded = try JSONCoding.decoder.decode([ProfileSnapshot].self, from: data)
        #expect(loaded == saved)
    }
}
