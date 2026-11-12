import Foundation

/// Everything autoISF works out for one loop cycle before the dosing stages run. Only built
/// when autoISF is on; with it off the determination takes the unchanged oref path.
struct AutoISFLoopContext {
    let engine: AutoISFEngineResult
    let b30: B30Result
    let units: GlucoseUnits
    /// An override switches SMBs off (always or by schedule).
    let overrideDisablesSmb: Bool
    /// Whether the user's SMB settings allow SMBs right now; autoISF's even target may only
    /// permit SMBs when they do.
    let profileSmbEnabled: Bool

    static func evaluate(
        profile: Profile,
        mealData: ComputedCarbs,
        pumpHistory: [PumpHistoryEvent],
        currentTime: Date,
        currentGlucose: Decimal,
        glucoseStatus: GlucoseStatus,
        basal: Decimal,
        targetGlucose: Decimal,
        dynamicIsfActive: Bool,
        adjustedSensitivity: Decimal,
        profileSensitivity: Decimal,
        sensitivityRatio: Decimal,
        microBolusAllowed: Bool,
        iob: Decimal,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        autoISFStatus: AutoISFGlucoseStatus?
    ) throws -> AutoISFLoopContext {
        let units = profile.outUnits ?? .mgdL
        let b30 = AimiB30.evaluate(
            profile: profile,
            pumpHistory: pumpHistory,
            currentTime: currentTime,
            targetBG: targetGlucose,
            currentBG: glucoseStatus.glucose,
            bgDelta: glucoseStatus.delta,
            basal: basal
        )
        let overrideDisablesSmb = trioCustomOrefVariables.smbIsOff ||
            (
                (try? DosingEngine.isSmbScheduledOff(trioCustomOrefVariables: trioCustomOrefVariables, clock: currentTime)) ??
                    false
            )
        let profileSmbEnabled = try DosingEngine.isProfileSmbEnabled(
            currentGlucose: currentGlucose,
            adjustedTargetGlucose: targetGlucose,
            profile: profile,
            meal: mealData,
            trioCustomOrefVariables: trioCustomOrefVariables,
            clock: currentTime
        )
        let engine = AutoISF.run(
            profile: profile,
            dynamicIsfActive: dynamicIsfActive,
            adjustedSensitivity: adjustedSensitivity,
            profileSens: profileSensitivity,
            targetBG: targetGlucose,
            units: units,
            currentGlucose: currentGlucose,
            sensitivityRatio: sensitivityRatio,
            originalSensitivity: profileSensitivity,
            microBolusAllowed: microBolusAllowed,
            iob: iob,
            b30IsActive: b30.isActive,
            autoISFStatus: autoISFStatus,
            overrideSmbIsOff: overrideDisablesSmb,
            orefSmbEnabled: profileSmbEnabled
        )
        return AutoISFLoopContext(
            engine: engine,
            b30: b30,
            units: units,
            overrideDisablesSmb: overrideDisablesSmb,
            profileSmbEnabled: profileSmbEnabled
        )
    }
}
