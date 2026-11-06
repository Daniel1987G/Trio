import SwiftUI
import UIKit

extension MealPhotoSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!

        /// Not `provider`: BaseStateModel already has the module's data provider under that name.
        @Published var selectedProvider: MealPhotoProvider = .anthropic
        @Published var apiKey: String = ""
        @Published var model: String = ""
        @Published private(set) var hasStoredKey = false
        @Published private(set) var isTesting = false
        @Published var testResult: String?

        private var store: MealPhotoSettingsStore { MealPhotoSettingsStore(keychain: keychain) }

        override func subscribe() {
            selectedProvider = store.provider
            load()
        }

        /// Shows the stored values of the selected provider; the key itself is never displayed.
        func load() {
            store.provider = selectedProvider
            model = store.model(for: selectedProvider)
            hasStoredKey = store.apiKey(for: selectedProvider) != nil
            apiKey = ""
            testResult = nil
        }

        func save() {
            if !apiKey.isEmpty { store.setAPIKey(apiKey, for: selectedProvider) }
            store.setModel(model, for: selectedProvider)
            apiKey = ""
            hasStoredKey = store.apiKey(for: selectedProvider) != nil
        }

        func removeKey() {
            store.setAPIKey(nil, for: selectedProvider)
            apiKey = ""
            hasStoredKey = false
            testResult = nil
        }

        func resetModel() {
            model = selectedProvider.defaultModel
            store.setModel("", for: selectedProvider)
        }

        /// Sends a small plain image: a "no food" answer proves key, model and network work.
        func testConnection() {
            save()
            guard let key = store.apiKey(for: selectedProvider) else {
                testResult = MealPhotoAnalysisError.missingAPIKey.localizedDescription
                return
            }
            isTesting = true
            testResult = nil
            let selectedProvider = self.selectedProvider
            let model = store.model(for: selectedProvider)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            Task {
                let message: String
                do {
                    _ = try await MealPhotoAnalyzer().analyze(image: image, provider: selectedProvider, model: model, apiKey: key)
                    message = String(localized: "Connection works.")
                } catch MealPhotoAnalysisError.notFood {
                    message = String(localized: "Connection works.")
                } catch {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = message
                }
            }
        }
    }
}
