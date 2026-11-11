import Foundation

/// User settings of the rescue carbs button (UserDefaults; included in settings backups).
///
/// Rescue carbs are logged outside of Trio's carb entries on purpose: they never enter COB, so the
/// algorithm does not dose insulin for them once glucose rises again.
enum RescueCarbSettings {
    static let gramsKey = "rescueCarbs.grams"
    static let tempTargetEnabledKey = "rescueCarbs.tempTargetEnabled"
    static let tempTargetKey = "rescueCarbs.tempTargetMgdL"
    static let durationKey = "rescueCarbs.tempTargetMinutes"

    /// Keys copied into and out of settings backups.
    static let backupKeys = [gramsKey, tempTargetEnabledKey, tempTargetKey, durationKey]

    static let gramsRange = 5 ... 60
    static let defaultGrams = 15
    /// mg/dL
    static let tempTargetRange = 100 ... 200
    static let defaultTempTarget = 140
    static let durationRange = 15 ... 240
    static let defaultDuration = 60

    static var defaults: UserDefaults = .standard

    static var grams: Int {
        get { value(gramsKey, default: defaultGrams, in: gramsRange) }
        set { defaults.set(newValue.clamped(to: gramsRange), forKey: gramsKey) }
    }

    static var tempTargetEnabled: Bool {
        get { defaults.object(forKey: tempTargetEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: tempTargetEnabledKey) }
    }

    /// Temp target in mg/dL.
    static var tempTarget: Int {
        get { value(tempTargetKey, default: defaultTempTarget, in: tempTargetRange) }
        set { defaults.set(newValue.clamped(to: tempTargetRange), forKey: tempTargetKey) }
    }

    /// Temp target duration in minutes.
    static var duration: Int {
        get { value(durationKey, default: defaultDuration, in: durationRange) }
        set { defaults.set(newValue.clamped(to: durationRange), forKey: durationKey) }
    }

    private static func value(_ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key).clamped(to: range)
    }
}

/// One use of the rescue carbs button, kept in a small local log.
struct RescueCarbEntry: JSON, Equatable {
    let date: Date
    let grams: Int
}

enum RescueCarbs {
    static let maxLogEntries = 50

    /// Text of the Nightscout note.
    static func noteText(grams: Int) -> String {
        String(localized: "Rescue carbs \(grams) g", comment: "Nightscout note for rescue carbs")
    }

    /// An active temp target at least as high as the rescue target is left running: replacing it
    /// would lower the target right after a low.
    static func keepsActiveTempTarget(activeTarget: Decimal?, rescueTarget: Decimal) -> Bool {
        guard let activeTarget, activeTarget > 0 else { return false }
        return activeTarget >= rescueTarget
    }

    /// Log with the new entry appended, oldest dropped beyond `maxLogEntries`.
    static func appending(_ entry: RescueCarbEntry, to log: [RescueCarbEntry]) -> [RescueCarbEntry] {
        Array((log + [entry]).suffix(maxLogEntries))
    }

    /// The most recent entry within `window`, to warn before treating twice.
    static func recent(in log: [RescueCarbEntry], now: Date, window: TimeInterval = 2 * 60 * 60) -> RescueCarbEntry? {
        log.filter { $0.date <= now && now.timeIntervalSince($0.date) < window }.max { $0.date < $1.date }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
