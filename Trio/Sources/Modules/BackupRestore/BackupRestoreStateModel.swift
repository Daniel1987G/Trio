import Foundation
import SwiftUI
import Swinject

extension BackupRestore {
    /// A backup opened for restoring, with the parts the user selected.
    struct PendingRestore: Identifiable {
        let id = UUID()
        let backup: SettingsBackup
        let fileName: String
        var selected: Set<BackupSection>
    }

    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var backupManager: BackupManager!

        // Mirrors for the view: it renders before services are injected.
        @Published var automaticEnabled = true
        @Published private(set) var lastAutomatic: Date?
        @Published private(set) var nextAutomatic: Date?
        @Published private(set) var problem: String?
        @Published private(set) var externalFolderName: String?
        @Published private(set) var backups: [BackupFileInfo] = []
        @Published private(set) var isWorking = false
        @Published private(set) var hasPassword = false

        @Published var pendingRestore: PendingRestore?
        @Published var message: (title: String, text: String)?

        override func subscribe() {
            refresh()
        }

        func refresh() {
            guard let backupManager else { return }
            automaticEnabled = backupManager.automaticBackupEnabled
            lastAutomatic = backupManager.lastAutomaticBackup
            nextAutomatic = backupManager.nextAutomaticBackup
            problem = backupManager.lastAutomaticBackupProblem
            externalFolderName = backupManager.externalFolderName
            backups = backupManager.localBackups()
            hasPassword = backupManager.hasBackupPassword
        }

        /// Sets, changes or (with nil) removes the backup password; false when it was not accepted.
        @discardableResult func setPassword(_ password: String?) -> Bool {
            do {
                try backupManager.setBackupPassword(password)
                refresh()
                message = (
                    String(localized: "Backup Password", comment: "Backup alert title"),
                    password == nil
                        ? String(
                            localized: "The backup password was removed. New backups no longer contain the pump pairing and passwords.",
                            comment: "Backup alert"
                        )
                        : String(
                            localized: "The backup password was saved. From the next backup on, the pump pairing and passwords are included, encrypted. Keep the password in a safe place: without it this part cannot be restored.",
                            comment: "Backup alert"
                        )
                )
                return true
            } catch {
                message = (String(localized: "Backup Password", comment: "Backup alert title"), error.localizedDescription)
                return false
            }
        }

        /// Decrypts the protected part; the passwords are pre-selected, the pump pairing never.
        func unlock(_ pending: PendingRestore, password: String) throws -> PendingRestore {
            let backup = try pending.backup.unlocked(password: password)
            var result = PendingRestore(backup: backup, fileName: pending.fileName, selected: pending.selected)
            if backup.availableSections.contains(.passwords) { result.selected.insert(.passwords) }
            return result
        }

        func setAutomaticEnabled(_ enabled: Bool) {
            backupManager.automaticBackupEnabled = enabled
            if enabled { backupManager.performAutomaticBackupIfDue() }
            refresh()
        }

        func backUpNow() {
            do {
                try backupManager.createBackup(kind: .manual)
                refresh()
                message = (
                    String(localized: "Backup Saved", comment: "Backup alert title"),
                    externalFolderName == nil || problem != nil
                        ? String(localized: "The settings were saved on this iPhone.", comment: "Backup alert")
                        : String(
                            localized: "The settings were saved on this iPhone and in the extra folder.",
                            comment: "Backup alert"
                        )
                )
            } catch {
                refresh()
                message = (String(localized: "Backup Failed", comment: "Backup alert title"), error.localizedDescription)
            }
        }

        func delete(_ file: BackupFileInfo) {
            do {
                try backupManager.deleteBackup(at: file.url)
            } catch {
                message = (String(localized: "Backup", comment: "Backup alert title"), error.localizedDescription)
            }
            refresh()
        }

        func setExternalFolder(_ url: URL?) {
            do {
                try backupManager.setExternalFolder(url)
            } catch {
                message = (String(localized: "Backup", comment: "Backup alert title"), error.localizedDescription)
            }
            refresh()
        }

        /// Opens a backup (from the list or the Files app) and prepares the restore sheet.
        func open(_ url: URL) {
            do {
                let backup = try backupManager.loadBackup(at: url)
                guard !backup.availableSections.isEmpty || backup.isLocked else {
                    message = (
                        String(localized: "Restore", comment: "Backup alert title"),
                        String(localized: "This backup contains no settings that can be restored.", comment: "Backup alert")
                    )
                    return
                }
                pendingRestore = PendingRestore(
                    backup: backup,
                    fileName: url.lastPathComponent,
                    selected: Set(backup.availableSections.filter { !$0.isSealed })
                )
            } catch {
                message = (String(localized: "Restore", comment: "Backup alert title"), error.localizedDescription)
            }
        }

        /// Problems that block restoring the current selection.
        func issues(for pending: PendingRestore) -> [String] {
            guard let backupManager else { return [] }
            var issues = pending.backup.validationIssues(for: pending.selected, currentMaxBasal: backupManager.currentMaxBasal)
            if pending.selected.contains(.pumpPairing),
               let problem = backupManager.pumpPairingProblem(for: pending.backup)?.errorDescription
            {
                issues.append(problem)
            }
            return issues
        }

        func restore(_ pending: PendingRestore) {
            guard !isWorking else { return }
            isWorking = true
            pendingRestore = nil
            let manager = backupManager!
            Task {
                do {
                    let report = try await manager.restore(pending.backup, sections: pending.selected)
                    let parts = BackupSection.allCases.filter { report.restored.contains($0) }.map(\.displayName)
                    await MainActor.run {
                        self.isWorking = false
                        self.refresh()
                        self.message = (
                            String(localized: "Settings Restored", comment: "Backup alert title"),
                            String(localized: "Restored: \(parts.joined(separator: ", ")).", comment: "Backup alert") + "\n\n" +
                                String(
                                    localized: "Your previous settings were saved as a backup \"Before Restore\". Check the restored values before relying on them.",
                                    comment: "Backup alert"
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
