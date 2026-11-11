import Foundation
import Testing
@testable import Trio

@Suite("Settings Backup") struct SettingsBackupTests {
    // MARK: - Fixtures

    private static func backup(
        basal: [BasalProfileEntry] = [
            BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 0.8),
            BasalProfileEntry(start: "06:00:00", minutes: 360, rate: 1.2)
        ],
        pumpSettings: PumpSettings? = PumpSettings(insulinActionCurve: 9, maxBolus: 8, maxBasal: 3),
        settings: TrioSettings? = TrioSettings(),
        preferences: Preferences? = Preferences()
    ) -> SettingsBackup {
        SettingsBackup(
            created: Date(timeIntervalSince1970: 1_793_000_000),
            kind: .manual,
            appVersion: "1.0.2.29",
            build: "dev abc123",
            pumpInsulinConcentration: .u200,
            settings: settings,
            preferences: preferences,
            pumpSettings: pumpSettings,
            basalProfile: basal,
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 45, offset: 0, start: "00:00:00")]
            ),
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 10)]),
            bgTargets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: 100, high: 100, start: "00:00:00", offset: 0)]
            ),
            extras: [MealCarbTypeSettings.fpuInsulinPercentKey: 60]
        )
    }

    /// Sections of a backup without presets and without a protected part.
    private static let allSections: Set<BackupSection> = [.therapy, .limits, .algorithm, .app]

    // MARK: - File format

    @Test("Encode and decode round trip") func roundTrip() throws {
        let original = Self.backup()
        let decoded = try SettingsBackup.decode(from: original.encoded())

        #expect(decoded.created == original.created)
        #expect(decoded.kind == .manual)
        #expect(decoded.pumpInsulinConcentration == .u200)
        #expect(decoded.basalProfile == original.basalProfile)
        #expect(decoded.pumpSettings?.maxBasal == 3)
        #expect(decoded.pumpSettings?.insulinActionCurve == 9)
        #expect(decoded.insulinSensitivities?.sensitivities.first?.sensitivity == 45)
        #expect(decoded.carbRatios?.schedule.first?.ratio == 10)
        #expect(decoded.bgTargets?.targets.first?.low == 100)
        #expect(decoded.extras?[MealCarbTypeSettings.fpuInsulinPercentKey] == 60)
        #expect(decoded.settings?.units == original.settings?.units)
        #expect(decoded.settings?.high == original.settings?.high)
        #expect(decoded.preferences?.maxIOB == original.preferences?.maxIOB)
        #expect(decoded.preferences?.enableUAM == original.preferences?.enableUAM)
        #expect(decoded.unreadableParts.isEmpty)
        #expect(Set(decoded.availableSections) == Self.allSections)
    }

    @Test("Basal rates survive without binary noise") func basalPrecision() throws {
        let basal = [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: Decimal(string: "0.15")!)]
        let decoded = try SettingsBackup.decode(from: Self.backup(basal: basal).encoded())
        #expect(decoded.basalProfile?.first?.rate == Decimal(string: "0.15")!)
    }

    @Test("A broken part is skipped, the rest stays usable") func unreadablePart() throws {
        var json = try JSONSerialization.jsonObject(with: Self.backup().encoded()) as! [String: Any]
        json["carbRatios"] = ["units": "grams", "schedule": "not a list"]
        let decoded = try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: json))

        #expect(decoded.carbRatios == nil)
        #expect(decoded.unreadableParts == ["carbRatios"])
        #expect(decoded.basalProfile != nil)
        #expect(decoded.availableSections.contains(.therapy))
    }

    @Test("Other files are rejected") func notABackup() {
        #expect(throws: SettingsBackupError.notABackup) {
            try SettingsBackup.decode(from: Data(#"{"hello": "world"}"#.utf8))
        }
        #expect(throws: SettingsBackupError.self) {
            try SettingsBackup.decode(from: Data("no json".utf8))
        }
    }

    @Test("Backups of a newer format are rejected") func newerVersion() throws {
        var json = try JSONSerialization.jsonObject(with: Self.backup().encoded()) as! [String: Any]
        json["version"] = SettingsBackup.currentVersion + 1
        #expect(throws: SettingsBackupError.unsupportedVersion(SettingsBackup.currentVersion + 1)) {
            try SettingsBackup.decode(from: JSONSerialization.data(withJSONObject: json))
        }
    }

    // MARK: - Validation

    @Test("A complete backup passes") func validBackup() {
        #expect(Self.backup().validationIssues(for: Self.allSections, currentMaxBasal: 2).isEmpty)
    }

    @Test("Basal above max basal is refused") func basalAboveMaxBasal() {
        let basal = [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 2.5)]
        let backup = Self.backup(basal: basal)
        // with limits restored too, the restored max basal (3) counts …
        #expect(backup.validationIssues(for: Self.allSections, currentMaxBasal: 2).isEmpty)
        // … otherwise the current one (2)
        #expect(backup.validationIssues(for: [.therapy], currentMaxBasal: 2).count == 1)
    }

    @Test("Zero basal and broken schedules are refused") func brokenSchedules() {
        let zero = Self.backup(basal: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 0)])
        #expect(!zero.validationIssues(for: [.therapy], currentMaxBasal: 2).isEmpty)

        let lateStart = Self.backup(basal: [BasalProfileEntry(start: "01:00:00", minutes: 60, rate: 1)])
        #expect(!lateStart.validationIssues(for: [.therapy], currentMaxBasal: 2).isEmpty)

        let unordered = Self.backup(basal: [
            BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1),
            BasalProfileEntry(start: "06:00:00", minutes: 360, rate: 1),
            BasalProfileEntry(start: "03:00:00", minutes: 180, rate: 1)
        ])
        #expect(!unordered.validationIssues(for: [.therapy], currentMaxBasal: 2).isEmpty)

        let empty = Self.backup(basal: [])
        #expect(!empty.validationIssues(for: [.therapy], currentMaxBasal: 2).isEmpty)
    }

    @Test("Limits outside the editor ranges are refused") func limitRanges() {
        let backup = Self.backup(pumpSettings: PumpSettings(insulinActionCurve: 4, maxBolus: 40, maxBasal: 3))
        #expect(backup.validationIssues(for: [.limits], currentMaxBasal: 2).count == 2)
        // not checked when limits are not restored
        #expect(backup.validationIssues(for: [.app], currentMaxBasal: 2).isEmpty)
    }

    @Test("ISF, carb ratio and target ranges") func therapyRanges() {
        var backup = Self.backup()
        backup.insulinSensitivities = InsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [InsulinSensitivityEntry(sensitivity: 3, offset: 0, start: "00:00:00")]
        )
        backup.carbRatios = CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 80)])
        backup.bgTargets = BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [BGTargetEntry(low: 60, high: 60, start: "00:00:00", offset: 0)]
        )
        #expect(backup.validationIssues(for: [.therapy], currentMaxBasal: 2).count == 3)
    }

    // MARK: - Device-bound values

    @Test("Concentration, dosing mode and CGM stay as they are") func deviceBoundSettings() {
        var fromBackup = TrioSettings()
        fromBackup.pumpInsulinConcentration = .u100
        fromBackup.dosingMode = .closed
        fromBackup.cgm = .xdrip
        fromBackup.high = 200

        var current = TrioSettings()
        current.pumpInsulinConcentration = .u200
        current.pumpInsulinConcentrationSyncPending = true
        current.dosingMode = .open
        current.cgm = .plugin
        current.cgmPluginIdentifier = "G7"

        let restored = SettingsBackup.restoredSettings(fromBackup, keeping: current)
        #expect(restored.pumpInsulinConcentration == .u200)
        #expect(restored.pumpInsulinConcentrationSyncPending)
        #expect(restored.dosingMode == .open)
        #expect(restored.cgm == .plugin)
        #expect(restored.cgmPluginIdentifier == "G7")
        // everything else comes from the backup
        #expect(restored.high == 200)
    }

    @Test("Bolus step stays as it is") func bolusIncrement() {
        var fromBackup = Preferences()
        fromBackup.bolusIncrement = 0.05
        fromBackup.maxIOB = 6
        var current = Preferences()
        current.bolusIncrement = 0.1

        let restored = SettingsBackup.restoredPreferences(fromBackup, keeping: current)
        #expect(restored.bolusIncrement == 0.1)
        #expect(restored.maxIOB == 6)
    }

    // MARK: - File names, retention, schedule

    @Test("File names encode date and kind") func fileNames() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        for kind in BackupKind.allCases {
            let name = SettingsBackupFiles.fileName(for: date, kind: kind)
            let parsed = try #require(SettingsBackupFiles.parse(fileName: name))
            #expect(parsed.kind == kind)
            #expect(parsed.date == date)
        }
        #expect(SettingsBackupFiles.parse(fileName: "notes.json") == nil)
        #expect(SettingsBackupFiles.parse(fileName: "Trio-Backup-garbage-auto.json") == nil)
    }

    @Test("Only the 5 newest automatic backups are kept") func retention() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let automatic = (0 ..< 7).map {
            SettingsBackupFiles.fileName(for: base.addingTimeInterval(Double($0) * 7 * 86400), kind: .automatic)
        }
        let manual = (0 ..< 9).map { SettingsBackupFiles.fileName(for: base.addingTimeInterval(Double($0)), kind: .manual) }
        let names = (automatic + manual + ["readme.txt"]).shuffled()

        #expect(SettingsBackupFiles.namesToPrune(names, kind: .automatic) == Array(automatic.prefix(2)))
        #expect(SettingsBackupFiles.namesToPrune(names, kind: .manual).isEmpty)
    }

    @Test("Automatic backup every 7 days") func due() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(SettingsBackupFiles.isAutomaticBackupDue(last: nil, now: now))
        #expect(!SettingsBackupFiles.isAutomaticBackupDue(last: now.addingTimeInterval(-6 * 86400), now: now))
        #expect(SettingsBackupFiles.isAutomaticBackupDue(last: now.addingTimeInterval(-7 * 86400), now: now))
        // clock set back: a "future" backup must not block backups for days
        #expect(SettingsBackupFiles.isAutomaticBackupDue(last: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - Presets

    private static func overridePreset(_ name: String, percentage: Double = 80, target: Decimal = 0) -> BackupOverridePreset {
        BackupOverridePreset(
            name: name,
            orderPosition: 1,
            duration: 60,
            indefinite: false,
            percentage: percentage,
            target: target,
            smbIsOff: false,
            smbIsScheduledOff: false,
            start: nil,
            end: nil,
            advancedSettings: false,
            smbMinutes: nil,
            uamMinutes: nil,
            isfAndCr: true,
            isf: true,
            cr: true
        )
    }

    @Test("Presets survive a round trip and are a section") func presetsRoundTrip() throws {
        var original = Self.backup()
        original.overridePresets = [Self.overridePreset("Sport", target: 140)]
        original.tempTargetPresets = [BackupTempTargetPreset(
            name: "Eating Soon",
            orderPosition: 1,
            duration: 45,
            target: 80,
            halfBasalTarget: nil
        )]
        let decoded = try SettingsBackup.decode(from: original.encoded())
        #expect(decoded.overridePresets == original.overridePresets)
        #expect(decoded.tempTargetPresets == original.tempTargetPresets)
        #expect(decoded.availableSections.contains(.presets))
        #expect(!Self.backup().availableSections.contains(.presets))
        #expect(decoded.validationIssues(for: [.presets], currentMaxBasal: 2).isEmpty)
    }

    @Test("Presets outside the allowed ranges are refused") func presetRanges() {
        var backup = Self.backup()
        backup.overridePresets = [Self.overridePreset(" "), Self.overridePreset("Too much", percentage: 500)]
        backup.tempTargetPresets = [BackupTempTargetPreset(
            name: "Low",
            orderPosition: 1,
            duration: 30,
            target: 50,
            halfBasalTarget: nil
        )]
        #expect(backup.validationIssues(for: [.presets], currentMaxBasal: 2).count == 3)
        // not selected: not checked
        #expect(backup.validationIssues(for: [.therapy], currentMaxBasal: 2).isEmpty)
    }

    @Test("Override presets without a target (0, or 6 from older versions) are accepted") func presetWithoutTarget() {
        var backup = Self.backup()
        backup.overridePresets = [
            Self.overridePreset("Insulin anheben 135%", percentage: 135, target: 6),
            Self.overridePreset("Dexcom Jump 45", percentage: 100, target: 6),
            Self.overridePreset("Sport", target: 0)
        ]
        #expect(backup.validationIssues(for: [.presets], currentMaxBasal: 2).isEmpty)
        // a real target below 72 mg/dL stays refused
        backup.overridePresets = [Self.overridePreset("Too low", target: 50)]
        #expect(backup.validationIssues(for: [.presets], currentMaxBasal: 2).count == 1)
    }

    @Test("Presets merge by name: same name updates, duplicates in the file count once") func presetMerge() {
        let incoming = [Self.overridePreset("Sport"), Self.overridePreset("Night"), Self.overridePreset(" night ")]
        let merged = BackupPresets.merge(incoming, existingNames: ["sport ", "Party"], name: \.name)
        #expect(merged.updates.map(\.name) == ["Sport"])
        #expect(merged.additions.map(\.name) == ["Night"])
    }

    // MARK: - Password-protected part

    private static let secrets = SettingsBackupPrivate(
        pumpManagerState: try? PropertyListSerialization.data(
            fromPropertyList: ["managerIdentifier": "Omnipod", "state": ["podID": 42]],
            format: .binary,
            options: 0
        ),
        pumpName: "Omnipod",
        nightscoutURL: "https://ns.example.org",
        nightscoutSecret: "secret-1234",
        aiAPIKeys: ["anthropic": "sk-test"]
    )

    @Test("The protected part opens only with the right password") func vault() throws {
        let data = try JSONCoding.encoder.encode(Self.secrets)
        let sealed = try SettingsBackupVault.seal(data, password: "correct horse", rounds: 1000)
        #expect(sealed.salt.count == 16)
        #expect(!String(decoding: sealed.box, as: UTF8.self).contains("secret-1234"))
        #expect(try SettingsBackupVault.open(sealed, password: "correct horse") == data)
        #expect(throws: SettingsBackupError.wrongPassword) {
            try SettingsBackupVault.open(sealed, password: "wrong horse")
        }
        #expect(throws: SettingsBackupError.passwordTooShort) {
            try SettingsBackupVault.seal(data, password: "short", rounds: 1000)
        }
    }

    @Test("Pump pairing and passwords appear only after unlocking") func unlocking() throws {
        var original = Self.backup()
        original.sealed = try SettingsBackupVault.seal(
            JSONCoding.encoder.encode(Self.secrets),
            password: "correct horse",
            rounds: 1000
        )
        let file = try original.encoded()
        #expect(!String(decoding: file, as: UTF8.self).contains("secret-1234"))

        let decoded = try SettingsBackup.decode(from: file)
        #expect(decoded.isLocked)
        #expect(!decoded.availableSections.contains(.passwords))
        #expect(!decoded.availableSections.contains(.pumpPairing))
        #expect(throws: SettingsBackupError.wrongPassword) {
            try decoded.unlocked(password: "nope nope")
        }

        let unlocked = try decoded.unlocked(password: "correct horse")
        #expect(!unlocked.isLocked)
        #expect(unlocked.unsealed == Self.secrets)
        #expect(unlocked.availableSections.contains(.passwords))
        #expect(unlocked.availableSections.contains(.pumpPairing))
        // the decrypted part is never written back in plain text
        #expect(try !String(decoding: unlocked.encoded(), as: UTF8.self).contains("secret-1234"))
    }

    @Test("Pump pairing only without a pump and with the same concentration") func pumpPairingRules() {
        let backup = Self.backup() // made with U200
        #expect(backup.pumpPairingProblem(pumpIsSetUp: false, currentConcentration: .u200) == nil)
        #expect(backup.pumpPairingProblem(pumpIsSetUp: true, currentConcentration: .u200) == .pumpAlreadySetUp)
        #expect(
            backup.pumpPairingProblem(pumpIsSetUp: false, currentConcentration: .u100) ==
                .pumpConcentrationMismatch(
                    backup: InsulinConcentration.u200.displayName,
                    current: InsulinConcentration.u100.displayName
                )
        )
    }
}
