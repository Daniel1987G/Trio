import Foundation
import SwiftUI
import Swinject

extension ProfileSnapshots {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var backupManager: BackupManager!

        @Published private(set) var snapshots: [ProfileSnapshot] = []
        @Published private(set) var current: ProfileSnapshot?
        @Published private(set) var isWorking = false
        @Published var message: (title: String, text: String)?

        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            units = settingsManager.settings.units
            refresh()
        }

        func refresh() {
            guard let backupManager else { return }
            snapshots = backupManager.profileSnapshots()
            current = backupManager.currentProfile()
        }

        /// The saved profile with the same values as the one in use, if any.
        var savedCurrent: ProfileSnapshot? {
            guard let current else { return nil }
            return snapshots.first { $0.hasSameValues(as: current) }
        }

        func saveCurrent(name: String) {
            do {
                let saved = try backupManager.saveCurrentProfile(name: name)
                refresh()
                message = (
                    String(localized: "Profile Saved", comment: "Profile snapshot alert title"),
                    String(localized: "\"\(saved.name)\" was saved.", comment: "Profile snapshot alert")
                )
            } catch {
                message = (
                    String(localized: "Profile Not Saved", comment: "Profile snapshot alert title"),
                    error.localizedDescription
                )
            }
        }

        func rename(_ snapshot: ProfileSnapshot, to name: String) {
            try? backupManager.renameProfileSnapshot(id: snapshot.id, to: name)
            refresh()
        }

        func delete(_ snapshot: ProfileSnapshot) {
            backupManager.deleteProfileSnapshot(id: snapshot.id)
            refresh()
        }

        func restore(_ snapshot: ProfileSnapshot) {
            guard !isWorking else { return }
            isWorking = true
            let manager = backupManager!
            Task {
                do {
                    _ = try await manager.restoreProfile(id: snapshot.id)
                    await MainActor.run {
                        self.isWorking = false
                        self.refresh()
                        self.message = (
                            String(localized: "Profile Restored", comment: "Profile snapshot alert title"),
                            String(
                                localized: "Basal rates, ISF and carb ratios of \"\(snapshot.name)\" are active again. The basal rates were sent to the pump. The previous profile is listed as \"Before Restore\".",
                                comment: "Profile snapshot alert"
                            )
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.isWorking = false
                        self.refresh()
                        self.message = (
                            String(localized: "Restore Failed", comment: "Backup alert title"),
                            error.localizedDescription
                        )
                    }
                }
            }
        }
    }
}
