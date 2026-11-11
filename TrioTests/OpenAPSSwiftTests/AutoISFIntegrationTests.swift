import Foundation
import Testing
@testable import Trio

/// autoISF wired into determineBasal: off leaves the oref path alone, on adjusts ISF and SMBs,
/// and B30 never overrides the low glucose suspend.
@Suite("autoISF in determineBasal") struct AutoISFIntegrationTests {
    private struct Inputs {
        var profile: Profile
        var glucoseStatus: GlucoseStatus
        var iob: Decimal = 0.2
        var pumpHistory: [PumpHistoryEvent] = []
        var autoISFStatus: AutoISFGlucoseStatus?
        var preferences = Preferences()
        let now = Date()
    }

    private func baseInputs(glucose: Decimal = 190, delta: Decimal = 5) -> Inputs {
        var profile = Profile()
        profile.currentBasal = 1.0
        profile.maxDailyBasal = 1.5
        profile.maxBasal = 3.0
        profile.minBg = 100
        profile.maxBg = 100
        profile.targetBg = 100
        profile.sens = 40
        profile.carbRatio = 10
        profile.thresholdSetting = 70
        profile.maxIob = 6
        profile.enableSMBAlways = true
        profile.bolusIncrement = 0.1
        profile.outUnits = .mgdL

        let glucoseStatus = GlucoseStatus(
            delta: delta,
            glucose: glucose,
            noise: 1,
            shortAvgDelta: delta,
            longAvgDelta: delta,
            date: Date(),
            lastCalIndex: nil,
            device: "test"
        )
        return Inputs(profile: profile, glucoseStatus: glucoseStatus)
    }

    /// Flat history at the current glucose: only bg_ISF (glucose vs. target) can act.
    private func flatStatus(_ glucoseStatus: GlucoseStatus) -> AutoISFGlucoseStatus {
        AutoISFGlucoseStatus(
            glucoseStatus: glucoseStatus,
            cgmFlatMinutes: 0,
            dura_ISF_minutes: 0,
            dura_ISF_average: glucoseStatus.glucose,
            dura_p: 0,
            delta_pl: 0,
            delta_pn: 0,
            bg_acceleration: 0,
            r_squ: 0,
            a_0: 0,
            a_1: 0,
            a_2: 0,
            debugInfo: ""
        )
    }

    private func run(_ inputs: Inputs) throws -> Determination? {
        let now = inputs.now
        let iobData = [IobResult(
            iob: inputs.iob,
            activity: 0,
            basaliob: inputs.iob,
            bolusiob: 0,
            netbasalinsulin: 0,
            bolusinsulin: 0,
            time: now,
            iobWithZeroTemp: IobResult.IobWithZeroTemp(
                iob: inputs.iob,
                activity: 0,
                basaliob: inputs.iob,
                bolusiob: 0,
                netbasalinsulin: 0,
                bolusinsulin: 0,
                time: now
            ),
            lastBolusTime: UInt64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000),
            lastTemp: IobResult.LastTemp(
                rate: 0,
                timestamp: now,
                started_at: now,
                date: UInt64(now.timeIntervalSince1970 * 1000),
                duration: 30
            )
        )]
        return try DeterminationGenerator.determineBasal(
            profile: inputs.profile,
            preferences: inputs.preferences,
            currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
            iobData: iobData,
            mealData: ComputedCarbs(
                carbs: 0,
                mealCOB: 0,
                currentDeviation: 0,
                maxDeviation: 0,
                minDeviation: 0,
                slopeFromMaxDeviation: 0,
                slopeFromMinDeviation: 0,
                allDeviations: [0, 0, 0, 0, 0],
                lastCarbTime: 0
            ),
            autosensData: Autosens(ratio: 1.0, newisf: nil),
            reservoirData: 100,
            glucoseStatus: inputs.glucoseStatus,
            pumpHistory: inputs.pumpHistory,
            microBolusAllowed: true,
            autoISFStatus: inputs.autoISFStatus,
            trioCustomOrefVariables: TrioCustomOrefVariables(
                average_total_data: 0,
                weightedAverage: 0,
                currentTDD: 0,
                past2hoursAverage: 0,
                date: now,
                overridePercentage: 100,
                useOverride: false,
                duration: 0,
                unlimited: false,
                overrideTarget: 0,
                smbIsOff: false,
                advancedSettings: false,
                isfAndCr: false,
                isf: false,
                cr: false,
                smbIsScheduledOff: false,
                start: 0,
                end: 0,
                smbMinutes: 30,
                uamMinutes: 30
            ),
            currentTime: now
        )
    }

    @Test("autoISF off: settings are ignored and the reason has no autoISF tags") func offIsUnchanged() throws {
        let plain = try #require(try run(baseInputs()))

        var inputs = baseInputs()
        inputs.profile.higherISFrangeWeight = 1
        inputs.profile.iobThresholdPercent = Decimal(string: "0.01")!
        inputs.profile.smbMaxRangeExtension = 3
        inputs.autoISFStatus = flatStatus(inputs.glucoseStatus)
        let withSettings = try #require(try run(inputs))

        #expect(withSettings.isf == plain.isf)
        #expect(withSettings.units == plain.units)
        #expect(withSettings.rate == plain.rate)
        #expect(!withSettings.reason.contains("autoISF"))
        #expect(!withSettings.reason.contains("SMB Del.Ratio"))
    }

    @Test("High glucose lowers the ISF within autoISF max and shows it in the reason") func highGlucoseAdjustsISF() throws {
        var inputs = baseInputs(glucose: 190)
        inputs.profile.autoisf = true
        inputs.profile.higherISFrangeWeight = 1
        inputs.profile.autoISFmax = Decimal(string: "1.5")!
        inputs.autoISFStatus = flatStatus(inputs.glucoseStatus)

        let determination = try #require(try run(inputs))
        let isf = try #require(determination.isf)
        // bg_ISF at 190 mg/dL (80 above target + 10) is 1.5 with weight 1, so ISF 40 → 26.7
        #expect(isf < 40)
        #expect(isf >= 26)
        #expect(determination.reason.contains("ISF: 40→27"))
        #expect(determination.reason.contains("autoISF"))
        #expect(determination.reason.contains("SMB Del.Ratio: 0.5"))
        // the tags stay label + value in one part, as the loop status view splits on ", "
        #expect(!determination.reason.contains(":, "))
    }

    @Test("autoISF max limits the lift") func liftIsLimited() throws {
        var inputs = baseInputs(glucose: 300)
        inputs.profile.autoisf = true
        inputs.profile.higherISFrangeWeight = 2
        inputs.profile.autoISFmax = Decimal(string: "1.2")!
        inputs.autoISFStatus = flatStatus(inputs.glucoseStatus)

        let determination = try #require(try run(inputs))
        // 40 / 1.2 = 33.3
        #expect(determination.isf == 33)
    }

    @Test("IOB above the iobTH switches SMBs off") func iobThresholdBlocksSMB() throws {
        var inputs = baseInputs(glucose: 190)
        inputs.profile.autoisf = true
        inputs.profile.iobThresholdPercent = Decimal(string: "0.5")! // 3 U of max IOB 6
        inputs.iob = 4
        inputs.autoISFStatus = flatStatus(inputs.glucoseStatus)

        let determination = try #require(try run(inputs))
        #expect(determination.units == nil || determination.units == 0)
        #expect(determination.reason.contains("eff.iobTH: 3"))
    }

    @Test("Without a glucose history autoISF leaves the ISF alone") func noStatusNoAdjustment() throws {
        var inputs = baseInputs(glucose: 190)
        inputs.profile.autoisf = true
        inputs.profile.higherISFrangeWeight = 1
        inputs.autoISFStatus = nil // as if no status could be built
        let determination = try #require(try run(inputs))
        #expect(determination.isf == 40)
    }

    @Test("Dynamic ISF switched on: autoISF does nothing, even if it is stored as on") func neverWithDynamicISF() throws {
        var inputs = b30Inputs(glucose: 190, delta: 5)
        inputs.profile.higherISFrangeWeight = 1
        inputs.profile.iobThresholdPercent = Decimal(string: "0.1")!
        inputs.preferences.useNewFormula = true
        let determination = try #require(try run(inputs))
        #expect(!determination.reason.contains("autoISF"))
        #expect(!determination.reason.contains("AIMI B30"))
        #expect(!determination.reason.contains("SMB Del.Ratio"))
    }

    @Test("Stored settings with both on load with autoISF and B30 off") func storedConflictResolved() throws {
        let preferences = try JSONDecoder().decode(
            Preferences.self,
            from: Data(#"{"useNewFormula": true, "use_autoisf": true, "use_B30": true}"#.utf8)
        )
        #expect(preferences.useNewFormula)
        #expect(!preferences.autoisf)
        #expect(!preferences.enableB30)

        var onlyAutoISF = Preferences()
        onlyAutoISF.autoisf = true
        onlyAutoISF.resolveISFModeConflict()
        #expect(onlyAutoISF.autoisf)
    }

    // MARK: - B30

    private func b30Inputs(glucose: Decimal, delta: Decimal) -> Inputs {
        var inputs = baseInputs(glucose: glucose, delta: delta)
        inputs.profile.autoisf = true
        inputs.profile.enableB30 = true
        inputs.profile.B30iTimeStartBolus = 1
        inputs.profile.B30iTime = 30
        inputs.profile.B30iTimeTarget = 90
        inputs.profile.B30basalFactor = 5
        inputs.profile.minBg = 90
        inputs.profile.maxBg = 90
        inputs.profile.targetBg = 90
        inputs.profile.temptargetSet = true
        inputs.pumpHistory = [PumpHistoryEvent(
            id: "bolus",
            type: .bolus,
            timestamp: inputs.now.addingTimeInterval(-5 * 60),
            amount: 3,
            isSMB: false
        )]
        inputs.autoISFStatus = flatStatus(inputs.glucoseStatus)
        return inputs
    }

    @Test("B30 boost basal after a meal bolus with the eating soon target") func b30Boost() throws {
        let determination = try #require(try run(b30Inputs(glucose: 110, delta: 2)))
        #expect(determination.reason.contains("AIMI B30"))
        #expect(determination.duration == 30)
        // 1 U/h × 5, capped by the max safe basal (min of max basal 3, 3 × max daily 1.5, 4 × current 1)
        #expect(determination.rate == 3)
        #expect(determination.units == nil || determination.units == 0)
    }

    @Test("A low still suspends while the B30 window is open") func b30NeverOverridesLowSuspend() throws {
        let determination = try #require(try run(b30Inputs(glucose: 65, delta: -4)))
        #expect(determination.rate == 0)
        #expect(!determination.reason.contains("calculated AIMI B30"))
    }

    @Test("No B30 without the eating soon target") func b30NeedsTarget() throws {
        var inputs = b30Inputs(glucose: 110, delta: 2)
        inputs.profile.temptargetSet = false
        let determination = try #require(try run(inputs))
        #expect(!determination.reason.contains("AIMI B30"))
    }

    // MARK: - Settings plumbing

    @Test("Preferences without autoISF keys decode with autoISF off") func preferencesDefaultOff() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"max_iob": 5}"#.utf8))
        #expect(preferences.maxIOB == 5)
        #expect(preferences.autoisf == false)
        #expect(preferences.enableB30 == false)

        let stored = try JSONDecoder().decode(
            Preferences.self,
            from: Data(#"{"use_autoisf": true, "autoISF_max": 1.3, "iob_threshold_percent": 0.6}"#.utf8)
        )
        #expect(stored.autoisf)
        #expect(stored.autoISFmax == Decimal(string: "1.3")!)
        #expect(stored.iobThresholdPercent == Decimal(string: "0.6")!)
    }

    @Test("Profile takes the settings over without writing them to profile.json") func profileInjection() throws {
        var preferences = Preferences()
        preferences.autoisf = true
        preferences.autoISFmax = Decimal(string: "1.4")!
        preferences.enableB30 = true
        var profile = Profile()
        profile.applyAutoISF(from: preferences)
        #expect(profile.autoisf)
        #expect(profile.autoISFmax == Decimal(string: "1.4")!)
        #expect(profile.enableB30)

        let json = try String(data: JSONEncoder().encode(profile), encoding: .utf8) ?? ""
        #expect(!json.contains("autoisf"))
        #expect(!json.contains("autoISF"))
    }
}
