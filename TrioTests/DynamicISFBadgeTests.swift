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
}
