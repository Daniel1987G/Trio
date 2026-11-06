import Combine
import CoreData
import Foundation
import HealthKit
import LoopKit
import Swinject
import UIKit

/// A backup file in the local backup folder.
struct BackupFileInfo: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let date: Date
    let kind: BackupKind
    let size: Int
}

/// What a restore changed, for the summary shown to the user.
struct BackupRestoreReport: Equatable {
    var restored: [BackupSection]
    /// A safety backup of the previous settings, if one was made.
    var safetyBackup: URL?
}

protocol BackupManager: AnyObject {
    var automaticBackupEnabled: Bool { get set }
    var lastAutomaticBackup: Date? { get }
    var nextAutomaticBackup: Date? { get }
    /// Message of the last failed automatic backup (or failed copy to the extra folder); cleared on success.
    var lastAutomaticBackupProblem: String? { get }
    var externalFolderName: String? { get }
    /// Current max basal rate, the bound basal rates of a backup are checked against.
    var currentMaxBasal: Decimal { get }
    /// With a backup password, pump pairing and passwords are added to every backup, encrypted.
    var hasBackupPassword: Bool { get }
    /// Stores (or with `nil` removes) the backup password in the Keychain.
    func setBackupPassword(_ password: String?) throws
    /// Why the pump pairing of `backup` cannot be restored now, nil when it can.
    func pumpPairingProblem(for backup: SettingsBackup) -> SettingsBackupError?

    func localBackups() -> [BackupFileInfo]
    @discardableResult func createBackup(kind: BackupKind) throws -> URL
    func loadBackup(at url: URL) throws -> SettingsBackup
    func deleteBackup(at url: URL) throws
    func restore(_ backup: SettingsBackup, sections: Set<BackupSection>) async throws -> BackupRestoreReport
    /// Stores (or with `nil` forgets) a folder chosen by the user, e.g. in iCloud Drive, that receives a copy of
    /// every automatic and manual backup.
    func setExternalFolder(_ url: URL?) throws
    func performAutomaticBackupIfDue()
}

/// Settings backup and restore. Backups are JSON files in `Documents/Backups` (visible in the Files app under
/// "On My iPhone › Trio"), optionally copied to a folder of the user's choice. An automatic backup runs every
/// 7 days; it is checked after each loop cycle and whenever the app becomes active.
final class BaseBackupManager: BackupManager, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var deviceManager: DeviceDataManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var nightscout: NightscoutManager!
    @Injected() private var keychain: Keychain!

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "BaseBackupManager.queue", qos: .utility)
    private var subscriptions = Set<AnyCancellable>()
    /// Guards `isRunningAutomatic` against concurrent triggers.
    private let lock = NSLock()
    private var isRunningAutomatic = false

    private enum Keys {
        static let automaticEnabled = "backup.automaticEnabled"
        static let lastAutomatic = "backup.lastAutomatic"
        static let lastProblem = "backup.lastProblem"
        static let externalBookmark = "backup.externalFolderBookmark"
        static let externalName = "backup.externalFolderName"
        /// Keychain
        static let password = "backup.password"
    }

    init(resolver: Resolver, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        injectServices(resolver)

        // every loop cycle (also in the background) and every return to the foreground
        apsManager.lastLoopDateSubject
            .receive(on: queue)
            .sink { [weak self] _ in self?.performAutomaticBackupIfDue() }
            .store(in: &subscriptions)
        // Trio defines its own NotificationCenter protocol, so name Foundation's explicitly
        Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: queue)
            .sink { [weak self] _ in self?.performAutomaticBackupIfDue() }
            .store(in: &subscriptions)
        // the first check waits until startup work has settled
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.performAutomaticBackupIfDue()
        }
    }

    // MARK: - State

    var automaticBackupEnabled: Bool {
        get { defaults.object(forKey: Keys.automaticEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.automaticEnabled) }
    }

    var lastAutomaticBackup: Date? {
        let stored = defaults.object(forKey: Keys.lastAutomatic) as? Date
        // fall back to the files, e.g. after the defaults were reset
        let newestFile = localBackups().first(where: { $0.kind == .automatic })?.date
        switch (stored, newestFile) {
        case let (stored?, file?): return max(stored, file)
        case let (stored?, nil): return stored
        case let (nil, file?): return file
        case (nil, nil): return nil
        }
    }

    var nextAutomaticBackup: Date? {
        guard automaticBackupEnabled else { return nil }
        guard let last = lastAutomaticBackup else { return Date() }
        return last.addingTimeInterval(SettingsBackupFiles.automaticInterval)
    }

    var lastAutomaticBackupProblem: String? {
        defaults.string(forKey: Keys.lastProblem)
    }

    var externalFolderName: String? {
        defaults.data(forKey: Keys.externalBookmark) == nil ? nil : defaults.string(forKey: Keys.externalName)
    }

    var currentMaxBasal: Decimal {
        settingsManager.pumpSettings.maxBasal
    }

    // MARK: - Backup password

    private var backupPassword: String? {
        let stored: String? = keychain.getValue(String.self, forKey: Keys.password)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    var hasBackupPassword: Bool { backupPassword != nil }

    func setBackupPassword(_ password: String?) throws {
        guard let password, !password.isEmpty else {
            keychain.removeObject(forKey: Keys.password)
            return
        }
        guard password.count >= SettingsBackupVault.minimumPasswordLength else { throw SettingsBackupError.passwordTooShort }
        if case let .failure(error) = keychain.setValue(password, forKey: Keys.password) {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
    }

    func pumpPairingProblem(for backup: SettingsBackup) -> SettingsBackupError? {
        backup.pumpPairingProblem(
            pumpIsSetUp: deviceManager.pumpManager != nil,
            currentConcentration: settingsManager.settings.pumpInsulinConcentration
        )
    }

    // MARK: - Files

    /// `Documents/Backups`, created on first use.
    private func localFolder() throws -> URL {
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent(SettingsBackupFiles.folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func localBackups() -> [BackupFileInfo] {
        guard let folder = try? localFolder(),
              let urls = try? fileManager.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        return urls.compactMap { url in
            guard let parsed = SettingsBackupFiles.parse(fileName: url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return BackupFileInfo(url: url, date: parsed.date, kind: parsed.kind, size: size)
        }
        .sorted { $0.date > $1.date }
    }

    @discardableResult func createBackup(kind: BackupKind) throws -> URL {
        let backup = snapshot(kind: kind)
        let data: Data
        do {
            data = try backup.encoded()
        } catch {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
        let name = SettingsBackupFiles.fileName(for: backup.created, kind: kind)
        let url: URL
        do {
            url = try localFolder().appendingPathComponent(name)
            // readable while the phone is locked after first unlock, like Trio's other files
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
        pruneLocal(kind: kind)
        debug(.service, "Settings backup written: \(name)")

        // a copy for the extra folder; a failure there does not fail the backup
        if kind != .beforeRestore, defaults.data(forKey: Keys.externalBookmark) != nil {
            do {
                try copyToExternalFolder(data: data, name: name, kind: kind)
                defaults.removeObject(forKey: Keys.lastProblem)
            } catch {
                let folderName = externalFolderName ?? ""
                let message = String(
                    localized: "The copy to the folder \"\(folderName)\" failed: \(error.localizedDescription)",
                    comment: "Backup problem"
                )
                defaults.set(message, forKey: Keys.lastProblem)
                debug(.service, "Settings backup: external copy failed: \(error)")
            }
        }
        return url
    }

    func loadBackup(at url: URL) throws -> SettingsBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(SettingsBackupError.fileError(url.lastPathComponent))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                result = try .success(Data(contentsOf: readURL))
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw SettingsBackupError.fileError(coordinationError.localizedDescription) }
        let data: Data
        do {
            data = try result.get()
        } catch {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
        return try SettingsBackup.decode(from: data)
    }

    func deleteBackup(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
    }

    private func pruneLocal(kind: BackupKind) {
        guard let folder = try? localFolder(),
              let names = try? fileManager.contentsOfDirectory(atPath: folder.path)
        else { return }
        for name in SettingsBackupFiles.namesToPrune(names, kind: kind) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Snapshot

    private func snapshot(kind: BackupKind) -> SettingsBackup {
        let settings = settingsManager.settings
        var extras: [String: Int] = [:]
        for key in SettingsBackup.extraKeys where UserDefaults.standard.object(forKey: key) != nil {
            extras[key] = UserDefaults.standard.integer(forKey: key)
        }
        return SettingsBackup(
            created: Date(),
            kind: kind,
            appVersion: Bundle.main.appDevVersion ?? Bundle.main.releaseVersionNumber ?? "",
            build: BuildDetails.shared.branchAndSha,
            pumpInsulinConcentration: settings.pumpInsulinConcentration,
            settings: settings,
            preferences: settingsManager.preferences,
            pumpSettings: storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self),
            basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
            insulinSensitivities: storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
            carbRatios: storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
            bgTargets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self),
            extras: extras.isEmpty ? nil : extras,
            overridePresets: overridePresetsSnapshot(),
            tempTargetPresets: tempTargetPresetsSnapshot(),
            sealed: sealedSnapshot()
        )
    }

    /// Pump pairing and passwords, encrypted; nil without a backup password or with nothing to protect.
    private func sealedSnapshot() -> SealedBackupPart? {
        guard let password = backupPassword else { return nil }
        let photoKeys = MealPhotoSettingsStore(keychain: keychain)
        var aiKeys: [String: String] = [:]
        for provider in MealPhotoProvider.allCases {
            if let key = photoKeys.apiKey(for: provider) { aiKeys[provider.rawValue] = key }
        }
        var payload = SettingsBackupPrivate(
            nightscoutURL: keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
            nightscoutSecret: keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey),
            aiAPIKeys: aiKeys.isEmpty ? nil : aiKeys
        )
        if let rawState = deviceManager.pumpManagerRawState {
            payload.pumpManagerState = try? PropertyListSerialization.data(
                fromPropertyList: rawState,
                format: .binary,
                options: 0
            )
            payload.pumpName = deviceManager.pumpName.value
        }
        guard !payload.isEmpty else { return nil }
        do {
            return try SettingsBackupVault.seal(JSONCoding.encoder.encode(payload), password: password)
        } catch {
            debug(.service, "Settings backup: protected part not written: \(error)")
            return nil
        }
    }

    private func overridePresetsSnapshot() -> [BackupOverridePreset]? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "backupOverridePresets"
        let presets: [BackupOverridePreset] = context.performAndWait {
            let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            return rows.map { row in
                BackupOverridePreset(
                    name: row.name ?? "",
                    orderPosition: Int(row.orderPosition),
                    duration: row.duration?.decimalValue ?? 0,
                    indefinite: row.indefinite,
                    percentage: row.percentage,
                    target: row.target?.decimalValue ?? 0,
                    smbIsOff: row.smbIsOff,
                    smbIsScheduledOff: row.smbIsScheduledOff,
                    start: row.start?.decimalValue,
                    end: row.end?.decimalValue,
                    advancedSettings: row.advancedSettings,
                    smbMinutes: row.smbMinutes?.decimalValue,
                    uamMinutes: row.uamMinutes?.decimalValue,
                    isfAndCr: row.isfAndCr,
                    isf: row.isf,
                    cr: row.cr
                )
            }
        }
        return presets.isEmpty ? nil : presets
    }

    private func tempTargetPresetsSnapshot() -> [BackupTempTargetPreset]? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "backupTempTargetPresets"
        let presets: [BackupTempTargetPreset] = context.performAndWait {
            let request: NSFetchRequest<TempTargetStored> = TempTargetStored.fetchRequest()
            request.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            return rows.map { row in
                BackupTempTargetPreset(
                    name: row.name ?? "",
                    orderPosition: Int(row.orderPosition),
                    duration: row.duration?.decimalValue ?? 0,
                    target: row.target?.decimalValue ?? 0,
                    halfBasalTarget: row.halfBasalTarget?.decimalValue
                )
            }
        }
        return presets.isEmpty ? nil : presets
    }

    // MARK: - Automatic backup

    func performAutomaticBackupIfDue() {
        guard automaticBackupEnabled,
              SettingsBackupFiles.isAutomaticBackupDue(last: lastAutomaticBackup, now: Date())
        else { return }

        lock.lock()
        guard !isRunningAutomatic else {
            lock.unlock()
            return
        }
        isRunningAutomatic = true
        lock.unlock()
        defer {
            lock.lock()
            isRunningAutomatic = false
            lock.unlock()
        }

        defaults.removeObject(forKey: Keys.lastProblem)
        do {
            try createBackup(kind: .automatic)
            defaults.set(Date(), forKey: Keys.lastAutomatic)
        } catch {
            // retried on the next trigger
            defaults.set(error.localizedDescription, forKey: Keys.lastProblem)
            debug(.service, "Automatic settings backup failed: \(error)")
        }
    }

    // MARK: - Extra folder

    func setExternalFolder(_ url: URL?) throws {
        guard let url else {
            defaults.removeObject(forKey: Keys.externalBookmark)
            defaults.removeObject(forKey: Keys.externalName)
            defaults.removeObject(forKey: Keys.lastProblem)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Keys.externalBookmark)
            defaults.set(url.lastPathComponent, forKey: Keys.externalName)
            defaults.removeObject(forKey: Keys.lastProblem)
        } catch {
            throw SettingsBackupError.fileError(error.localizedDescription)
        }
    }

    private func copyToExternalFolder(data: Data, name: String, kind: BackupKind) throws {
        guard let bookmark = defaults.data(forKey: Keys.externalBookmark) else { return }
        var isStale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard folder.startAccessingSecurityScopedResource() else {
            throw SettingsBackupError.fileError(String(localized: "No access to the folder.", comment: "Backup problem"))
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        if isStale, let renewed = try? folder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(renewed, forKey: Keys.externalBookmark)
        }

        let target = folder.appendingPathComponent(name)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }

        // same retention as locally, only for files Trio named
        if let names = try? fileManager.contentsOfDirectory(atPath: folder.path) {
            for old in SettingsBackupFiles.namesToPrune(names, kind: kind) {
                NSFileCoordinator().coordinate(
                    writingItemAt: folder.appendingPathComponent(old),
                    options: .forDeleting,
                    error: nil
                ) { url in
                    try? self.fileManager.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Restore

    func restore(_ backup: SettingsBackup, sections: Set<BackupSection>) async throws -> BackupRestoreReport {
        let sections = sections.intersection(backup.availableSections)
        guard !sections.isEmpty else { throw SettingsBackupError.nothingSelected }

        let issues = backup.validationIssues(for: sections, currentMaxBasal: currentMaxBasal)
        guard issues.isEmpty else { throw SettingsBackupError.invalid(issues) }

        var pump = deviceManager.pumpManager
        let concentration = settingsManager.settings.pumpInsulinConcentration
        let restoreBasal = sections.contains(.therapy) ? backup.basalProfile : nil
        let restoreLimits = sections.contains(.limits) ? backup.pumpSettings : nil

        // Everything that can refuse comes before the first change.
        if let pump {
            if restoreBasal != nil || restoreLimits != nil {
                guard case .noBolus = pump.status.bolusState else { throw SettingsBackupError.bolusInProgress }
            }
            if let restoreBasal {
                let undeliverable = pump.undeliverableBasalRates(
                    restoreBasal.map { Double($0.rate) },
                    concentration: concentration
                )
                if !undeliverable.isEmpty {
                    let list = Array(Set(undeliverable)).sorted().map { "\($0.formatted()) U/hr" }.joined(separator: ", ")
                    throw SettingsBackupError.basalRatesNotDeliverable(list)
                }
            }
        }

        var pumpRawState: PumpManager.RawValue?
        if sections.contains(.pumpPairing) {
            if let problem = pumpPairingProblem(for: backup) { throw problem }
            guard let data = backup.unsealed?.pumpManagerState,
                  let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? PumpManager.RawValue
            else { throw SettingsBackupError.pumpStateUnreadable }
            pumpRawState = raw
        }

        // The previous state, so the user can go back.
        let safetyBackup: URL
        do {
            safetyBackup = try createBackup(kind: .beforeRestore)
        } catch {
            throw SettingsBackupError.safetyBackupFailed(error.localizedDescription)
        }

        var report = BackupRestoreReport(restored: [], safetyBackup: safetyBackup)
        debug(.service, "Restoring settings backup from \(backup.created): \(sections.map(\.rawValue))")

        // 0. Pump pairing: only when none is set up (checked above), before basal and limits go to it.
        if let pumpRawState {
            let restored = await MainActor.run { self.deviceManager.restorePumpManager(rawValue: pumpRawState) }
            guard restored else { throw SettingsBackupError.pumpStateUnreadable }
            report.restored.append(.pumpPairing)
            pump = deviceManager.pumpManager
        }

        // 1. Pump-bound values. The pump is written first; a value is saved only once the pump accepted it.
        //    Order: the pump must never hold a schedule above its own max basal.
        enum PumpStep {
            case limits(PumpSettings)
            case basal([BasalProfileEntry])
        }
        var pumpSteps: [PumpStep] = []
        if let restoreLimits { pumpSteps.append(.limits(restoreLimits)) }
        if let restoreBasal {
            // limits first when they rise, basal first when they fall
            let limitsRise = (restoreLimits?.maxBasal ?? 0) >= currentMaxBasal
            if limitsRise { pumpSteps.append(.basal(restoreBasal)) } else { pumpSteps.insert(.basal(restoreBasal), at: 0) }
        }
        var done: [String] = []
        for step in pumpSteps {
            let name: String
            switch step {
            case .limits: name = String(localized: "delivery limits", comment: "Backup restore step")
            case .basal: name = String(localized: "basal rates", comment: "Backup restore step")
            }
            do {
                switch step {
                case let .limits(limits):
                    try await restoreLimitsAndDIA(limits, pump: pump, concentration: concentration)
                case let .basal(profile):
                    try await restoreBasalProfile(profile, pump: pump, concentration: concentration)
                }
                done.append(name)
            } catch {
                throw SettingsBackupError.pumpUpdateFailed(
                    step: name,
                    message: error.localizedDescription,
                    alreadyChanged: done
                )
            }
        }
        if restoreLimits != nil { report.restored.append(.limits) }

        // 2. Files only Trio reads.
        if sections.contains(.therapy) {
            if let isf = backup.insulinSensitivities {
                storage.save(isf, as: OpenAPS.Settings.insulinSensitivities)
                notify(InsulinSensitivitiesObserver.self) { $0.insulinSensitivitiesDidChange(isf) }
            }
            if let carbRatios = backup.carbRatios {
                storage.save(carbRatios, as: OpenAPS.Settings.carbRatios)
                notify(CarbRatiosObserver.self) { $0.carbRatiosDidChange(carbRatios) }
            }
            if let targets = backup.bgTargets {
                storage.save(targets, as: OpenAPS.Settings.bgTargets)
                notify(BGTargetsObserver.self) { $0.bgTargetsDidChange(targets) }
            }
            report.restored.append(.therapy)
        }

        if sections.contains(.algorithm), let preferences = backup.preferences {
            settingsManager.preferences = SettingsBackup.restoredPreferences(preferences, keeping: settingsManager.preferences)
            report.restored.append(.algorithm)
        }

        if sections.contains(.app) {
            if let settings = backup.settings {
                settingsManager.settings = SettingsBackup.restoredSettings(settings, keeping: settingsManager.settings)
            }
            // only known keys; the getters clamp out-of-range values
            for (key, value) in backup.extras ?? [:] where SettingsBackup.extraKeys.contains(key) {
                UserDefaults.standard.set(value, forKey: key)
            }
            report.restored.append(.app)
        }

        if sections.contains(.presets) {
            await restorePresets(overrides: backup.overridePresets ?? [], tempTargets: backup.tempTargetPresets ?? [])
            report.restored.append(.presets)
        }

        if sections.contains(.passwords), let secrets = backup.unsealed {
            restorePasswords(secrets)
            report.restored.append(.passwords)
        }

        if sections.contains(.therapy) || sections.contains(.limits) || sections.contains(.algorithm) {
            let nightscout = self.nightscout
            Task.detached(priority: .low) {
                try? await nightscout?.uploadProfiles()
            }
        }
        debug(.service, "Settings backup restored: \(report.restored.map(\.rawValue))")
        return report
    }

    /// Merges presets by name: same name updates the preset, others are added at the end. A running
    /// override or temp target is a copy, so it is not touched; nothing is started.
    private func restorePresets(overrides: [BackupOverridePreset], tempTargets: [BackupTempTargetPreset]) async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "restorePresets"
        await context.perform {
            let overrideRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
            overrideRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let existingOverrides = (try? context.fetch(overrideRequest)) ?? []
            var overrideOrder = Int(existingOverrides.map(\.orderPosition).max() ?? 0)
            let overrideMerge = BackupPresets.merge(overrides, existingNames: existingOverrides.compactMap(\.name), name: \.name)
            for preset in overrideMerge.updates + overrideMerge.additions {
                let row: OverrideStored
                if let existing = existingOverrides
                    .first(where: { BackupPresets.key($0.name ?? "") == BackupPresets.key(preset.name) })
                {
                    row = existing
                } else {
                    row = OverrideStored(context: context)
                    row.id = UUID().uuidString
                    row.isPreset = true
                    overrideOrder += 1
                    row.orderPosition = Int16(clamping: overrideOrder)
                }
                row.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                row.date = Date()
                row.enabled = false
                row.isUploadedToNS = false
                row.duration = preset.duration as NSDecimalNumber
                row.indefinite = preset.indefinite
                row.percentage = preset.percentage
                row.target = preset.target as NSDecimalNumber
                row.smbIsOff = preset.smbIsOff
                row.smbIsScheduledOff = preset.smbIsScheduledOff
                row.start = preset.start.map { $0 as NSDecimalNumber }
                row.end = preset.end.map { $0 as NSDecimalNumber }
                row.advancedSettings = preset.advancedSettings
                row.smbMinutes = preset.smbMinutes.map { $0 as NSDecimalNumber }
                row.uamMinutes = preset.uamMinutes.map { $0 as NSDecimalNumber }
                row.isfAndCr = preset.isfAndCr
                row.isf = preset.isf
                row.cr = preset.cr
            }

            let tempTargetRequest: NSFetchRequest<TempTargetStored> = TempTargetStored.fetchRequest()
            tempTargetRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let existingTempTargets = (try? context.fetch(tempTargetRequest)) ?? []
            var tempTargetOrder = Int(existingTempTargets.map(\.orderPosition).max() ?? 0)
            let tempTargetMerge = BackupPresets.merge(
                tempTargets,
                existingNames: existingTempTargets.compactMap(\.name),
                name: \.name
            )
            for preset in tempTargetMerge.updates + tempTargetMerge.additions {
                let row: TempTargetStored
                if let existing = existingTempTargets
                    .first(where: { BackupPresets.key($0.name ?? "") == BackupPresets.key(preset.name) })
                {
                    row = existing
                } else {
                    row = TempTargetStored(context: context)
                    row.id = UUID()
                    row.isPreset = true
                    tempTargetOrder += 1
                    row.orderPosition = Int16(clamping: tempTargetOrder)
                }
                row.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                row.date = Date()
                row.enabled = false
                row.isUploadedToNS = false
                row.duration = preset.duration as NSDecimalNumber
                row.target = preset.target as NSDecimalNumber
                row.halfBasalTarget = preset.halfBasalTarget.map { $0 as NSDecimalNumber }
                row.enteredBy = TempTarget.local
            }

            do {
                if context.hasChanges { try context.save() }
            } catch {
                debug(.service, "Settings backup: presets not restored: \(error)")
            }
        }
        await MainActor.run {
            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
            Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)
            Foundation.NotificationCenter.default.post(name: .didRestoreAdjustmentPresets, object: nil)
        }
    }

    /// Writes the passwords of the backup to the Keychain; values missing in the backup stay as they are.
    private func restorePasswords(_ secrets: SettingsBackupPrivate) {
        if let url = secrets.nightscoutURL {
            keychain.setValue(url, forKey: NightscoutConfig.Config.urlKey)
        }
        if let secret = secrets.nightscoutSecret {
            keychain.setValue(secret, forKey: NightscoutConfig.Config.secretKey)
        }
        let photoKeys = MealPhotoSettingsStore(keychain: keychain)
        for (rawProvider, key) in secrets.aiAPIKeys ?? [:] {
            if let provider = MealPhotoProvider(rawValue: rawProvider) {
                photoKeys.setAPIKey(key, for: provider)
            }
        }
    }

    private func restoreBasalProfile(
        _ profile: [BasalProfileEntry],
        pump: PumpManager?,
        concentration: InsulinConcentration
    ) async throws {
        if let pump {
            let items = profile.map { RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate)) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pump.syncBasalRateSchedule(actualItems: items, concentration: concentration) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
        }
        storage.save(profile, as: OpenAPS.Settings.basalProfile)
        notify(BasalProfileObserver.self) { $0.basalProfileDidChange(profile) }
    }

    private func restoreLimitsAndDIA(
        _ limits: PumpSettings,
        pump: PumpManager?,
        concentration: InsulinConcentration
    ) async throws {
        var stored = limits
        if let pump {
            let deliveryLimits = DeliveryLimits(
                maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(limits.maxBasal)),
                maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(limits.maxBolus))
            )
            let reported: DeliveryLimits = try await withCheckedThrowingContinuation { continuation in
                pump.syncDeliveryLimits(actualLimits: deliveryLimits, concentration: concentration) { result in
                    continuation.resume(with: result)
                }
            }
            // keep what the pump accepted (some pumps only report their limits)
            stored = PumpSettings(
                insulinActionCurve: limits.insulinActionCurve,
                maxBolus: reported.maximumBolus
                    .map { Decimal($0.doubleValue(for: .internationalUnit())) } ?? limits.maxBolus,
                maxBasal: reported.maximumBasalRate
                    .map { Decimal($0.doubleValue(for: .internationalUnitsPerHour)) } ?? limits.maxBasal
            )
        }
        storage.save(stored, as: OpenAPS.Settings.settings)
        notify(PumpSettingsObserver.self) { $0.pumpSettingsDidChange(stored) }
    }

    /// Broadcaster.notify must run on the queue it notifies on.
    private func notify<T>(_ type: T.Type, _ body: @escaping (T) -> Void) {
        DispatchQueue.main.async {
            self.broadcaster.notify(type, on: .main, block: body)
        }
    }
}
