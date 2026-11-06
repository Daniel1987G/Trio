import Combine
import Foundation
import LoopKit

extension BasalProfileEditor {
    final class Provider: BaseProvider, BasalProfileEditorProvider {
        private let processQueue = DispatchQueue(label: "BasalProfileEditorProvider.processQueue")
        @Injected() private var settingsManager: SettingsManager!

        var profile: [BasalProfileEntry] {
            storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
                ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
                ?? []
        }

        var supportedBasalRates: [Decimal]? {
            // Drops 0 even where the pump accepts it: oref rejects a schedule containing a 0 rate, so a scheduled
            // basal of 0 would be saved and then refused. Zero temp basals are unaffected — they do not come
            // from this list.
            // in actual U/h, so every offered rate is one the pump can deliver at the configured concentration
            deviceManager.pumpManager?.supportedBasalRates(concentration: settingsManager.settings.pumpInsulinConcentration)
                .filter { $0 > 0 }
                // 3 dp: the doubled U200 table must not carry binary noise, or stored rates fail to match
                .map { Decimal($0).rounded(scale: 3) }
        }

        func saveProfile(_ profile: [BasalProfileEntry]) -> AnyPublisher<Void, Error> {
            guard let pump = deviceManager?.pumpManager else {
                debugPrint("\(DebuggingIdentifiers.failed) No pump found; cannot save basal profile!")
                return Fail(error: NSError()).eraseToAnyPublisher()
            }

            let syncValues = profile.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }

            return Future { promise in
                pump.syncBasalRateSchedule(
                    actualItems: syncValues,
                    concentration: self.settingsManager.settings.pumpInsulinConcentration
                ) { result in
                    switch result {
                    case .success:
                        self.storage.save(profile, as: OpenAPS.Settings.basalProfile)
                        promise(.success(()))
                    case let .failure(error):
                        promise(.failure(error))
                    }
                }
            }.eraseToAnyPublisher()
        }
    }
}
