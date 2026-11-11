import Foundation
import HealthKit
import LoopKit

extension InsulinConcentrationSettings {
    final class Provider: BaseProvider, InsulinConcentrationSettingsProvider {
        @Injected() private var settingsManager: SettingsManager!
        @Injected() private var broadcaster: Broadcaster!

        var currentConcentration: InsulinConcentration {
            settingsManager.settings.pumpInsulinConcentration
        }

        var isPumpPaired: Bool {
            deviceManager.pumpManager != nil
        }

        func bolusIncrement(for concentration: InsulinConcentration) -> Decimal? {
            guard let first = deviceManager.pumpManager?.supportedBolusVolumes(concentration: concentration).first,
                  first > 0
            else { return nil }
            return Decimal(first).rounded(scale: 3)
        }

        var isPumpSyncPending: Bool {
            settingsManager.settings.pumpInsulinConcentrationSyncPending
        }

        func apply(_ newConcentration: InsulinConcentration) async throws {
            let oldConcentration = currentConcentration
            guard newConcentration != oldConcentration else { return }

            // Without a pump there is nothing on a device to convert. A pump set up later receives
            // its basal schedule and limits already converted (see PumpSetupView).
            guard let pump = deviceManager.pumpManager else {
                var settings = settingsManager.settings
                settings.pumpInsulinConcentration = newConcentration
                settings.pumpInsulinConcentrationSyncPending = false
                settingsManager.settings = settings
                debug(.deviceManager, "Insulin concentration set to U\(newConcentration.rawValue) (no pump paired)")
                return
            }

            // Preconditions first, so a refusal leaves everything untouched.
            guard case .noBolus = pump.status.bolusState else {
                throw InsulinConcentrationChangeError.bolusInProgress
            }
            let scheduleItems = try basalScheduleItems()
            try requireDeliverable(scheduleItems, pump: pump, concentration: newConcentration)

            // The user confirmed the pump now holds the new insulin, so every command from here on
            // (including a loop cycle running concurrently) must use the new factor. Persist first;
            // the flag stays set until basal schedule and limits on the pump match.
            var settings = settingsManager.settings
            settings.pumpInsulinConcentration = newConcentration
            settings.pumpInsulinConcentrationSyncPending = true
            settingsManager.settings = settings
            updateBolusIncrement(pump: pump, concentration: newConcentration)
            debug(.deviceManager, "Insulin concentration set to U\(newConcentration.rawValue), updating pump")

            // A running temp basal was commanded in the old pump units and would now be misread.
            // A zero-duration temp cancels it; the rate is irrelevant. The next loop sets a new one.
            if case .tempBasal = pump.status.basalDeliveryState {
                do {
                    try await enactTempBasal(pump, actualUnitsPerHour: 0, duration: 0, concentration: newConcentration)
                } catch {
                    throw InsulinConcentrationChangeError.pumpSyncFailed(error)
                }
            }

            // Order the writes so the pump never holds a schedule above its own max basal:
            // if pump-side values grow (e.g. U200 -> U100) raise the limits first.
            let pumpValuesIncrease = newConcentration.unitsPerPumpUnit < oldConcentration.unitsPerPumpUnit
            try await syncPump(pump, scheduleItems: scheduleItems, limitsFirst: pumpValuesIncrease)
        }

        func retryPumpSync() async throws {
            guard let pump = deviceManager.pumpManager else {
                settingsManager.settings.pumpInsulinConcentrationSyncPending = false
                return
            }
            let scheduleItems = try basalScheduleItems()
            try requireDeliverable(scheduleItems, pump: pump, concentration: currentConcentration)
            // limits first is the safe order whichever way the previous attempt went
            try await syncPump(pump, scheduleItems: scheduleItems, limitsFirst: true)
        }

        // MARK: - Pump sync

        private func basalScheduleItems() throws -> [RepeatingScheduleValue<Double>] {
            let basalProfile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            guard !basalProfile.isEmpty else {
                throw InsulinConcentrationChangeError.missingBasalProfile
            }
            return basalProfile.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }
        }

        /// Refuses a schedule the pump could only deliver rounded: the user decides the new rates.
        private func requireDeliverable(
            _ items: [RepeatingScheduleValue<Double>],
            pump: PumpManager,
            concentration: InsulinConcentration
        ) throws {
            let undeliverable = pump.undeliverableBasalRates(items.map(\.value), concentration: concentration)
            guard !undeliverable.isEmpty else { return }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 3
            let list = Array(Set(undeliverable)).sorted()
                .map {
                    (formatter.string(from: $0 as NSNumber) ?? "\($0)") + String(localized: " U/hr", comment: "Basal rate unit")
                }
                .joined(separator: ", ")
            throw InsulinConcentrationChangeError.basalRatesNotDeliverable(list)
        }

        /// Writes basal schedule and delivery limits (both in actual units) for the current concentration,
        /// then clears the pending flag.
        private func syncPump(
            _ pump: PumpManager,
            scheduleItems: [RepeatingScheduleValue<Double>],
            limitsFirst: Bool
        ) async throws {
            let concentration = currentConcentration
            let pumpSettings = settingsManager.pumpSettings
            let limits = DeliveryLimits(
                maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(pumpSettings.maxBasal)),
                maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(pumpSettings.maxBolus))
            )

            let reportedLimits: DeliveryLimits
            do {
                if limitsFirst {
                    reportedLimits = try await syncLimits(pump, limits, concentration)
                    try await syncSchedule(pump, scheduleItems, concentration)
                } else {
                    try await syncSchedule(pump, scheduleItems, concentration)
                    reportedLimits = try await syncLimits(pump, limits, concentration)
                }
            } catch {
                debug(.deviceManager, "Insulin concentration: pump update failed: \(error)")
                throw InsulinConcentrationChangeError.pumpSyncFailed(error)
            }

            updateBolusIncrement(pump: pump, concentration: concentration)
            storeLimits(reportedLimits)
            settingsManager.settings.pumpInsulinConcentrationSyncPending = false
            debug(.deviceManager, "Insulin concentration: pump updated for U\(concentration.rawValue)")
        }

        /// The bolus step Trio rounds to is a pump capability, so it moves with the concentration.
        private func updateBolusIncrement(pump: PumpManager, concentration: InsulinConcentration) {
            guard let first = pump.supportedBolusVolumes(concentration: concentration).first, first > 0 else { return }
            var preferences = settingsManager.preferences
            preferences.bolusIncrement = Decimal(first).rounded(scale: 3)
            settingsManager.preferences = preferences
        }

        private func storeLimits(_ reportedLimits: DeliveryLimits) {
            // Keep the stored limits in line with what the pump accepted (Dana-style pumps only report them).
            // The pump helper never returns more than was requested for a concentrated insulin.
            let current = settingsManager.pumpSettings
            let updated = PumpSettings(
                insulinActionCurve: current.insulinActionCurve,
                maxBolus: reportedLimits.maximumBolus
                    .map { Decimal($0.doubleValue(for: .internationalUnit())) } ?? current.maxBolus,
                maxBasal: reportedLimits.maximumBasalRate
                    .map { Decimal($0.doubleValue(for: .internationalUnitsPerHour)) } ?? current.maxBasal
            )
            storage.save(updated, as: OpenAPS.Settings.settings)
            // Broadcaster.notify must be called on the queue it notifies on; this runs in a background task.
            DispatchQueue.main.async {
                self.broadcaster.notify(PumpSettingsObserver.self, on: .main) {
                    $0.pumpSettingsDidChange(updated)
                }
            }
        }

        // MARK: - Pump commands

        private func syncSchedule(
            _ pump: PumpManager,
            _ items: [RepeatingScheduleValue<Double>],
            _ concentration: InsulinConcentration
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pump.syncBasalRateSchedule(actualItems: items, concentration: concentration) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
        }

        private func syncLimits(
            _ pump: PumpManager,
            _ limits: DeliveryLimits,
            _ concentration: InsulinConcentration
        ) async throws -> DeliveryLimits {
            try await withCheckedThrowingContinuation { continuation in
                pump.syncDeliveryLimits(actualLimits: limits, concentration: concentration) { result in
                    continuation.resume(with: result)
                }
            }
        }

        private func enactTempBasal(
            _ pump: PumpManager,
            actualUnitsPerHour: Double,
            duration: TimeInterval,
            concentration: InsulinConcentration
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pump.enactTempBasal(
                    actualUnitsPerHour: actualUnitsPerHour,
                    for: duration,
                    concentration: concentration
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
