import Foundation

enum InsulinConcentrationSettings {
    enum Config {}
}

protocol InsulinConcentrationSettingsProvider: Provider {
    var currentConcentration: InsulinConcentration { get }
    var isPumpSyncPending: Bool { get }
    var isPumpPaired: Bool { get }
    /// Smallest deliverable bolus step in actual units for `concentration`, if a pump is paired.
    func bolusIncrement(for concentration: InsulinConcentration) -> Decimal?
    /// Records that the pump now holds `concentration` insulin and rewrites basal schedule and
    /// delivery limits on the pump for it.
    func apply(_ concentration: InsulinConcentration) async throws
    /// Rewrites basal schedule and delivery limits for the current concentration (after a failed attempt).
    func retryPumpSync() async throws
}

enum InsulinConcentrationChangeError: LocalizedError {
    case bolusInProgress
    case missingBasalProfile
    /// Rates (actual U/h, already formatted) the pump cannot deliver exactly at the target concentration.
    case basalRatesNotDeliverable(String)
    case pumpSyncFailed(Error)

    var errorDescription: String? {
        switch self {
        case .bolusInProgress:
            return String(
                localized: "A bolus is in progress. Wait until it has finished, then try again. Nothing was changed.",
                comment: "Insulin concentration change error"
            )
        case .missingBasalProfile:
            return String(
                localized: "No basal profile is configured, so the pump cannot be updated. Nothing was changed.",
                comment: "Insulin concentration change error"
            )
        case let .basalRatesNotDeliverable(rates):
            return String(
                localized: "With this insulin concentration your pump cannot deliver these basal rates exactly: \(rates). Please change them in Therapy → Basal Rates to rates the pump can deliver (for U200 on Omnipod: steps of 0.1 U/hr), then try again. Nothing was changed.",
                comment: "Insulin concentration change error"
            )
        case let .pumpSyncFailed(error):
            return String(
                localized: "The insulin concentration was changed, but the basal schedule and delivery limits on the pump could not be updated (\(error.localizedDescription)). Until this succeeds, the pump's own basal schedule still runs in the previous units. Tap \"Update Pump\" to try again.",
                comment: "Insulin concentration change error"
            )
        }
    }
}
