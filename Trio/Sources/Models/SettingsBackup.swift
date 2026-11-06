import CommonCrypto
import CryptoKit
import Foundation

/// Why a backup was made. Decides its file name suffix and how many are kept.
enum BackupKind: String, Codable, CaseIterable {
    case automatic
    case manual
    case beforeRestore

    var fileSuffix: String {
        switch self {
        case .automatic: return "auto"
        case .manual: return "manual"
        case .beforeRestore: return "before-restore"
        }
    }

    /// Older backups of this kind are deleted; `nil` keeps all (manual backups are only deleted by the user).
    var keepCount: Int? {
        switch self {
        case .automatic: return 5
        case .manual: return nil
        case .beforeRestore: return 3
        }
    }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "backup.kind.automatic", defaultValue: "Automatic", comment: "Backup kind")
        case .manual: return String(localized: "backup.kind.manual", defaultValue: "Manual", comment: "Backup kind")
        case .beforeRestore: return String(
                localized: "backup.kind.beforeRestore",
                defaultValue: "Before Restore",
                comment: "Backup kind"
            )
        }
    }
}

/// Parts of a backup that can be restored independently.
enum BackupSection: String, CaseIterable, Identifiable, Codable {
    /// Basal rates, ISF, carb ratios, glucose targets.
    case therapy
    /// Max bolus, max basal, duration of insulin action.
    case limits
    /// oref preferences (SMB, autosens, max IOB, …).
    case algorithm
    /// Trio app settings (display, Nightscout upload, meals, …) and meal type defaults.
    case app
    /// Override and temp target presets (merged by name, never started).
    case presets
    /// Nightscout URL and API secret, AI provider keys (encrypted part).
    case passwords
    /// Saved state of the paired pump (encrypted part).
    case pumpPairing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .therapy: return String(localized: "Therapy Settings", comment: "Backup section")
        case .limits: return String(localized: "Delivery Limits and Insulin Action", comment: "Backup section")
        case .algorithm: return String(localized: "Algorithm Settings", comment: "Backup section")
        case .app: return String(localized: "App Settings", comment: "Backup section")
        case .presets: return String(localized: "Override and Temp Target Presets", comment: "Backup section")
        case .passwords: return String(localized: "Passwords", comment: "Backup section")
        case .pumpPairing: return String(localized: "Pump Pairing", comment: "Backup section")
        }
    }

    var detail: String {
        switch self {
        case .therapy: return String(
                localized: "Basal rates, ISF, carb ratios, glucose targets",
                comment: "Backup section detail"
            )
        case .limits: return String(
                localized: "Max bolus, max basal rate, duration of insulin action",
                comment: "Backup section detail"
            )
        case .algorithm: return String(
                localized: "SMB, UAM, autosens, max IOB and other algorithm settings",
                comment: "Backup section detail"
            )
        case .app: return String(
                localized: "Display, notifications, Nightscout upload, meal settings",
                comment: "Backup section detail"
            )
        case .presets: return String(
                localized: "Presets with the same name are updated, others added. None is started.",
                comment: "Backup section detail"
            )
        case .passwords: return String(
                localized: "Nightscout URL and API secret, API keys for the AI functions",
                comment: "Backup section detail"
            )
        case .pumpPairing: return String(
                localized: "Only when no pump is set up. For the same pod or pump, e.g. on a new iPhone.",
                comment: "Backup section detail"
            )
        }
    }

    /// Sections kept in the password-protected part of the file.
    var isSealed: Bool { self == .passwords || self == .pumpPairing }
}

/// A snapshot of all of Trio's settings files. Values are stored exactly as Trio keeps them on disk:
/// mg/dL and actual insulin units (independent of the insulin concentration).
///
/// Device-bound values are recorded but never restored, see `restoredSettings(_:keeping:)`.
struct SettingsBackup: Encodable {
    static let formatIdentifier = "org.nightscout.trio.settings-backup"
    static let currentVersion = 1

    var format: String = SettingsBackup.formatIdentifier
    var version: Int = SettingsBackup.currentVersion
    var created: Date
    var kind: BackupKind
    var appVersion: String
    var build: String
    /// Informational: the concentration in use when the backup was made.
    var pumpInsulinConcentration: InsulinConcentration?

    var settings: TrioSettings?
    var preferences: Preferences?
    var pumpSettings: PumpSettings?
    var basalProfile: [BasalProfileEntry]?
    var insulinSensitivities: InsulinSensitivities?
    var carbRatios: CarbRatios?
    var bgTargets: BGTargets?
    /// Small UserDefaults-based settings, e.g. `MealCarbTypeSettings.fpuInsulinPercentKey`.
    var extras: [String: Int]?
    var overridePresets: [BackupOverridePreset]?
    var tempTargetPresets: [BackupTempTargetPreset]?
    /// Pump pairing and passwords, encrypted with the backup password; absent without one.
    var sealed: SealedBackupPart?

    /// Parts present in the file that could not be read (not encoded).
    var unreadableParts: [String] = []
    /// The decrypted `sealed` part after `unlocked(password:)` (not encoded).
    var unsealed: SettingsBackupPrivate?

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case created
        case kind
        case appVersion
        case build
        case pumpInsulinConcentration
        case settings
        case preferences
        case pumpSettings
        case basalProfile
        case insulinSensitivities
        case carbRatios
        case bgTargets
        case extras
        case overridePresets
        case tempTargetPresets
        case sealed
    }

    init(
        created: Date,
        kind: BackupKind,
        appVersion: String,
        build: String,
        pumpInsulinConcentration: InsulinConcentration?,
        settings: TrioSettings?,
        preferences: Preferences?,
        pumpSettings: PumpSettings?,
        basalProfile: [BasalProfileEntry]?,
        insulinSensitivities: InsulinSensitivities?,
        carbRatios: CarbRatios?,
        bgTargets: BGTargets?,
        extras: [String: Int]?,
        overridePresets: [BackupOverridePreset]? = nil,
        tempTargetPresets: [BackupTempTargetPreset]? = nil,
        sealed: SealedBackupPart? = nil
    ) {
        self.created = created
        self.kind = kind
        self.appVersion = appVersion
        self.build = build
        self.pumpInsulinConcentration = pumpInsulinConcentration
        self.settings = settings
        self.preferences = preferences
        self.pumpSettings = pumpSettings
        self.basalProfile = basalProfile
        self.insulinSensitivities = insulinSensitivities
        self.carbRatios = carbRatios
        self.bgTargets = bgTargets
        self.extras = extras
        self.overridePresets = overridePresets
        self.tempTargetPresets = tempTargetPresets
        self.sealed = sealed
    }

    /// UserDefaults-based settings stored in `extras` (integers; booleans as 0/1).
    static let extraKeys = [MealCarbTypeSettings.fpuInsulinPercentKey, MealCarbTypeSettings.extendedDelayMinutesKey] +
        RescueCarbSettings.backupKeys

    /// Sections that have data in this backup.
    var availableSections: [BackupSection] {
        BackupSection.allCases.filter { section in
            switch section {
            case .therapy:
                return basalProfile != nil || insulinSensitivities != nil || carbRatios != nil || bgTargets != nil
            case .limits: return pumpSettings != nil
            case .algorithm: return preferences != nil
            case .app: return settings != nil || !(extras ?? [:]).isEmpty
            case .presets: return !(overridePresets ?? []).isEmpty || !(tempTargetPresets ?? []).isEmpty
            case .passwords: return unsealed?.hasPasswords == true
            case .pumpPairing: return unsealed?.pumpManagerState != nil
            }
        }
    }

    /// The file has a password-protected part that is not unlocked yet.
    var isLocked: Bool { sealed != nil && unsealed == nil }

    /// A copy with the password-protected part decrypted.
    func unlocked(password: String) throws -> SettingsBackup {
        guard let sealed else { return self }
        let data = try SettingsBackupVault.open(sealed, password: password)
        var copy = self
        do {
            copy.unsealed = try JSONCoding.decoder.decode(SettingsBackupPrivate.self, from: data)
        } catch {
            throw SettingsBackupError.unreadable(error.localizedDescription)
        }
        return copy
    }
}

// MARK: - Reading

enum SettingsBackupError: LocalizedError, Equatable {
    case notABackup
    case unsupportedVersion(Int)
    case unreadable(String)
    case invalid([String])
    case nothingSelected
    case bolusInProgress
    case basalRatesNotDeliverable(String)
    case safetyBackupFailed(String)
    /// `alreadyChanged`: parts written before the failing step (they stay restored).
    case pumpUpdateFailed(step: String, message: String, alreadyChanged: [String])
    case fileError(String)
    case wrongPassword
    case passwordTooShort
    case pumpAlreadySetUp
    case pumpConcentrationMismatch(backup: String, current: String)
    case pumpStateUnreadable

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return String(localized: "This file is not a Trio settings backup.", comment: "Backup error")
        case let .unsupportedVersion(version):
            return String(
                localized: "This backup was made with a newer Trio version (format \(version)) and cannot be restored with this version.",
                comment: "Backup error"
            )
        case let .unreadable(detail):
            return String(localized: "The backup could not be read: \(detail)", comment: "Backup error")
        case let .invalid(issues):
            return String(
                localized: "The backup contains values Trio does not accept. Nothing was changed.",
                comment: "Backup error"
            ) +
                "\n\n• " + issues.joined(separator: "\n• ")
        case .nothingSelected:
            return String(localized: "Select at least one part to restore.", comment: "Backup error")
        case .bolusInProgress:
            return String(
                localized: "A bolus is in progress. Wait until it has finished, then try again. Nothing was changed.",
                comment: "Backup error"
            )
        case let .basalRatesNotDeliverable(rates):
            return String(
                localized: "Your pump cannot deliver these basal rates of the backup exactly with the current insulin concentration: \(rates). Nothing was changed.",
                comment: "Backup error"
            )
        case let .safetyBackupFailed(detail):
            return String(
                localized: "The current settings could not be saved before restoring (\(detail)). Nothing was changed.",
                comment: "Backup error"
            )
        case let .pumpUpdateFailed(step, message, alreadyChanged):
            let changed = alreadyChanged.isEmpty
                ? String(localized: "Nothing was changed.", comment: "Backup error")
                : String(
                    localized: "Already restored: \(alreadyChanged.joined(separator: ", ")). Everything else was left unchanged.",
                    comment: "Backup error"
                )
            return String(
                localized: "The pump could not be updated (\(step): \(message)).",
                comment: "Backup error"
            ) + " " + changed + " " + String(
                localized: "You can return to the previous state with the backup \"Before Restore\".",
                comment: "Backup error"
            )
        case let .fileError(detail):
            return String(localized: "File error: \(detail)", comment: "Backup error")
        case .wrongPassword:
            return String(
                localized: "The backup password is wrong, or the protected part of the file is damaged.",
                comment: "Backup error"
            )
        case .passwordTooShort:
            return String(
                localized: "The backup password must have at least \(SettingsBackupVault.minimumPasswordLength) characters.",
                comment: "Backup error"
            )
        case .pumpAlreadySetUp:
            return String(
                localized: "A pump is set up on this iPhone. The pump pairing can only be restored when no pump is set up. Nothing was changed.",
                comment: "Backup error"
            )
        case let .pumpConcentrationMismatch(backup, current):
            return String(
                localized: "The pump in the backup was used with \(backup), this iPhone is set to \(current). Set the insulin concentration to \(backup) first. Nothing was changed.",
                comment: "Backup error"
            )
        case .pumpStateUnreadable:
            return String(localized: "The saved pump pairing could not be read.", comment: "Backup error")
        }
    }
}

extension SettingsBackup: Decodable {
    /// Reads every part on its own: a part that cannot be decoded is reported in `unreadableParts`
    /// instead of failing the whole file, so the rest can still be restored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? container.decode(String.self, forKey: .format)) == SettingsBackup.formatIdentifier else {
            throw SettingsBackupError.notABackup
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= SettingsBackup.currentVersion else {
            throw SettingsBackupError.unsupportedVersion(version)
        }

        format = SettingsBackup.formatIdentifier
        self.version = version
        created = try container.decode(Date.self, forKey: .created)
        kind = (try? container.decode(BackupKind.self, forKey: .kind)) ?? .manual
        appVersion = (try? container.decode(String.self, forKey: .appVersion)) ?? ""
        build = (try? container.decode(String.self, forKey: .build)) ?? ""
        pumpInsulinConcentration = try? container.decodeIfPresent(InsulinConcentration.self, forKey: .pumpInsulinConcentration)

        var unreadable: [String] = []
        func part<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard container.contains(key) else { return nil }
            do {
                return try container.decodeIfPresent(type, forKey: key)
            } catch {
                unreadable.append(key.rawValue)
                return nil
            }
        }

        settings = part(TrioSettings.self, .settings)
        preferences = part(Preferences.self, .preferences)
        pumpSettings = part(PumpSettings.self, .pumpSettings)
        basalProfile = part([BasalProfileEntry].self, .basalProfile)
        insulinSensitivities = part(InsulinSensitivities.self, .insulinSensitivities)
        carbRatios = part(CarbRatios.self, .carbRatios)
        bgTargets = part(BGTargets.self, .bgTargets)
        extras = part([String: Int].self, .extras)
        overridePresets = part([BackupOverridePreset].self, .overridePresets)
        tempTargetPresets = part([BackupTempTargetPreset].self, .tempTargetPresets)
        sealed = part(SealedBackupPart.self, .sealed)
        unreadableParts = unreadable
    }

    static func decode(from data: Data) throws -> SettingsBackup {
        do {
            return try JSONCoding.decoder.decode(SettingsBackup.self, from: data)
        } catch let error as SettingsBackupError {
            throw error
        } catch is DecodingError {
            // valid JSON of another kind, or a backup missing its header
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                throw SettingsBackupError.notABackup
            }
            throw SettingsBackupError.unreadable(String(localized: "invalid file format", comment: "Backup error detail"))
        } catch {
            throw SettingsBackupError.unreadable(error.localizedDescription)
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(self)
    }
}

// MARK: - Validation

extension SettingsBackup {
    /// Checks the parts that would be restored against the ranges Trio's own editors allow.
    /// - Parameter currentMaxBasal: max basal rate in effect now; basal rates are checked against the
    ///   restored max basal when limits are restored too, otherwise against this.
    /// - Returns: Human-readable problems; empty when the selection can be restored.
    func validationIssues(for sections: Set<BackupSection>, currentMaxBasal: Decimal) -> [String] {
        let ranges = DecimalPickerSettings()
        var issues: [String] = []

        if sections.contains(.limits), let pumpSettings {
            if !(ranges.dia.min ... ranges.dia.max).contains(pumpSettings.insulinActionCurve) {
                issues.append(String(
                    localized: "Duration of insulin action \(pumpSettings.insulinActionCurve.description) h is outside \(ranges.dia.min.description)–\(ranges.dia.max.description) h.",
                    comment: "Backup validation"
                ))
            }
            if !(ranges.maxBolus.min ... ranges.maxBolus.max).contains(pumpSettings.maxBolus) {
                issues.append(String(
                    localized: "Max bolus \(pumpSettings.maxBolus.description) U is outside \(ranges.maxBolus.min.description)–\(ranges.maxBolus.max.description) U.",
                    comment: "Backup validation"
                ))
            }
            if !(ranges.maxBasal.min ... ranges.maxBasal.max).contains(pumpSettings.maxBasal) {
                issues.append(String(
                    localized: "Max basal rate \(pumpSettings.maxBasal.description) U/hr is outside \(ranges.maxBasal.min.description)–\(ranges.maxBasal.max.description) U/hr.",
                    comment: "Backup validation"
                ))
            }
        }

        if sections.contains(.therapy) {
            let maxBasal = sections.contains(.limits) ? (pumpSettings?.maxBasal ?? currentMaxBasal) : currentMaxBasal

            if let basalProfile {
                issues += Self.scheduleIssues(
                    offsets: basalProfile.map(\.minutes),
                    name: String(localized: "Basal rates", comment: "Backup validation schedule name")
                )
                for entry in basalProfile where entry.rate <= 0 || entry.rate > maxBasal {
                    issues.append(String(
                        localized: "Basal rate \(entry.rate.description) U/hr at \(entry.start) is not between 0 and the max basal rate of \(maxBasal.description) U/hr.",
                        comment: "Backup validation"
                    ))
                }
            }

            if let insulinSensitivities {
                if insulinSensitivities.units != .mgdL {
                    issues.append(String(localized: "ISF values are not stored in mg/dL.", comment: "Backup validation"))
                }
                issues += Self.scheduleIssues(
                    offsets: insulinSensitivities.sensitivities.map(\.offset),
                    name: String(localized: "ISF", comment: "Backup validation schedule name")
                )
                for entry in insulinSensitivities.sensitivities where !(9 ... 540).contains(entry.sensitivity) {
                    issues.append(String(
                        localized: "ISF \(entry.sensitivity.description) mg/dL/U at \(entry.start) is outside 9–540 mg/dL/U.",
                        comment: "Backup validation"
                    ))
                }
            }

            if let carbRatios {
                if carbRatios.units != .grams {
                    issues.append(String(localized: "Carb ratios are not stored in grams.", comment: "Backup validation"))
                }
                issues += Self.scheduleIssues(
                    offsets: carbRatios.schedule.map(\.offset),
                    name: String(localized: "Carb ratios", comment: "Backup validation schedule name")
                )
                for entry in carbRatios.schedule where !(1 ... 50).contains(entry.ratio) {
                    issues.append(String(
                        localized: "Carb ratio \(entry.ratio.description) g/U at \(entry.start) is outside 1–50 g/U.",
                        comment: "Backup validation"
                    ))
                }
            }

            if let bgTargets {
                if bgTargets.units != .mgdL {
                    issues.append(String(localized: "Glucose targets are not stored in mg/dL.", comment: "Backup validation"))
                }
                issues += Self.scheduleIssues(
                    offsets: bgTargets.targets.map(\.offset),
                    name: String(localized: "Glucose targets", comment: "Backup validation schedule name")
                )
                for entry in bgTargets.targets
                    where !(72 ... 180).contains(entry.low) || !(72 ... 180).contains(entry.high) || entry.low > entry.high
                {
                    issues.append(String(
                        localized: "Glucose target \(entry.low.description)–\(entry.high.description) mg/dL at \(entry.start) is outside 72–180 mg/dL.",
                        comment: "Backup validation"
                    ))
                }
            }
        }

        if sections.contains(.algorithm), let preferences {
            let maxIOB = ranges.maxIOB
            if !(maxIOB.min ... maxIOB.max).contains(preferences.maxIOB) {
                issues.append(String(
                    localized: "Max IOB \(preferences.maxIOB.description) U is outside \(maxIOB.min.description)–\(maxIOB.max.description) U.",
                    comment: "Backup validation"
                ))
            }
        }

        if sections.contains(.presets) {
            issues += presetIssues()
        }

        return issues
    }

    /// Presets need a name and values Trio's editors allow (targets in mg/dL). An override target of 0 or 6
    /// means "no target": 6 is the marker of older Trio versions and Nightscout, which oref also ignores.
    static func overrideTargetMeansNone(_ target: Decimal) -> Bool {
        target == 0 || target == 6
    }

    func presetIssues() -> [String] {
        var issues: [String] = []
        for preset in overridePresets ?? [] {
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append(String(localized: "An override preset has no name.", comment: "Backup validation"))
            }
            if !(10 ... 300).contains(preset.percentage) || preset.duration < 0 ||
                (!Self.overrideTargetMeansNone(preset.target) && !(72 ... 300).contains(preset.target))
            {
                issues.append(String(
                    localized: "Override preset \(name) has values outside the allowed range.",
                    comment: "Backup validation"
                ))
            }
        }
        for preset in tempTargetPresets ?? [] {
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append(String(localized: "A temp target preset has no name.", comment: "Backup validation"))
            }
            if !(72 ... 300).contains(preset.target) || preset.duration < 0 {
                issues.append(String(
                    localized: "Temp target preset \(name) has values outside the allowed range.",
                    comment: "Backup validation"
                ))
            }
        }
        return issues
    }

    /// Why the pump pairing of this backup cannot be restored now, nil when it can.
    /// - The pump manager is only replaced when none is set up, never a working pairing.
    /// - The pod or pump holds insulin of the concentration in use at backup time; with another
    ///   setting every dose would be off by that factor.
    func pumpPairingProblem(pumpIsSetUp: Bool, currentConcentration: InsulinConcentration) -> SettingsBackupError? {
        if pumpIsSetUp { return .pumpAlreadySetUp }
        let backupConcentration = pumpInsulinConcentration ?? .u100
        if backupConcentration != currentConcentration {
            return .pumpConcentrationMismatch(
                backup: backupConcentration.displayName,
                current: currentConcentration.displayName
            )
        }
        return nil
    }

    /// A schedule must start at midnight, be ordered without duplicates and stay within one day.
    static func scheduleIssues(offsets: [Int], name: String) -> [String] {
        guard let first = offsets.first else {
            return [String(localized: "\(name): the schedule is empty.", comment: "Backup validation")]
        }
        var issues: [String] = []
        if first != 0 {
            issues.append(String(localized: "\(name): the schedule does not start at 00:00.", comment: "Backup validation"))
        }
        let ordered = zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }
        if !ordered || offsets.contains(where: { $0 < 0 || $0 >= 24 * 60 }) {
            issues.append(String(
                localized: "\(name): the times are not in order or outside one day.",
                comment: "Backup validation"
            ))
        }
        return issues
    }
}

// MARK: - Device-bound values

extension SettingsBackup {
    /// App settings from the backup, with the values that belong to this device and the insulin
    /// currently in the pump taken from `current`:
    /// - insulin concentration (and its pending pump update): depends on the insulin physically in the pump
    /// - dosing mode: switching to closed loop must stay a deliberate step
    /// - CGM selection: belongs to the sensor set up on this iPhone
    static func restoredSettings(_ backup: TrioSettings, keeping current: TrioSettings) -> TrioSettings {
        var result = backup
        result.pumpInsulinConcentration = current.pumpInsulinConcentration
        result.pumpInsulinConcentrationSyncPending = current.pumpInsulinConcentrationSyncPending
        result.dosingMode = current.dosingMode
        result.cgm = current.cgm
        result.cgmPluginIdentifier = current.cgmPluginIdentifier
        return result
    }

    /// Algorithm settings from the backup; the bolus step is a capability of the paired pump and
    /// insulin concentration, so it stays as it is.
    static func restoredPreferences(_ backup: Preferences, keeping current: Preferences) -> Preferences {
        var result = backup
        result.bolusIncrement = current.bolusIncrement
        return result
    }
}

// MARK: - Files and schedule

enum SettingsBackupFiles {
    static let folderName = "Backups"
    static let fileExtension = "json"
    private static let prefix = "Trio-Backup-"
    static let automaticInterval: TimeInterval = 7 * 24 * 60 * 60

    private static var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }

    /// `Trio-Backup-2026-10-26_204012-auto.json` (UTC, sorts chronologically by name).
    static func fileName(for date: Date, kind: BackupKind) -> String {
        "\(prefix)\(timestampFormatter.string(from: date))-\(kind.fileSuffix).\(fileExtension)"
    }

    /// Date and kind from a file name made by `fileName(for:kind:)`; `nil` for other files.
    static func parse(fileName: String) -> (date: Date, kind: BackupKind)? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix("." + fileExtension) else { return nil }
        let core = fileName.dropFirst(prefix.count).dropLast(fileExtension.count + 1)
        guard core.count > 17 else { return nil }
        let stamp = String(core.prefix(17))
        let suffix = core.dropFirst(17)
        guard suffix.first == "-",
              let kind = BackupKind.allCases.first(where: { $0.fileSuffix == suffix.dropFirst() }),
              let date = timestampFormatter.date(from: stamp)
        else { return nil }
        return (date, kind)
    }

    /// File names of `kind` beyond its keep count, oldest first. Other files are never returned.
    static func namesToPrune(_ fileNames: [String], kind: BackupKind) -> [String] {
        guard let keep = kind.keepCount else { return [] }
        let ofKind = fileNames
            .compactMap { name in parse(fileName: name).map { (name, $0.date) } }
            .filter { parse(fileName: $0.0)?.kind == kind }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return Array(ofKind.dropLast(keep))
    }

    /// Automatic backups run when none was made yet or the last one is at least `interval` old.
    /// A last date in the future (clock changed) counts as due.
    static func isAutomaticBackupDue(last: Date?, now: Date, interval: TimeInterval = automaticInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now.addingTimeInterval(60)
    }
}

// MARK: - Presets

/// An override preset as stored in the backup (target in mg/dL, 0 = no override target).
struct BackupOverridePreset: Codable, Equatable {
    var name: String
    var orderPosition: Int
    var duration: Decimal
    var indefinite: Bool
    var percentage: Double
    var target: Decimal
    var smbIsOff: Bool
    var smbIsScheduledOff: Bool
    var start: Decimal?
    var end: Decimal?
    var advancedSettings: Bool
    var smbMinutes: Decimal?
    var uamMinutes: Decimal?
    var isfAndCr: Bool
    var isf: Bool
    var cr: Bool
}

/// A temp target preset as stored in the backup (target in mg/dL).
struct BackupTempTargetPreset: Codable, Equatable {
    var name: String
    var orderPosition: Int
    var duration: Decimal
    var target: Decimal
    /// nil = the half basal target of the algorithm settings.
    var halfBasalTarget: Decimal?
}

enum BackupPresets {
    /// Comparable form of a preset name.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Splits `incoming` into presets that update an existing one with the same name and new ones.
    static func merge<T>(
        _ incoming: [T],
        existingNames: [String],
        name: (T) -> String
    ) -> (updates: [T], additions: [T]) {
        let existing = Set(existingNames.map(key))
        var seen = Set<String>()
        var updates: [T] = []
        var additions: [T] = []
        for preset in incoming {
            let presetKey = key(name(preset))
            guard !presetKey.isEmpty, seen.insert(presetKey).inserted else { continue }
            if existing.contains(presetKey) { updates.append(preset) } else { additions.append(preset) }
        }
        return (updates, additions)
    }
}

// MARK: - Password-protected part

/// What only goes into a backup encrypted with the backup password.
struct SettingsBackupPrivate: Codable, Equatable {
    /// `PumpManager.rawValue` as a binary property list.
    var pumpManagerState: Data?
    var pumpName: String?
    var nightscoutURL: String?
    var nightscoutSecret: String?
    /// API key per `MealPhotoProvider.rawValue`.
    var aiAPIKeys: [String: String]?

    var hasPasswords: Bool {
        nightscoutURL != nil || nightscoutSecret != nil || !(aiAPIKeys ?? [:]).isEmpty
    }

    var isEmpty: Bool { pumpManagerState == nil && !hasPasswords }
}

/// AES-GCM ciphertext with the PBKDF2 parameters needed to derive its key from the password.
struct SealedBackupPart: Codable, Equatable {
    var algorithm: String = SettingsBackupVault.algorithm
    let rounds: Int
    let salt: Data
    /// Nonce, ciphertext and tag (`AES.GCM.SealedBox.combined`).
    let box: Data
}

enum SettingsBackupVault {
    static let algorithm = "AES-256-GCM, PBKDF2-HMAC-SHA256"
    static let defaultRounds = 310_000
    static let minimumPasswordLength = 8

    static func key(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedCount = derived.count
        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    &derived,
                    derivedCount
                )
            }
        }
        guard status == Int32(kCCSuccess) else { throw SettingsBackupError.wrongPassword }
        return SymmetricKey(data: derived)
    }

    static func seal(_ data: Data, password: String, rounds: Int = defaultRounds) throws -> SealedBackupPart {
        guard password.count >= minimumPasswordLength else { throw SettingsBackupError.passwordTooShort }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let symmetricKey = try key(password: password, salt: salt, rounds: rounds)
        guard let combined = try AES.GCM.seal(data, using: symmetricKey).combined else {
            throw SettingsBackupError.fileError("AES-GCM")
        }
        return SealedBackupPart(rounds: rounds, salt: salt, box: combined)
    }

    static func open(_ part: SealedBackupPart, password: String) throws -> Data {
        guard part.rounds > 0, part.rounds <= 10_000_000, !part.salt.isEmpty else { throw SettingsBackupError.wrongPassword }
        do {
            let symmetricKey = try key(password: password, salt: part.salt, rounds: part.rounds)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: part.box), using: symmetricKey)
        } catch {
            throw SettingsBackupError.wrongPassword
        }
    }
}
