import Foundation

/// Concentration of the insulin filled into the pump.
///
/// Every pump driver assumes U100 insulin: one "pump unit" is a fixed volume (10 µl). With a
/// more concentrated insulin that same volume contains more insulin. Trio keeps every value
/// it shows, stores, uploads and feeds to the algorithm in **actual insulin units** (the units
/// a U100 user would see), and converts only at the pump boundary:
///
/// - commands to the pump (bolus, temp basal, basal schedule, delivery limits): `toPump`
/// - values reported by the pump (doses, reservoir, deliverable increments):  `fromPump`
///
/// Only power-of-two factors are offered on purpose. Multiplying or dividing a `Double` by 2 is
/// exact in binary floating point, so a value never drifts across a pump-supported increment
/// boundary (e.g. 0.05 U pump steps become exactly 0.1 U actual steps and back).
enum InsulinConcentration: Int, CaseIterable, Identifiable, Codable, Hashable {
    case u100 = 100
    case u200 = 200

    var id: Int { rawValue }

    /// Actual insulin units contained in one pump unit.
    var unitsPerPumpUnit: Double {
        Double(rawValue) / 100
    }

    var isStandard: Bool { self == .u100 }

    var displayName: String {
        switch self {
        case .u100:
            return String(localized: "U100 (standard)", comment: "Insulin concentration option")
        case .u200:
            return String(localized: "U200", comment: "Insulin concentration option")
        }
    }

    // MARK: - Actual units -> pump units (commands)

    /// Converts an insulin amount (U) or rate (U/h) in actual units to the value the pump must be commanded with.
    func toPump(_ actual: Double) -> Double {
        actual / unitsPerPumpUnit
    }

    func toPump(_ actual: Decimal) -> Decimal {
        actual / Decimal(rawValue) * 100
    }

    // MARK: - Pump units -> actual units (reports)

    /// Converts an insulin amount (U) or rate (U/h) reported by the pump to actual insulin units.
    func fromPump(_ pump: Double) -> Double {
        pump * unitsPerPumpUnit
    }

    func fromPump(_ pump: Decimal) -> Decimal {
        pump * Decimal(rawValue) / 100
    }
}
