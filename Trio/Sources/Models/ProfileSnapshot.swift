import Foundation

/// A saved copy of the therapy profile — basal rates, ISF and carb ratios — to go back to after
/// trying changes. Values are stored as Trio keeps them on disk (mg/dL, actual insulin units).
struct ProfileSnapshot: JSON, Identifiable, Equatable {
    enum Origin: String, JSON {
        /// Saved by the user.
        case manual
        /// Saved automatically right before another profile was restored.
        case beforeRestore
    }

    var id: UUID
    var name: String
    var created: Date
    var origin: Origin
    var basalProfile: [BasalProfileEntry]
    var insulinSensitivities: InsulinSensitivities
    var carbRatios: CarbRatios

    static func == (lhs: ProfileSnapshot, rhs: ProfileSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.created == rhs.created && lhs.origin == rhs.origin &&
            lhs.hasSameValues(as: rhs)
    }

    // MARK: - Summary

    /// Total basal over 24 hours, in units.
    var dailyBasal: Decimal { Self.dailyTotal(basalProfile) }

    static func dailyTotal(_ profile: [BasalProfileEntry]) -> Decimal {
        let sorted = profile.sorted { $0.minutes < $1.minutes }
        var total: Decimal = 0
        for (index, entry) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].minutes : 24 * 60
            total += entry.rate * Decimal(max(end - entry.minutes, 0)) / 60
        }
        return total
    }

    /// Lowest and highest ISF in mg/dL per unit.
    var isfRange: ClosedRange<Decimal>? {
        Self.range(insulinSensitivities.sensitivities.map(\.sensitivity))
    }

    /// Lowest and highest carb ratio in g per unit.
    var carbRatioRange: ClosedRange<Decimal>? {
        Self.range(carbRatios.schedule.map(\.ratio))
    }

    static func range(_ values: [Decimal]) -> ClosedRange<Decimal>? {
        guard let low = values.min(), let high = values.max() else { return nil }
        return low ... high
    }

    // MARK: - Comparison

    /// Which parts differ from another profile (e.g. the current one).
    struct Differences: Equatable {
        var basal: Bool
        var isf: Bool
        var carbRatio: Bool

        var any: Bool { basal || isf || carbRatio }
    }

    func differences(from other: ProfileSnapshot) -> Differences {
        Differences(
            basal: Self.basalKey(basalProfile) != Self.basalKey(other.basalProfile),
            isf: Self.isfKey(insulinSensitivities) != Self.isfKey(other.insulinSensitivities),
            carbRatio: Self.carbRatioKey(carbRatios) != Self.carbRatioKey(other.carbRatios)
        )
    }

    func hasSameValues(as other: ProfileSnapshot) -> Bool {
        !differences(from: other).any
    }

    private static func basalKey(_ profile: [BasalProfileEntry]) -> [String] {
        profile.sorted { $0.minutes < $1.minutes }.map { "\($0.minutes)=\($0.rate)" }
    }

    private static func isfKey(_ isf: InsulinSensitivities) -> [String] {
        isf.sensitivities.sorted { $0.offset < $1.offset }.map { "\($0.offset)=\($0.sensitivity)" }
    }

    private static func carbRatioKey(_ ratios: CarbRatios) -> [String] {
        ratios.schedule.sorted { $0.offset < $1.offset }.map { "\($0.offset)=\($0.ratio)" }
    }
}

/// Errors of saving and restoring profiles.
enum ProfileSnapshotError: LocalizedError {
    case incompleteProfile
    case notFound

    var errorDescription: String? {
        switch self {
        case .incompleteProfile:
            return String(
                localized: "Basal rates, ISF and carb ratios must all be set before the profile can be saved.",
                comment: "Profile snapshot error"
            )
        case .notFound:
            return String(localized: "This profile no longer exists.", comment: "Profile snapshot error")
        }
    }
}
