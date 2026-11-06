import CoreData
import HealthKit
import Observation
import SwiftUI

extension History {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var broadcaster: Broadcaster!
        @ObservationIgnored @Injected() var apsManager: APSManager!
        @ObservationIgnored @Injected() var unlockmanager: UnlockManager!
        @ObservationIgnored @Injected() private var storage: FileStorage!
        @ObservationIgnored @Injected() var pumpHistoryStorage: PumpHistoryStorage!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var healthKitManager: HealthKitManager!
        @ObservationIgnored @Injected() var carbsStorage: CarbsStorage!
        @ObservationIgnored @Injected() var carbEntryMutationService: CarbEntryMutationService!

        var mode: Mode = .treatments
        var treatments: [Treatment] = []
        var manualGlucose: Decimal = 0
        var waitForSuggestion: Bool = false

        var insulinEntryDeleted: Bool = false
        var carbEntryDeleted: Bool = false

        var units: GlucoseUnits = .mgdL
        /// Delivered extended bolus portions; they are automatic boluses but no SMBs.
        var extendedBolusPortions: [ExtendedBolusPortion] = []
        /// `fpuID`s of carb equivalents that are the extended part of a bolus.
        var extendedCarbPlanIDs: Set<UUID> = []

        var carbEntryToEdit: CarbEntryStored?
        var showCarbEntryEditor = false

        override func subscribe() {
            units = settingsManager.settings.units
            reloadExtendedBolusPortions()
            broadcaster.register(DeterminationObserver.self, observer: self)
            broadcaster.register(SettingsObserver.self, observer: self)
        }

        func reloadExtendedBolusPortions() {
            extendedBolusPortions = storage.retrieve(OpenAPS.Monitor.extendedBolusPortions, as: [ExtendedBolusPortion].self) ?? []
            extendedCarbPlanIDs = Set(
                (storage.retrieve(OpenAPS.Monitor.extendedCarbPlans, as: [ExtendedCarbPlan].self) ?? []).map(\.fpuID)
            )
        }

        /// Whether `bolus` is a portion of an extended bolus (stored by the pump as an automatic bolus).
        func isExtendedBolusPortion(_ bolus: BolusStored, at date: Date?) -> Bool {
            guard bolus.isSMB, let date, let amount = bolus.amount else { return false }
            return ExtendedBolusPortions.isPortion(date: date, amount: amount as Decimal, in: extendedBolusPortions)
        }

        /// Checks if the glucose data is fresh based on the given date
        /// - Parameter glucoseDate: The date to check
        /// - Returns: Boolean indicating if the data is fresh
        func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool {
            glucoseStorage.isGlucoseDataFresh(glucoseDate)
        }

        func addManualGlucose() {
            // Always save value in mg/dL
            let glucose = units == .mmolL ? manualGlucose.asMgdL : manualGlucose
            let glucoseAsInt = Int(glucose)

            glucoseStorage.addManualGlucose(glucose: glucoseAsInt)
        }
    }
}

extension History.StateModel: DeterminationObserver, SettingsObserver {
    func determinationDidUpdate(_: Determination) {
        DispatchQueue.main.async {
            self.waitForSuggestion = false
            // a new portion may have been delivered this cycle
            self.reloadExtendedBolusPortions()
        }
    }

    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
