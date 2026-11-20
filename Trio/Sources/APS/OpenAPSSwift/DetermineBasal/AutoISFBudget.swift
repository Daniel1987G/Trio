import Foundation

/// Caps the insulin autoISF (ISF adaptation, SMB control and B30) may give beyond plain oref.
///
/// After GlucOS's budget for machine-learning doses (King et al., UC Davis): every loop the
/// determination is also computed with autoISF off. A ledger keeps what was programmed next to
/// what plain oref would have done; their difference over the last 3 hours is the extra insulin
/// autoISF gave. A loop whose autoISF dose would take that above the budget — a number of hours
/// of the highest scheduled basal rate — doses as plain oref instead. Doses autoISF reduced count
/// against the tally, down to minus the budget, so less insulin earlier allows more later.
/// A ledger that cannot be read counts as a full budget for the next 3 hours: unknown is not zero.
enum AutoISFBudget {
    static let window: TimeInterval = 3 * 60 * 60

    /// One loop: what was programmed and what plain oref would have done.
    struct Entry: Codable, Equatable {
        let date: Date
        /// U/h the pump runs after this loop, programmed and plain oref.
        let rate: Decimal
        let plainRate: Decimal
        /// SMB in U, programmed and plain oref.
        let smb: Decimal
        let plainSMB: Decimal
        /// How long the programmed rate runs at most, minutes.
        let minutes: Decimal
    }

    struct Ledger: JSON, Equatable {
        /// Set when an unreadable ledger was replaced: the tally before this is unknown.
        var reset: Date?
        var entries: [Entry] = []
    }

    /// What one determination makes the pump do: its temp, or the running temp or scheduled basal
    /// when it changes nothing, and its SMB.
    struct Dose: Equatable {
        let rate: Decimal
        let minutes: Decimal
        let smb: Decimal

        init(rate: Decimal, minutes: Decimal, smb: Decimal) {
            self.rate = rate
            self.minutes = minutes
            self.smb = smb
        }

        init(_ determination: Determination, currentTemp: TempBasal, scheduledBasal: Decimal) {
            if let rate = determination.rate, let duration = determination.duration, duration > 0 {
                self.init(rate: rate, minutes: min(duration, 30), smb: determination.units ?? 0)
            } else if currentTemp.duration > 0 {
                self.init(rate: currentTemp.rate, minutes: min(Decimal(currentTemp.duration), 30), smb: determination.units ?? 0)
            } else {
                self.init(rate: scheduledBasal, minutes: 30, smb: determination.units ?? 0)
            }
        }
    }

    enum Verdict: Equatable {
        /// autoISF may dose; `used` is the extra insulin including this loop.
        case allowed(used: Decimal)
        /// Over the budget (or the ledger is unknown): dose as plain oref.
        case exceeded(used: Decimal)
    }

    /// Hours of the highest scheduled basal rate, in U.
    static func budget(basalProfile: [BasalProfileEntry], hours: Decimal) -> Decimal {
        (basalProfile.map(\.rate).max() ?? 0) * hours
    }

    /// Extra insulin autoISF gave within the window before `now`, in U.
    static func extraInsulin(_ entries: [Entry], now: Date) -> Decimal {
        let start = now.addingTimeInterval(-window)
        let sorted = entries.sorted { $0.date < $1.date }
        var total: Decimal = 0
        for (index, entry) in sorted.enumerated() where entry.date < now {
            let next = index + 1 < sorted.count ? sorted[index + 1].date : now
            let end = min(next, now, entry.date.addingTimeInterval(NSDecimalNumber(decimal: entry.minutes).doubleValue * 60))
            let from = max(entry.date, start)
            if end > from {
                total += (entry.rate - entry.plainRate) * Decimal(end.timeIntervalSince(from)) / 3600
            }
            if entry.date >= start {
                total += entry.smb - entry.plainSMB
            }
        }
        return total
    }

    static func verdict(ledger: Ledger, now: Date, budget: Decimal, autoISF: Dose, plain: Dose) -> Verdict {
        let past = max(extraInsulin(ledger.entries, now: now), -budget)
        // the temp is counted for its whole duration, as if the next loops kept it
        let tick = (autoISF.rate - plain.rate) * autoISF.minutes / 60 + autoISF.smb - plain.smb
        let used = past + tick
        if let reset = ledger.reset, now.timeIntervalSince(reset) < window, tick > 0 {
            return .exceeded(used: budget + max(tick, 0))
        }
        if tick > 0, used > budget {
            return .exceeded(used: used)
        }
        return .allowed(used: used)
    }

    /// The ledger after this loop, without entries older than the window.
    static func recording(_ entry: Entry, in ledger: Ledger) -> Ledger {
        var ledger = ledger
        let cutoff = entry.date.addingTimeInterval(-window - 3600)
        ledger.entries = ledger.entries.filter { $0.date >= cutoff } + [entry]
        if let reset = ledger.reset, entry.date.timeIntervalSince(reset) >= window {
            ledger.reset = nil
        }
        return ledger
    }

    /// Adds `tag` to the first part of an oref reason (before "; "), where the loop status lists it.
    static func tagging(_ reason: String, with tag: String) -> String {
        guard let range = reason.range(of: "; ") else { return reason + ", " + tag }
        var tagged = reason
        tagged.insert(contentsOf: ", " + tag, at: range.lowerBound)
        return tagged
    }

    static func tag(used: Decimal, budget: Decimal, exceeded: Bool) -> String {
        let used = max(used, 0).jsRounded(scale: 1)
        let budget = budget.jsRounded(scale: 1)
        return exceeded ? "aISF budget \(used)/\(budget)U: oref" : "aISF budget \(used)/\(budget)U"
    }
}
