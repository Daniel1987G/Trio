import Foundation

/// Stops insulin when glucose falls much faster than the insulin on board explains.
///
/// After GlucOS's "biological invariant" (King et al., UC Davis): oref's glucose impact (BGI) is
/// what the active insulin should do to glucose in 5 minutes. When glucose drops far faster than
/// that, something the loop does not know about is lowering it — exercise without an override,
/// insulin delivered twice, the wrong ISF — and the forecasts built on the same insulin model are
/// too optimistic. Both the latest 5-minute change and the ~15-minute average must show the fall,
/// so a single noisy reading cannot trigger it, and glucose has to be falling.
enum FallingGuard {
    /// How long the zero temp runs; the guard is checked again every loop.
    static let suspendMinutes: Decimal = 30

    /// The unexplained fall in mg/dL per hour (negative) when the guard should stop insulin, else nil.
    ///
    /// - Parameters:
    ///   - delta: glucose change over the last 5 minutes, mg/dL
    ///   - shortAvgDelta: average 5-minute change over about 15 minutes, mg/dL
    ///   - glucoseImpact: oref's BGI, the change the active insulin explains per 5 minutes, mg/dL
    ///   - thresholdMgdlPerHour: positive; e.g. 35 stops at an unexplained fall of 35 mg/dL/h
    static func unexplainedFall(
        enabled: Bool,
        thresholdMgdlPerHour: Decimal,
        delta: Decimal,
        shortAvgDelta: Decimal,
        glucoseImpact: Decimal
    ) -> Decimal? {
        guard enabled, thresholdMgdlPerHour > 0, delta < 0 else { return nil }
        let recent = (delta - glucoseImpact) * 12
        let average = (shortAvgDelta - glucoseImpact) * 12
        // the smaller of the two falls is what both readings agree on
        let fall = max(recent, average)
        return fall < -thresholdMgdlPerHour ? fall : nil
    }

    static func reason(fall: Decimal, threshold: Decimal) -> String {
        "Falling guard: glucose \(fall.jsRounded()) mg/dL/h beyond insulin (limit -\(threshold.jsRounded())), insulin stopped; "
    }
}
