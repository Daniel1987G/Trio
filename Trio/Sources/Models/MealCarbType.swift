import Foundation

/// How fast a meal raises glucose, and which bolus strategy fits it.
///
/// The fat-protein strategies follow the FPU concept (Pańkowska): 1 FPU = 100 kcal from fat and
/// protein; per FPU about as much insulin as per carb unit (10 g), starting with a share of that
/// (default 50 %) to avoid lows. The extended part runs longer the more FPU the meal has.
enum MealCarbType: String, CaseIterable, Identifiable, Codable {
    case standard
    case fast
    case medium
    case slow
    case fatProteinRich
    case fatProteinOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "No Selection", comment: "Meal carb type")
        case .fast: return String(localized: "Fast Carbs", comment: "Meal carb type")
        case .medium: return String(localized: "Medium Carbs", comment: "Meal carb type")
        case .slow: return String(localized: "Slow / High-Fibre Carbs", comment: "Meal carb type")
        case .fatProteinRich: return String(localized: "Rich in Fat and Protein", comment: "Meal carb type")
        case .fatProteinOnly: return String(localized: "Fat/Protein Almost Without Carbs", comment: "Meal carb type")
        }
    }

    var examples: String {
        switch self {
        case .standard: return ""
        case .fast: return String(localized: "Dextrose, juice, soft drinks, white bread, cornflakes")
        case .medium: return String(localized: "Mixed bread, rice, potatoes, fruit")
        case .slow: return String(localized: "Wholegrain, oats, pulses, pasta al dente")
        case .fatProteinRich: return String(localized: "Pizza, burger, pasta with cream sauce, raclette, döner, crisps")
        case .fatProteinOnly: return String(localized: "Steak with salad, cheese platter")
        }
    }

    /// Effect on glucose and the strategy, as shown to the user.
    var strategy: String {
        switch self {
        case .standard:
            return ""
        case .fast:
            return String(
                localized: "Very fast, steep rise. Normal bolus, often with a pre-bolus interval of 10–30 min depending on your current glucose; no extended part."
            )
        case .medium:
            return String(localized: "Rise within 1–2 hours. Usually a normal bolus.")
        case .slow:
            return String(
                localized: "Delayed, flatter rise. Shorter or no pre-bolus interval; possibly a dual bolus with a small extended part (e.g. 70/30 over 1–2 hours)."
            )
        case .fatProteinRich:
            return String(
                localized: "Moderate at first, then a later rise after 3–6 hours. Dual bolus: the bolus for the carbs now, the fat-protein part extended."
            )
        case .fatProteinOnly:
            return String(localized: "Later, slow rise. Possibly only an extended bolus for the FPU.")
        }
    }

    /// Whether the type pre-selects an extended bolus.
    var usesExtendedBolus: Bool {
        switch self {
        case .fatProteinOnly,
             .fatProteinRich,
             .slow: return true
        case .fast,
             .medium,
             .standard: return false
        }
    }

    /// The extended part covers the fat-protein units (instead of a share of the bolus).
    var coversFPU: Bool {
        self == .fatProteinRich || self == .fatProteinOnly
    }

    // MARK: - Defaults

    /// Slow carbs: 70 % now, 30 % over 90 minutes.
    static let slowImmediatePercent = 70
    static let slowDurationMinutes = 90
    /// Share of the full FPU insulin given; 50 % is the usual starting point.
    static let defaultFPUInsulinPercent = 50

    /// Extended duration by FPU count: 1 → 3 h, 2 → 4 h, 3 → 5 h, ≥ 4 → 7.5 h (table: 7–8 h).
    static func extendedMinutes(forFPU fpu: Decimal) -> Int {
        switch fpu {
        case ..<1.5: return 180
        case ..<2.5: return 240
        case ..<3.5: return 300
        default: return 450
        }
    }

    /// Fat-protein units: 1 FPU = 100 kcal from fat (9 kcal/g) and protein (4 kcal/g).
    static func fpu(fat: Decimal, protein: Decimal) -> Decimal {
        guard fat > 0 || protein > 0 else { return 0 }
        return (max(fat, 0) * 9 + max(protein, 0) * 4) / 100
    }

    /// Insulin for `fpu` fat-protein units: per FPU as much as per 10 g carbs, times `percent` / 100.
    /// Zero without a valid carb ratio (g/U).
    static func fpuInsulin(fpu: Decimal, carbRatio: Decimal, percent: Int) -> Decimal {
        guard fpu > 0, carbRatio > 0, percent > 0 else { return 0 }
        return fpu * 10 / carbRatio * Decimal(percent) / 100
    }
}

/// Per-user defaults for the meal type strategies (UserDefaults; not therapy-critical).
enum MealCarbTypeSettings {
    static let fpuInsulinPercentKey = "mealCarbType.fpuInsulinPercent"
    /// Default time between the immediate bolus and the first extended portion, in minutes.
    static let extendedDelayMinutesKey = "extendedBolus.delayMinutes"
    static let extendedDelayRange = 0 ... Int(ExtendedBolus.maximumDelay / 60)
    static let extendedDelayStep = 15

    static var extendedDelayMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: extendedDelayMinutesKey)
            return min(max(stored, extendedDelayRange.lowerBound), extendedDelayRange.upperBound)
        }
        set {
            UserDefaults.standard.set(
                min(max(newValue, extendedDelayRange.lowerBound), extendedDelayRange.upperBound),
                forKey: extendedDelayMinutesKey
            )
        }
    }

    static var fpuInsulinPercent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: fpuInsulinPercentKey)
            return stored > 0 ? min(stored, 100) : MealCarbType.defaultFPUInsulinPercent
        }
        set { UserDefaults.standard.set(min(max(newValue, 10), 100), forKey: fpuInsulinPercentKey) }
    }
}
