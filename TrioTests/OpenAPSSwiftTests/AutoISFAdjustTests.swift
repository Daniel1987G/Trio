import Foundation
import Testing
@testable import Trio

/// Unit tests for `AutoISFAdjust.calculate` — the autoISF 3.01 ISF-adjustment math
/// (acce_ISF, bg_ISF, pp_ISF, dura_ISF) ported from determine-basal.js.
///
/// Style mirrors `DynamicISFTests`: a single `createDependencies` helper produces
/// the inputs (Profile, AutoISFGlucoseStatus, scalar args) and each test tweaks
/// only the fields it cares about.
@Suite("AutoISFAdjust Calculation Tests") struct AutoISFAdjustTests {
    /// Common dependencies for AutoISFAdjust tests.
    /// Defaults are tuned so the calculation runs in the "not modified" path —
    /// individual tests opt into specific weights / glucose conditions.
    private func createDependencies(
        autoisf: Bool = true,
        autoISFoffSport: Bool = false,
        autoISFmin: Decimal = 0.7,
        autoISFmax: Decimal = 1.2,
        higherISFrangeWeight: Decimal = 0,
        lowerISFrangeWeight: Decimal = 0,
        postMealISFweight: Decimal = 0,
        autoISFhourlyChange: Decimal = 0,
        enableBGacceleration: Bool = false,
        bgAccelISFweight: Decimal = 0,
        bgBrakeISFweight: Decimal = 0,
        glucose: Decimal = 120,
        delta: Decimal = 0,
        shortAvgDelta: Decimal = 0,
        longAvgDelta: Decimal = 0,
        bgAcceleration: Decimal = 0,
        rSqu: Decimal = 0,
        duraISFminutes: Decimal = 0,
        duraISFaverage: Decimal = 0
    ) -> (Profile, AutoISFGlucoseStatus, sens: Decimal, profileSens: Decimal, targetBG: Decimal, sensitivityRatio: Decimal) {
        var profile = Profile()
        profile.autoisf = autoisf
        profile.autoISFoffSport = autoISFoffSport
        profile.autoISFmin = autoISFmin
        profile.autoISFmax = autoISFmax
        profile.higherISFrangeWeight = higherISFrangeWeight
        profile.lowerISFrangeWeight = lowerISFrangeWeight
        profile.postMealISFweight = postMealISFweight
        profile.autoISFhourlyChange = autoISFhourlyChange
        profile.enableBGacceleration = enableBGacceleration
        profile.bgAccelISFweight = bgAccelISFweight
        profile.bgBrakeISFweight = bgBrakeISFweight

        let baseStatus = GlucoseStatus(
            delta: delta,
            glucose: glucose,
            noise: 0,
            shortAvgDelta: shortAvgDelta,
            longAvgDelta: longAvgDelta,
            date: Date(),
            lastCalIndex: nil,
            device: nil
        )

        let autoStatus = AutoISFGlucoseStatus(
            glucoseStatus: baseStatus,
            cgmFlatMinutes: 0,
            dura_ISF_minutes: duraISFminutes,
            dura_ISF_average: duraISFaverage,
            dura_p: 0,
            delta_pl: 0,
            delta_pn: 0,
            bg_acceleration: bgAcceleration,
            r_squ: rSqu,
            a_0: 0,
            a_1: 0,
            a_2: 0,
            debugInfo: ""
        )

        return (profile, autoStatus, sens: 50, profileSens: 50, targetBG: 100, sensitivityRatio: 1)
    }

    @Test("Returns nil when autoISF is disabled") func disabledReturnsNil() throws {
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(autoisf: false)

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )

        #expect(result == nil)
    }

    @Test("Returns nil when off-sport bypass is active during exercise") func offSportBypass() throws {
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(autoISFoffSport: true)

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: true,
            resistanceModeActive: false
        )

        #expect(result == nil)
    }

    @Test("Returns identity result when no weights modify ISF") func notModifiedAllZeroWeights() throws {
        // glucose=120, target=100, all weights=0 → bgISF=1, ppISF=1, duraISF=1, acceISF=1
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies()

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.adjustedSens == sens)
        #expect(result.acceISFratio == 1)
        #expect(result.bgISFratio == 1)
        #expect(result.ppISFratio == 1)
        #expect(result.duraISFratio == 1)
        #expect(result.autoISFratio == 1)
    }

    @Test("bg_ISF below target triggers early decelerating return path") func bgISFBelowTargetEarlyReturn() throws {
        // glucose=80, target=100 → bgOff=30, xdata=70 → rawVal=-0.4, lowerWeight=1 → bgISF=0.6 (<1)
        // finalISF clamped to autoISFmin=0.7, adjustedSens = round(50/0.7, 1) = 71.4
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            lowerISFrangeWeight: 1,
            glucose: 80
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.bgISFratio.rounded(toPlaces: 2) == Decimal(string: "0.6"))
        #expect(result.adjustedSens == Decimal(string: "71.4"))
        #expect(result.autoISFratio.rounded(toPlaces: 2) == Decimal(string: "0.7"))
        #expect(result.ppISFratio == 1)
        #expect(result.duraISFratio == 1)
    }

    @Test("pp_ISF triggers above target on rising glucose") func ppISFActivation() throws {
        // glucose=130, target=100, bgOff=-20, shortAvgDelta>=0, delta=10, ppWeight=0.05
        // ppISF = 1 + 10*0.05 = 1.5 → clamped to autoISFmax=1.2
        // adjustedSens = round(50/1.2, 1) = 41.7
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            postMealISFweight: 0.05,
            glucose: 130,
            delta: 10,
            shortAvgDelta: 5
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.ppISFratio.rounded(toPlaces: 2) == Decimal(string: "1.5"))
        #expect(result.adjustedSens == Decimal(string: "41.7"))
        #expect(result.autoISFratio.rounded(toPlaces: 2) == Decimal(string: "1.2"))
    }

    @Test("dura_ISF triggers when sustained above target") func duraISFActivation() throws {
        // dura=30 min, avg=110 (>target 100), hourlyChange=5
        // duraISF = 1 + (30/60)*(5/100)*(110-100) = 1 + 0.5*0.05*10 = 1.25
        // clamped to autoISFmax=1.2 → adjustedSens = round(50/1.2, 1) = 41.7
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            autoISFhourlyChange: 5,
            glucose: 120,
            duraISFminutes: 30,
            duraISFaverage: 110
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.duraISFratio.rounded(toPlaces: 2) == Decimal(string: "1.25"))
        #expect(result.adjustedSens == Decimal(string: "41.7"))
        #expect(result.autoISFratio.rounded(toPlaces: 2) == Decimal(string: "1.2"))
    }

    @Test("Acceleration above target with reliable fit applies brake weight") func accelerationBrake() throws {
        // glucose=150, target=100, bgAcce=-0.5 (decelerating), r²=0.95, brakeWeight=0.5
        // fitShare = 10*(0.95-0.9) = 0.5; acceISF = 1 + (-0.5)*1*0.5*0.5 = 0.875
        // higherISFrangeWeight=1: bgISF rises (xdata=140 → rawVal=0.375 → bgISF=1.38)
        // sensModified=true (bgISF>1); liftISF = 1.38 * 0.875 = 1.2075 (acce<1 brakes)
        // clamped to 1.2 → adjustedSens = round(50/1.2, 1) = 41.7
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            higherISFrangeWeight: 1,
            enableBGacceleration: true,
            bgBrakeISFweight: 0.5,
            glucose: 150,
            bgAcceleration: -0.5,
            rSqu: Decimal(string: "0.95")!
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.acceISFratio.rounded(toPlaces: 2) == Decimal(string: "0.88"))
        #expect(result.bgISFratio.rounded(toPlaces: 2) == Decimal(string: "1.38"))
        #expect(result.adjustedSens == Decimal(string: "41.7"))
    }

    @Test("Acceleration brake alone modifies adjustedSens") func accelerationAloneTriggersModification() throws {
        // Mirrors JS `acce_ISF != 1 → sens_modified = true` (determine-basal.js line 443).
        // No bg/pp/dura signal, but acceISF=0.875 from a pure brake → adjustedSens must change.
        // glucose=150 (above target), bgAcce=-0.5, brakeWeight=0.5, r²=0.95 → acceISF=0.875
        // liftISF = max(1,1,0.875,1) * 0.875 = 0.875 (acce<1 brakes); finalISF=0.875
        // adjustedSens = round(50/0.875, 1) = 57.1
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            enableBGacceleration: true,
            bgBrakeISFweight: 0.5,
            glucose: 150,
            bgAcceleration: -0.5,
            rSqu: Decimal(string: "0.95")!
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.acceISFratio.rounded(toPlaces: 2) == Decimal(string: "0.88"))
        #expect(result.bgISFratio == 1)
        #expect(result.adjustedSens == Decimal(string: "57.1"))
    }

    @Test("Predictive brake fires when parabola predicts BG below target soon") func predictiveBrake() throws {
        // Mirrors JS predictive brake (determine-basal.js lines 399-406): a future
        // minimum below target within 30 min installs `acceWeight = -bgBrakeISFweight`
        // even when the standard above-target branch would otherwise apply accel.
        //
        // Construct a parabola whose vertex (min) is 5 min in the future at BG=80:
        //   tVertex = -a₁/(2·a₂) = -(-0.5)/(2·0.05) = 5 (in 5-min blocks → 25 min × 5/5? )
        // Actually JS: minmax_delta = -a1/(2*a2) * 5 (1-min units).
        // With a₁=-0.5, a₂=0.05: tBlocks = 5 → minmax_delta = 25 min, ≤ 30 ✓
        // minmax_value = a₀ - tBlocks² · a₂ = 81.25 - 25·0.05 = 80, < target 100 ✓
        // bgAcce=2·a₂=0.1 > 0 ✓; r²=0.95 ✓; glucose=110 (above target → would normally apply accel)
        //   → predictive overrides: acceWeight = -bgBrakeISFweight = -1
        //   → acceISF = 1 + 0.1·1·(-1)·0.5 = 0.95
        var profile = Profile()
        profile.autoisf = true
        profile.autoISFmin = Decimal(string: "0.7")!
        profile.autoISFmax = Decimal(string: "1.2")!
        profile.enableBGacceleration = true
        profile.bgBrakeISFweight = 1
        profile.bgAccelISFweight = 1

        let baseStatus = GlucoseStatus(
            delta: 0, glucose: 110, noise: 0, shortAvgDelta: 0, longAvgDelta: 0,
            date: Date(), lastCalIndex: nil, device: nil
        )
        let status = AutoISFGlucoseStatus(
            glucoseStatus: baseStatus,
            cgmFlatMinutes: 0, dura_ISF_minutes: 0, dura_ISF_average: 0,
            dura_p: 0, delta_pl: 0, delta_pn: 0,
            bg_acceleration: Decimal(string: "0.1")!,
            r_squ: Decimal(string: "0.95")!,
            a_0: Decimal(string: "81.25")!,
            a_1: Decimal(string: "-0.5")!,
            a_2: Decimal(string: "0.05")!,
            debugInfo: ""
        )

        let result = AutoISFAdjust.calculate(
            sens: 50,
            profileSens: 50,
            targetBG: 100,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: 1,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        // Without predictive: bg(110)>target → accel branch, acceWeight=+1 → acceISF=1.05.
        // With predictive: acceWeight = -1 → acceISF = 1 + 0.1·1·(-1)·0.5 = 0.95.
        #expect(result.acceISFratio.rounded(toPlaces: 2) == Decimal(string: "0.95"))
    }

    @Test("Acceleration ignored when fit correlation below threshold") func accelerationLowFitIgnored() throws {
        // r²=0.85 < 0.9 → acceISF stays 1 even with strong bgAcceleration
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            enableBGacceleration: true,
            bgBrakeISFweight: 1,
            glucose: 150,
            bgAcceleration: -2,
            rSqu: Decimal(string: "0.85")!
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.acceISFratio == 1)
    }

    @Test("Exercise mode multiplies autoISF and autosens factors") func exerciseModeMultiplies() throws {
        // ppISF=1.5 trigger; sensitivityRatio=0.8, exerciseModeActive=true
        // finalISF = clamp(1.5, [0.7, 1.2]) * sensitivityRatio = 1.2 * 0.8 = 0.96
        // adjustedSens = round(50/0.96, 1) = 52.1
        let (profile, status, sens, profileSens, targetBG, _) = createDependencies(
            postMealISFweight: 0.05,
            glucose: 130,
            delta: 10,
            shortAvgDelta: 5
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: Decimal(string: "0.8")!,
            exerciseModeActive: true,
            resistanceModeActive: false
        )!

        #expect(result.adjustedSens == Decimal(string: "52.1"))
        #expect(result.autoISFratio.rounded(toPlaces: 2) == Decimal(string: "0.96"))
    }

    @Test("Strong lift clamps to autoISFmax") func liftClampedAtMax() throws {
        // ppISF=11 (huge) but autoISFmax=1.2 → finalISF=1.2
        let (profile, status, sens, profileSens, targetBG, sensitivityRatio) = createDependencies(
            postMealISFweight: 1,
            glucose: 140,
            delta: 10,
            shortAvgDelta: 5
        )

        let result = AutoISFAdjust.calculate(
            sens: sens,
            profileSens: profileSens,
            targetBG: targetBG,
            profile: profile,
            glucoseStatus: status,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: false,
            resistanceModeActive: false
        )!

        #expect(result.adjustedSens == Decimal(string: "41.7")) // 50/1.2 rounded to 1 decimal
        #expect(result.autoISFratio.rounded(toPlaces: 2) == Decimal(string: "1.2"))
    }
}
