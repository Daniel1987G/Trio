import Foundation
import Testing

@testable import Trio

@Suite("Header widget snapshot") struct HeaderWidgetSnapshotTests {
    private func snapshot(units: String) -> HeaderWidgetSnapshot {
        HeaderWidgetSnapshot(
            glucose: 126, glucoseDate: Date(), delta: -4, trendSymbols: ["arrow.down.right"], units: units,
            glucoseColorHex: nil, rangeColorHex: "#34C759", dosingModeName: "Closed Loop", lastLoopDate: Date(),
            loopColorFollowsAge: true, fixedLoopColorHex: nil, loopColorHexes: ["#00FF00", "#FFFF00", "#FF0000"],
            dynamicISFRatio: 1.2, iob: 1.25, cob: 20, eventualGlucose: 110, reservoir: 120, reservoirIsOver50: false,
            pumpExpiresAt: nil, pumpBatteryPercent: nil, pumpMessage: nil, insulinConcentrationBadge: "U200",
            updatedAt: Date()
        )
    }

    @Test("Readings and deltas follow the display unit") func formatting() {
        let mgdl = snapshot(units: "mg/dL")
        #expect(mgdl.formattedGlucose(126) == "126")
        #expect(mgdl.formattedGlucose(400) == "HIGH")
        #expect(mgdl.formattedDelta(-4) == "−4")
        #expect(mgdl.formattedDelta(3) == "+3")

        let mmol = snapshot(units: "mmol/L")
        #expect(mmol.formattedGlucose(126) == String(format: "%.1f", 126 / 18.0182))
        #expect(mmol.formattedDelta(9) == "+" + String(format: "%.1f", 9 / 18.0182))
    }

    @Test("The snapshot survives the trip through the app group") func codable() throws {
        let original = snapshot(units: "mg/dL")
        let decoded = try JSONDecoder().decode(HeaderWidgetSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
