import SwiftUI
import Swinject
import UniformTypeIdentifiers

extension BackupRestore {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        /// One importer for both purposes: two `fileImporter`s in one view hierarchy do not work reliably.
        private enum ImportPurpose {
            case folder
            case backupFile
        }

        @State private var importPurpose: ImportPurpose = .backupFile
        @State private var showImporter = false
        @State private var newPassword = ""
        @State private var confirmPassword = ""
        @State private var isEditingPassword = false
        @State private var showRemovePassword = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private func dateText(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .shortened)
        }

        var body: some View {
            List {
                automaticSection
                externalFolderSection
                passwordSection
                backupsSection
                restoreFromFileSection
                notesSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importPurpose == .folder ? [.folder] : [.json]
            ) { result in
                guard case let .success(url) = result else { return }
                switch importPurpose {
                case .folder: state.setExternalFolder(url)
                case .backupFile: state.open(url)
                }
            }
            .refreshable { state.refresh() }
            .sheet(item: $state.pendingRestore) { pending in
                RestoreSheet(
                    pending: pending,
                    issues: { state.issues(for: $0) },
                    onUnlock: { try state.unlock($0, password: $1) },
                    onRestore: { state.restore($0) }
                )
            }
            .alert(
                state.message?.title ?? "",
                isPresented: Binding(
                    get: { state.message != nil },
                    set: { if !$0 { state.message = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.message?.text ?? "")
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.automatic)
        }

        // MARK: - Sections

        private var automaticSection: some View {
            Section(
                header: Text("Automatic Backup"),
                footer: Text(
                    "Every 7 days Trio saves all settings as a file. The last 5 automatic backups are kept. The check runs with every loop cycle, so it also works while Trio is in the background."
                )
            ) {
                Toggle(
                    "Back Up Every 7 Days",
                    isOn: Binding(
                        get: { state.automaticEnabled },
                        set: { state.setAutomaticEnabled($0) }
                    )
                )
                HStack {
                    Text("Last Automatic Backup")
                    Spacer()
                    Text(state.lastAutomatic.map(dateText) ?? String(localized: "None", comment: "No backup yet"))
                        .foregroundStyle(.secondary)
                }
                if let next = state.nextAutomatic {
                    HStack {
                        Text("Next Automatic Backup")
                        Spacer()
                        Text(next <= Date() ? String(localized: "Due", comment: "Backup due now") : dateText(next))
                            .foregroundStyle(.secondary)
                    }
                }
                if let problem = state.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                Button {
                    state.backUpNow()
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive.badge.plus")
                }
                .disabled(state.isWorking)
            }
            .listRowBackground(Color.chart)
        }

        private var externalFolderSection: some View {
            Section(
                header: Text("Extra Copy"),
                footer: Text(
                    "Backups on this iPhone are lost when Trio is deleted or the iPhone is lost. Choose a folder in iCloud Drive (or another provider) and Trio additionally saves every automatic and manual backup there."
                )
            ) {
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(state.externalFolderName ?? String(localized: "None", comment: "No folder chosen"))
                        .foregroundStyle(.secondary)
                }
                Button {
                    importPurpose = .folder
                    showImporter = true
                } label: {
                    Text(
                        state
                            .externalFolderName == nil ? LocalizedStringKey("Choose Folder") : LocalizedStringKey("Change Folder")
                    )
                }
                if state.externalFolderName != nil {
                    Button("Remove Folder", role: .destructive) {
                        state.setExternalFolder(nil)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private var passwordSection: some View {
            Section(
                header: Text("Backup Password"),
                footer: Text(
                    "With a backup password, every new backup also contains the pump pairing, the Nightscout login and the API keys of the AI functions, encrypted with AES-256. Without the password this part cannot be restored, and the password cannot be recovered. A saved pump pairing is soon out of date: make a manual backup right before you switch to a new iPhone."
                )
            ) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(
                        state.hasPassword
                            ? String(localized: "Set", comment: "Backup password status")
                            : String(localized: "Not Set", comment: "Backup password status")
                    )
                    .foregroundStyle(.secondary)
                }
                if isEditingPassword || !state.hasPassword {
                    SecureField(
                        String(
                            localized: "New Password (at least \(SettingsBackupVault.minimumPasswordLength) characters)",
                            comment: "Backup password field"
                        ),
                        text: $newPassword
                    )
                    .textContentType(.newPassword)
                    SecureField(String(localized: "Repeat Password", comment: "Backup password field"), text: $confirmPassword)
                        .textContentType(.newPassword)
                    if !confirmPassword.isEmpty, confirmPassword != newPassword {
                        Text("The passwords do not match.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("Save Password") {
                        if state.setPassword(newPassword) {
                            newPassword = ""
                            confirmPassword = ""
                            isEditingPassword = false
                        }
                    }
                    .disabled(
                        newPassword.count < SettingsBackupVault.minimumPasswordLength || newPassword != confirmPassword
                    )
                } else {
                    Button("Change Password") { isEditingPassword = true }
                    Button("Remove Password", role: .destructive) { showRemovePassword = true }
                }
            }
            .listRowBackground(Color.chart)
            .confirmationDialog(
                String(localized: "Remove Backup Password?", comment: "Backup password"),
                isPresented: $showRemovePassword,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Remove Password", comment: "Backup password"), role: .destructive) {
                    state.setPassword(nil)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "New backups no longer contain the pump pairing and passwords. Existing backups still need the old password."
                )
            }
        }

        private var backupsSection: some View {
            Section(
                header: Text("Backups on This iPhone"),
                footer: Text("Tap a backup to restore it. Swipe to delete it, or share it to keep a copy elsewhere.")
            ) {
                if state.backups.isEmpty {
                    Text("No backups yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.backups) { file in
                    HStack {
                        Button {
                            state.open(file.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dateText(file.date))
                                    .foregroundStyle(Color.primary)
                                Text(
                                    "\(file.kind.displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            state.delete(file)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private var restoreFromFileSection: some View {
            Section(
                footer: Text("For example a backup from iCloud Drive or from another iPhone.")
            ) {
                Button {
                    importPurpose = .backupFile
                    showImporter = true
                } label: {
                    Label("Restore from File…", systemImage: "doc.badge.arrow.up")
                }
                .disabled(state.isWorking)
            }
            .listRowBackground(Color.chart)
        }

        private var notesSection: some View {
            Section(header: Text("What Is Backed Up")) {
                Text(
                    "Therapy settings (basal rates, ISF, carb ratios, glucose targets), delivery limits and insulin action, algorithm settings, app settings and override and temp target presets."
                )
                Text(
                    "With a backup password also: pump pairing, Nightscout URL and API secret, API keys of the AI functions."
                )
                Text(
                    "Not included: CGM pairing, Tidepool login and history (glucose, insulin, carbs)."
                )
                .foregroundStyle(.secondary)
                if state.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Restoring…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    // MARK: - Restore sheet

    struct RestoreSheet: View {
        @State var pending: PendingRestore
        let issues: (PendingRestore) -> [String]
        let onUnlock: (PendingRestore, String) throws -> PendingRestore
        let onRestore: (PendingRestore) -> Void

        @State private var showConfirmation = false
        @State private var password = ""
        @State private var unlockError: String?
        @Environment(\.dismiss) private var dismiss

        private var backup: SettingsBackup { pending.backup }

        var body: some View {
            let currentIssues = issues(pending)

            NavigationStack {
                List {
                    Section(header: Text("Backup")) {
                        row("Created", backup.created.formatted(date: .abbreviated, time: .shortened))
                        row("Type", backup.kind.displayName)
                        if !backup.appVersion.isEmpty {
                            row("Trio Version", backup.appVersion)
                        }
                        if let concentration = backup.pumpInsulinConcentration {
                            row("Insulin at the Time", concentration.displayName)
                        }
                        Text(pending.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if backup.isLocked {
                        Section(
                            header: Text("Password-Protected Part"),
                            footer: Text(
                                "This backup also contains the pump pairing and/or passwords. Enter the backup password to restore them."
                            )
                        ) {
                            SecureField(String(localized: "Backup Password", comment: "Backup password field"), text: $password)
                                .textContentType(.password)
                            if let unlockError {
                                Text(unlockError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            Button {
                                do {
                                    pending = try onUnlock(pending, password)
                                    password = ""
                                    unlockError = nil
                                } catch {
                                    unlockError = error.localizedDescription
                                }
                            } label: {
                                Label("Unlock", systemImage: "lock.open")
                            }
                            .disabled(password.isEmpty)
                        }
                    }

                    Section(
                        header: Text("Restore"),
                        footer: Text(
                            "Insulin concentration, dosing mode (open/closed loop), CGM selection and bolus step are never changed by a restore: they belong to this iPhone and the insulin in your pump."
                        )
                    ) {
                        ForEach(backup.availableSections) { section in
                            Toggle(isOn: Binding(
                                get: { pending.selected.contains(section) },
                                set: { isOn in
                                    if isOn { pending.selected.insert(section) } else { pending.selected.remove(section) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.displayName)
                                    Text(section.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if pending.selected.contains(.pumpPairing) {
                        Section(header: Text("Pump Pairing")) {
                            if let name = backup.unsealed?.pumpName {
                                row("Pump", name)
                            }
                            row("Saved", pairingAge)
                            Label(
                                "Only for the same pod or pump that is still running, e.g. after switching to a new iPhone. Insulin delivered since this backup is unknown to OpenTrio, so IOB can be too low: be careful with boluses for the next hours. If the saved state is out of date, the pod may no longer respond and has to be replaced.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }

                    if !backup.unreadableParts.isEmpty {
                        Section {
                            Label(
                                "Some parts of this backup could not be read and are skipped: \(backup.unreadableParts.joined(separator: ", "))",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }

                    if !currentIssues.isEmpty {
                        Section(header: Text("Cannot Be Restored")) {
                            ForEach(currentIssues, id: \.self) { issue in
                                Label(issue, systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Section {
                        Text(
                            "Basal rates and delivery limits are written to the pump first and only saved when the pump accepted them. Before restoring, Trio saves your current settings as a backup \"Before Restore\"."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            showConfirmation = true
                        } label: {
                            Text("Restore Selected Settings").frame(maxWidth: .infinity)
                        }
                        .disabled(pending.selected.isEmpty || !currentIssues.isEmpty)
                    }
                }
                .navigationTitle("Restore Backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .confirmationDialog(
                    "Restore Settings?",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Restore", role: .destructive) {
                        onRestore(pending)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "The selected settings are replaced by those of the backup. The algorithm uses them from the next loop cycle."
                    )
                }
            }
        }

        /// Date of the backup and how long ago it was made.
        private var pairingAge: String {
            let hours = max(0, Int(Date().timeIntervalSince(backup.created) / 3600))
            return backup.created.formatted(date: .abbreviated, time: .shortened) + " · " + String(
                localized: "\(hours) h ago",
                comment: "Age of a backup in hours"
            )
        }

        private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}
