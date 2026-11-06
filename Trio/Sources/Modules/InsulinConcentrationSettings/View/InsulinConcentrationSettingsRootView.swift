import SwiftUI
import Swinject

extension InsulinConcentrationSettings {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Insulin in the Pump"),
                    footer: Text(
                        "Select the concentration of the insulin currently filled into your pump. All values in Trio (basal rates, boluses, IOB, limits, reservoir, history) stay in regular insulin units as with U100. Only commands to the pump and values read from the pump are converted."
                    )
                ) {
                    ForEach(InsulinConcentration.allCases) { option in
                        Button {
                            state.request(option)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.displayName)
                                        .foregroundStyle(Color.primary)
                                    if let increment = state.bolusIncrementText(for: option) {
                                        Text("Smallest bolus step: \(increment)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if state.current == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .disabled(state.isApplying)
                    }

                    if state.isApplying {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Updating pump…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)

                if state.isPumpSyncPending {
                    Section(header: Text("Pump Not Updated")) {
                        Label {
                            Text(
                                "The basal schedule and delivery limits on the pump have not been updated for the current insulin concentration yet. Until this succeeds, the pump's own basal schedule runs in the previous units."
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Button("Update Pump") {
                            state.retryPumpSync()
                        }
                        .disabled(state.isApplying)
                    }
                    .listRowBackground(Color.chart)
                }

                if !state.current.isStandard {
                    Section(header: Text("Active Conversion")) {
                        Text(
                            "Trio sends 1 pump unit for every \(Int(state.current.unitsPerPumpUnit)) units of insulin and counts every pump unit reported by the pump as \(Int(state.current.unitsPerPumpUnit)) units of insulin."
                        )
                        Text(
                            "Screens provided by the pump itself (pump settings, reservoir in pod/patch settings, boluses entered on the pump device) still show pump units."
                        )
                        .foregroundStyle(.orange)
                    }
                    .listRowBackground(Color.chart)
                }

                Section(header: Text("Important")) {
                    Text(
                        "Only change this setting when the pump has been filled with insulin of the selected concentration, ideally when starting a new pod, patch or reservoir. A wrong setting means the pump delivers double or half of the intended insulin."
                    )
                    Text(
                        "When you change it, Trio uses the new concentration for all pump commands right away, cancels a running temporary basal and rewrites the basal schedule and the delivery limits on the pump. If the pump cannot be updated, you are warned and can retry."
                    )
                    if !state.isPumpPaired {
                        Text("No pump is paired. A pump paired later is set up with converted values automatically.")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .confirmationDialog(
                "Change Insulin Concentration?",
                isPresented: Binding(
                    get: { state.pending != nil },
                    set: { if !$0 { state.pending = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pending = state.pending {
                    Button("Switch to \(pending.displayName)", role: .destructive) {
                        state.confirmPending()
                    }
                }
                Button("Cancel", role: .cancel) {
                    state.pending = nil
                }
            } message: {
                if let pending = state.pending {
                    Text(
                        "Confirm that the pump is now filled with \(pending.displayName) insulin. Trio will update the basal schedule and delivery limits on the pump."
                    )
                }
            }
            .alert(
                "Insulin Concentration",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.errorMessage ?? "")
            }
            .navigationTitle("Insulin Concentration")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
