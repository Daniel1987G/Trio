import SwiftUI
import Swinject

extension MealPhotoSettings {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("AI Provider"),
                    footer: Text(
                        "The photo is sent to the selected provider for analysis. Your API key is stored in the iOS Keychain on this iPhone. Each analysis is billed by the provider to your account."
                    )
                ) {
                    Picker("Provider", selection: $state.selectedProvider) {
                        ForEach(MealPhotoProvider.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: state.selectedProvider) { state.load() }

                    SecureField(
                        state.hasStoredKey ? String(localized: "API key saved – enter to replace") : String(localized: "API key"),
                        text: $state.apiKey
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    // SwiftUI.Link: Trio has its own `Link` view modifier
                    SwiftUI.Link(destination: state.selectedProvider.keyURL) {
                        Label("Get an API key", systemImage: "arrow.up.right.square")
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Model"),
                    footer: Text(
                        "Must be a model that accepts images. Providers rename models from time to time; adjust it here if analysis reports an unknown model."
                    )
                ) {
                    TextField(state.selectedProvider.defaultModel, text: $state.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use Default Model") { state.resetModel() }
                }
                .listRowBackground(Color.chart)

                Section {
                    Button("Save") { state.save() }
                    Button {
                        state.testConnection()
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if state.isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(state.isTesting)
                    if let result = state.testResult {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                    if state.hasStoredKey {
                        Button("Remove API Key", role: .destructive) { state.removeKey() }
                    }
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Important")) {
                    Text(
                        "Estimates from a photo can be far off, especially for mixed dishes, sauces and hidden fat. Always check the values and weigh where possible. Trio never gives insulin based on a photo by itself."
                    )
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Meal Photo Analysis")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
