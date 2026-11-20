import Combine
import ConnectIQ
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!
        @Injected() private var overrideStorage: OverrideStorage!

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false
        @Published var workoutOverridePreset = ""
        @Published var workoutAfterOverridePreset = ""
        /// Names of the override presets, for the workout pickers.
        @Published var overridePresetNames: [String] = []

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }
            subscribeSetting(\.workoutOverridePreset, on: $workoutOverridePreset) { workoutOverridePreset = $0 }
            subscribeSetting(\.workoutAfterOverridePreset, on: $workoutAfterOverridePreset) {
                workoutAfterOverridePreset = $0 }
            loadOverridePresetNames()

            devices = garmin.devices
        }

        private func loadOverridePresetNames() {
            Task { [weak self] in
                guard let self else { return }
                let ids = (try? await self.overrideStorage.fetchForOverridePresets()) ?? []
                let context = CoreDataStack.shared.persistentContainer.viewContext
                let names: [String] = await context.perform {
                    ids.compactMap { (try? context.existingObject(with: $0) as? OverrideStored)?.name }
                }
                await MainActor.run { self.overridePresetNames = names }
            }
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
