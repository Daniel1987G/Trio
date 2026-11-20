import Foundation
import Testing
@testable import Trio

@Suite("Falling guard") struct FallingGuardTests {
    private func fall(
        enabled: Bool = true,
        threshold: Decimal = 35,
        delta: Decimal,
        shortAvgDelta: Decimal,
        bgi: Decimal
    ) -> Decimal? {
        FallingGuard.unexplainedFall(
            enabled: enabled,
            thresholdMgdlPerHour: threshold,
            delta: delta,
            shortAvgDelta: shortAvgDelta,
            glucoseImpact: bgi
        )
    }

    @Test("falling as the insulin explains: no action") func explainedFall() {
        // BGI -3 per 5 min, glucose falls 3 per 5 min
        #expect(fall(delta: -3, shortAvgDelta: -3, bgi: -3) == nil)
    }

    @Test("falling 5 per 5 min with no insulin effect triggers at 35 mg/dL/h") func unexplainedFall() {
        // (-5 - 0) * 12 = -60 < -35
        #expect(fall(delta: -5, shortAvgDelta: -4, bgi: 0) == -48)
    }

    @Test("both windows must agree") func needsBothWindows() {
        // a single steep 5-minute drop, flat on average
        #expect(fall(delta: -8, shortAvgDelta: -1, bgi: 0) == nil)
        // falling on average, but the latest reading already turned
        #expect(fall(delta: -1, shortAvgDelta: -6, bgi: 0) == nil)
    }

    @Test("glucose must be falling") func notFalling() {
        // rising slower than the insulin should allow: no trigger without a fall
        #expect(fall(delta: 1, shortAvgDelta: 1, bgi: 5) == nil)
    }

    @Test("off and threshold") func offAndThreshold() {
        #expect(fall(enabled: false, delta: -10, shortAvgDelta: -10, bgi: 0) == nil)
        #expect(fall(threshold: 80, delta: -5, shortAvgDelta: -5, bgi: 0) == nil)
        #expect(fall(threshold: 0, delta: -10, shortAvgDelta: -10, bgi: 0) == nil)
    }

    @Test("a high temp running with negative BGI is subtracted") func bgiSubtracted() {
        // BGI -2, glucose -4: unexplained -2 per 5 min = -24/h, below the limit
        #expect(fall(delta: -4, shortAvgDelta: -4, bgi: -2) == nil)
        // BGI -1, glucose -5: unexplained -4 per 5 min = -48/h
        #expect(fall(delta: -5, shortAvgDelta: -5, bgi: -1) == -48)
    }
}
