import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSetupView: UIViewControllerRepresentable {
        let pumpEntry: PumpCatalogEntry
        /// In actual insulin units; converted to pump units below.
        let pumpInitialSettings: PumpInitialSettings
        let insulinConcentration: InsulinConcentration
        let bluetoothManager: BluetoothStateManager
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        /// The new pump's table is not known yet: round a concentrated rate down to 0.05 pump U/h,
        /// a step every supported pump can deliver, and never turn a non-zero rate into zero.
        static func setupRate(forActual actual: Double, _ concentration: InsulinConcentration) -> Double {
            let pumpRate = concentration.toPump(actual)
            guard !concentration.isStandard, actual > 0 else { return pumpRate }
            return max(0.05, (pumpRate * 20 + 1E-9).rounded(.down) / 20)
        }

        func makeUIViewController(context _: UIViewControllerRepresentableContext<PumpSetupView>) -> UIViewController {
            // var setupViewController: PumpManagerSetupViewController & UIViewController & CompletionNotifying
            var setupViewController: SetupUIResult<
                PumpManagerViewController,
                PumpManagerUI
            >

            // A newly set up pump runs this schedule and these limits on its own, so they must
            // already be in pump units for the configured insulin concentration.
            let concentration = insulinConcentration
            let pumpBasalSchedule = BasalRateSchedule(
                dailyItems: pumpInitialSettings.basalSchedule.items.map {
                    RepeatingScheduleValue(startTime: $0.startTime, value: Self.setupRate(forActual: $0.value, concentration))
                },
                timeZone: pumpInitialSettings.basalSchedule.timeZone
            )! // same start times as an already valid schedule, so this cannot fail; never fall back to unconverted rates
            let initialSettings = PumpManagerSetupSettings(
                maxBasalRateUnitsPerHour: concentration.toPump(pumpInitialSettings.maxBasalRateUnitsPerHour),
                maxBolusUnits: concentration.toPump(pumpInitialSettings.maxBolusUnits),
                basalSchedule: pumpBasalSchedule
            )

            let ManagerType = pumpEntry.manager
            setupViewController = ManagerType.setupViewController(
                initialSettings: initialSettings,
                bluetoothProvider: bluetoothManager,
                colorPalette: .default,
                allowDebugFeatures: true,
                prefersToSkipUserInteraction: false,
                allowedInsulinTypes: pumpEntry.allowedInsulinTypes
            )

            switch setupViewController {
            case var .userInteractionRequired(setupViewControllerUI):
                setupViewControllerUI.pumpManagerOnboardingDelegate = setupDelegate
                setupViewControllerUI.completionDelegate = completionDelegate
                return setupViewControllerUI
            case let .createdAndOnboarded(pumpManagerUI):
                debug(.default, "Pump manager  created and onboarded")
                setupDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManagerUI)
                var vc = pumpManagerUI.settingsViewController(
                    bluetoothProvider: bluetoothManager,
                    pumpManagerOnboardingDelegate: setupDelegate
                )
                vc.completionDelegate = completionDelegate
                return vc
            }
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSetupView>) {}
    }
}
