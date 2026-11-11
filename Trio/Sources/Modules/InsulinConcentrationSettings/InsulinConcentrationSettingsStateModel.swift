import Foundation
import SwiftUI

extension InsulinConcentrationSettings {
    final class StateModel: BaseStateModel<Provider> {
        /// What is currently in effect (persisted).
        @Published private(set) var current: InsulinConcentration = .u100
        /// The option the user tapped and still has to confirm.
        @Published var pending: InsulinConcentration?
        @Published var isApplying = false
        @Published var errorMessage: String?
        @Published private(set) var isPumpPaired = false
        /// The pump still holds basal schedule / limits for a previous concentration.
        @Published private(set) var isPumpSyncPending = false
        /// Smallest bolus step per option, in actual units (empty without a pump).
        @Published private(set) var bolusIncrements: [InsulinConcentration: Decimal] = [:]

        override func subscribe() {
            refresh()
        }

        func refresh() {
            current = provider.currentConcentration
            isPumpPaired = provider.isPumpPaired
            isPumpSyncPending = provider.isPumpSyncPending
            var increments: [InsulinConcentration: Decimal] = [:]
            for option in InsulinConcentration.allCases {
                increments[option] = provider.bolusIncrement(for: option)
            }
            bolusIncrements = increments
        }

        func request(_ concentration: InsulinConcentration) {
            guard concentration != current, !isApplying else { return }
            pending = concentration
        }

        func bolusIncrementText(for concentration: InsulinConcentration) -> String? {
            // read from published state: the view renders before the provider exists
            guard let increment = bolusIncrements[concentration] else { return nil }
            return increment.formatted() + String(localized: " U", comment: "Insulin unit")
        }

        func confirmPending() {
            guard let target = pending else { return }
            pending = nil
            isApplying = true

            run { try await $0.apply(target) }
        }

        func retryPumpSync() {
            guard !isApplying else { return }
            isApplying = true
            run { try await $0.retryPumpSync() }
        }

        private func run(_ operation: @escaping (Provider) async throws -> Void) {
            let provider = self.provider!
            Task {
                do {
                    try await operation(provider)
                    await MainActor.run {
                        self.isApplying = false
                        self.refresh()
                    }
                } catch {
                    await MainActor.run {
                        self.isApplying = false
                        self.errorMessage = error.localizedDescription
                        self.refresh()
                    }
                }
            }
        }
    }
}
