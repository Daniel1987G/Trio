extension AutoISFSettings {
    final class Provider: BaseProvider, AutoISFSettingsProvider {
        /// The scheduled basal rates, for the insulin budget hint.
        func basalProfile() -> [BasalProfileEntry] {
            storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        }
    }
}
