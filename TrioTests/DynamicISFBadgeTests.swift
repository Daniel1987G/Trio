import Foundation
import Testing

@testable import Trio

@Suite("Dynamic ISF badge") struct DynamicISFBadgeTests {
    @Test("Ratio above 1 lowers the ISF, below 1 raises it") func direction() {
        // oref: ISF = profile ISF / ratio
        #expect(DynamicISFBadge(ratio: 1.25).changePercent == -20)
        #expect(DynamicISFBadge(ratio: 0.8).changePercent == 25)
        #expect(DynamicISFBadge(ratio: 1).changePercent == 0)
        #expect(DynamicISFBadge(ratio: 1.004).changePercent == 0)
    }

    @Test("autoISF factor 1.5 shows the ISF 33 % lower") func autoISF() {
        #expect(DynamicISFBadge(ratio: Decimal(string: "1.5")!, source: .autoISF).changePercent == -33)
        #expect(DynamicISFBadge(ratio: Decimal(string: "0.7")!, source: .autoISF).changePercent == 43)
    }

    @Test("FCL badge text") func fclBadge() {
        #expect(FCLBadge(preset: .moderate).shortText == "FCL M")
        #expect(FCLBadge(preset: .aggressive, isAdjusted: true).shortText == "FCL A*")
    }
}
