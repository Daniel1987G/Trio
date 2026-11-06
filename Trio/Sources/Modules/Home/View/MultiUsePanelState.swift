import Foundation

/// Content states of the Home multi-use panel; highest priority wins.
enum MultiUsePanelState: Equatable {
    case notificationsDisabled
    case pumpTimeMismatch
    case cgmStale
    /// A running extended bolus, or one that just stopped early (low glucose, expired).
    case extendedBolus(ExtendedBolus)
    case maxIOBZero
    case whatsNew
    case dosingModeLimited(DosingMode)
    case stats

    /// readings older than this offer manual glucose entry
    static let cgmStaleAfter: TimeInterval = 12 * 60
    /// an extended bolus that stopped early stays visible this long
    static let extendedBolusStoppedVisibleFor: TimeInterval = 30 * 60

    static func resolve(
        notificationsDisabled: Bool,
        pumpTimeMismatch: Bool,
        lastGlucoseDate: Date?,
        maxIOB: Decimal,
        hasUnacknowledgedReleaseNotes: Bool,
        dosingMode: DosingMode,
        now: Date,
        extendedBolus: ExtendedBolus? = nil
    ) -> MultiUsePanelState {
        if notificationsDisabled { return .notificationsDisabled }
        if pumpTimeMismatch { return .pumpTimeMismatch }
        if now.timeIntervalSince(lastGlucoseDate ?? .distantPast) > cgmStaleAfter { return .cgmStale }
        if let extendedBolus, showsExtendedBolus(extendedBolus, now: now) { return .extendedBolus(extendedBolus) }
        // constrained modes clamp Max IOB to 0 without touching the stored value
        if dosingMode.automation == .reductionsOnly || dosingMode.automation == .hypoSuspendOnly {
            return .dosingModeLimited(dosingMode)
        }
        if maxIOB <= 0 { return .maxIOBZero }
        // Informational, so it yields to every warning above but still displaces the stats.
        if hasUnacknowledgedReleaseNotes { return .whatsNew }
        return .stats
    }

    static func showsExtendedBolus(_ bolus: ExtendedBolus, now: Date) -> Bool {
        if bolus.isActive { return true }
        guard let endedAt = bolus.endedAt,
              bolus.endReason == .lowGlucose || bolus.endReason == .expired
        else { return false }
        return now.timeIntervalSince(endedAt) < extendedBolusStoppedVisibleFor
    }
}
