import Foundation

/// Output of the autoISF ISF-adjustment calculation.
/// All four sub-ratios are stored for logging and determination output.
struct AutoISFAdjustResult {
    /// The ISF value after autoISF adjustment (replaces `sens` for this loop iteration).
    let adjustedSens: Decimal
    /// Acceleration-based ISF ratio component (acce_ISF).
    let acceISFratio: Decimal
    /// BG-level-based ISF ratio component (bg_ISF).
    let bgISFratio: Decimal
    /// Post-prandial delta-based ISF ratio component (pp_ISF).
    let ppISFratio: Decimal
    /// Duration-at-high-BG ISF ratio component (dura_ISF).
    let duraISFratio: Decimal
    /// Combined autoISF factor applied to profileSens: profileSens / adjustedSens.
    let autoISFratio: Decimal
    /// Human-readable reason string for logging.
    let reason: String
}

/// Ports the `autoISF()` function from determine-basal.js (autoISF 3.01).
///
/// Computes an adjusted ISF by combining four sub-ratios:
/// - `acce_ISF`: BG acceleration from the parabola fit
/// - `bg_ISF`:   BG level relative to target via polygon interpolation
/// - `pp_ISF`:   Post-prandial glucose delta
/// - `dura_ISF`: Sustained duration of BG above target
///
/// Returns `nil` when autoISF is disabled or bypassed for exercise mode.
/// When enabled but no modification is warranted, returns a result with all ratios = 1
/// and the original `sens` unchanged.
enum AutoISFAdjust {
    // MARK: - Public interface

    static func calculate(
        sens: Decimal,
        profileSens: Decimal,
        targetBG: Decimal,
        profile: Profile,
        glucoseStatus: AutoISFGlucoseStatus,
        sensitivityRatio: Decimal,
        exerciseModeActive: Bool,
        resistanceModeActive: Bool
    ) -> AutoISFAdjustResult? {
        guard profile.autoisf else { return nil }
        guard !(profile.autoISFoffSport && exerciseModeActive) else { return nil }

        let bg = glucoseStatus.glucoseStatus.glucose
        // bg_off: positive when BG is below target+10, negative when above
        let bgOff = targetBG + 10 - bg
        let fitCorr = glucoseStatus.r_squ
        let bgAcce = glucoseStatus.bg_acceleration
        let dura05 = glucoseStatus.dura_ISF_minutes
        let avg05 = glucoseStatus.dura_ISF_average
        let bgDelta = glucoseStatus.glucoseStatus.delta
        let shortAvgDelta = glucoseStatus.glucoseStatus.shortAvgDelta

        // ---- acce_ISF ----
        var acceISF: Decimal = 1
        if profile.enableBGacceleration, fitCorr >= Decimal(string: "0.9")! {
            let fitShare = 10 * (fitCorr - Decimal(string: "0.9")!) // 0 at r²=0.9, 1 at r²=1.0
            // JS uses acceWeight=1 as a "not yet set" sentinel — predictive brake can
            // pre-empt the standard branch by assigning before the acceWeight==1 check.
            var acceWeight: Decimal = 1
            var capWeight: Decimal = 1

            // Predictive brake: parabola predicts BG dropping below target within 30 min.
            // Mirrors determine-basal.js (autoISF 3.01) lines 393-407.
            if glucoseStatus.a_2 != 0 {
                let minmaxDeltaUnrounded = -(glucoseStatus.a_1 / (2 * glucoseStatus.a_2)) * 5
                let minmaxValue = glucoseStatus.a_0
                    - minmaxDeltaUnrounded * minmaxDeltaUnrounded / 25 * glucoseStatus.a_2
                let minmaxDelta = minmaxDeltaUnrounded.jsRounded(scale: 0)
                if minmaxDelta > 0, bgAcce > 0, minmaxDelta <= 30, minmaxValue < targetBG {
                    acceWeight = -profile.bgBrakeISFweight
                }
            }

            if acceWeight == 1, bg < targetBG { // below target: acceleration goes towards target
                if bgAcce > 0 {
                    if bgAcce > 1 { capWeight = Decimal(string: "0.5")! }
                    acceWeight = profile.bgBrakeISFweight
                } else if bgAcce < 0 {
                    acceWeight = profile.bgAccelISFweight
                }
            } else if acceWeight == 1 { // above target: acceleration goes away from target
                if bgAcce < 0 {
                    acceWeight = profile.bgBrakeISFweight
                } else if bgAcce > 0 {
                    acceWeight = profile.bgAccelISFweight
                }
            }
            acceISF = 1 + bgAcce * capWeight * acceWeight * fitShare
            if acceISF < 0 { acceISF = Decimal(string: "0.1")! }
        }

        // ---- bg_ISF: polygon interpolation centred at target+10 ----
        let xdata = 100 - bgOff // maps glucose relative to target+10 onto the polygon x-axis
        let bgISF = (1 + interpolate(xdata, higherWeight: profile.higherISFrangeWeight, lowerWeight: profile.lowerISFrangeWeight))
            .jsRounded(scale: 2)

        // ---- early return: BG below target (bgISF < 1) ----
        // pp and dura are not evaluated; only bg and acce shape the response
        if bgISF < 1 {
            var liftISF = min(bgISF, acceISF)
            if acceISF > 1 {
                liftISF = bgISF * acceISF // accel already outweighs the low-BG brake, lift back
            }
            let finalISF = withinISFlimits(
                liftISF: liftISF,
                min: profile.autoISFmin,
                max: profile.autoISFmax,
                sensitivityRatio: sensitivityRatio,
                exerciseModeActive: exerciseModeActive,
                resistanceModeActive: resistanceModeActive
            )
            // Round to 1 decimal: integer rounding here would lose up to 0.5 mg/dL of
            // sens precision, which propagates into CR (= profile.carb_ratio × sens /
            // profile.sens) and flips the 1-decimal CR field.
            let adjustedSens = min(720, (profileSens / finalISF).jsRounded(scale: 1))
            let autoISFratio = adjustedSens > 0 ? (profileSens / adjustedSens).jsRounded(scale: 2) : 1
            return AutoISFAdjustResult(
                adjustedSens: adjustedSens,
                acceISFratio: acceISF.jsRounded(scale: 2),
                bgISFratio: bgISF,
                ppISFratio: 1,
                duraISFratio: 1,
                autoISFratio: autoISFratio,
                reason: AutoISFReason.adjustDeceleratingReason(
                    acceISFratio: acceISF.jsRounded(scale: 2),
                    bgISFratio: bgISF,
                    finalISF: finalISF,
                    profileSens: profileSens,
                    adjustedSens: adjustedSens
                )
            )
        }

        // ---- pp_ISF: post-prandial delta (only above target+10 and on rising BG) ----
        var ppISF: Decimal = 1
        var sensModified = bgISF > 1 // bgISF already above target counts as modification
        // Mirrors determine-basal.js (autoISF 3.01) line 443: acce_ISF != 1 also triggers
        // sens_modified, so a pure acceleration brake (no bg/pp/dura signal) still adjusts ISF.
        if acceISF != 1 { sensModified = true }
        if bgOff <= 0, shortAvgDelta >= 0 {
            ppISF = 1 + max(0, bgDelta * profile.postMealISFweight)
            if ppISF != 1 { sensModified = true }
        }

        // ---- dura_ISF: sustained duration above target ----
        var duraISF: Decimal = 1
        if dura05 >= 10, avg05 > targetBG {
            let dura05Weight = dura05 / 60
            let avg05Weight = profile.autoISFhourlyChange / targetBG
            duraISF = 1 + dura05Weight * avg05Weight * (avg05 - targetBG)
            sensModified = true
        }

        guard sensModified else {
            return AutoISFAdjustResult(
                adjustedSens: sens,
                acceISFratio: acceISF.jsRounded(scale: 2),
                bgISFratio: bgISF,
                ppISFratio: 1,
                duraISFratio: 1,
                autoISFratio: 1,
                reason: AutoISFReason.adjustNotModified
            )
        }

        // ---- combine: take strongest factor, apply acce brakes if decelerating ----
        var liftISF = max(duraISF, max(bgISF, max(acceISF, ppISF)))
        if acceISF < 1 {
            liftISF = liftISF * acceISF // BG is already decelerating — weaken the lift
        }

        let finalISF = withinISFlimits(
            liftISF: liftISF,
            min: profile.autoISFmin,
            max: profile.autoISFmax,
            sensitivityRatio: sensitivityRatio,
            exerciseModeActive: exerciseModeActive,
            resistanceModeActive: resistanceModeActive
        )

        // 1-decimal precision — see comment on the early-return adjustedSens above.
        let adjustedSens = (profileSens / finalISF).jsRounded(scale: 1)
        let autoISFratio = adjustedSens > 0 ? (profileSens / adjustedSens).jsRounded(scale: 2) : 1

        return AutoISFAdjustResult(
            adjustedSens: adjustedSens,
            acceISFratio: acceISF.jsRounded(scale: 2),
            bgISFratio: bgISF,
            ppISFratio: ppISF.jsRounded(scale: 2),
            duraISFratio: duraISF.jsRounded(scale: 2),
            autoISFratio: autoISFratio,
            reason: AutoISFReason.adjustFullReason(
                acceISFratio: acceISF,
                bgISFratio: bgISF,
                ppISFratio: ppISF,
                duraISFratio: duraISF,
                dura05: dura05,
                avg05: avg05,
                finalISF: finalISF,
                profileSens: profileSens,
                adjustedSens: adjustedSens
            )
        )
    }

    // MARK: - Private helpers

    /// Piecewise linear interpolation on the bg_ISF polygon.
    ///
    /// `xdata = 100 - bgOff` maps the glucose offset from target+10 onto the polygon x-axis
    /// centred at 100. At x=100 (BG == target+10) the result is 0 (no adjustment).
    /// Above 100 the result is positive (tighten ISF); below 100 it is negative (loosen ISF).
    /// `higherWeight` / `lowerWeight` scale the magnitude in each region.
    private static func interpolate(_ xdata: Decimal, higherWeight: Decimal, lowerWeight: Decimal) -> Decimal {
        let polyX: [Decimal] = [50, 60, 80, 90, 100, 110, 150, 180, 200]
        let polyY: [Decimal] = [-0.5, -0.5, -0.3, -0.2, 0.0, 0.0, 0.5, 0.7, 0.7]
        let polymax = polyX.count - 1

        let rawVal: Decimal
        if xdata < polyX[0] {
            // Extrapolate below the lowest knot
            let lowX = polyX[0], topX = polyX[1]
            let lowVal = polyY[0], topVal = polyY[1]
            rawVal = lowVal + (topVal - lowVal) / (topX - lowX) * (xdata - lowX)
        } else if xdata > polyX[polymax] {
            // Extrapolate above the highest knot
            let lowX = polyX[polymax - 1], topX = polyX[polymax]
            let lowVal = polyY[polymax - 1], topVal = polyY[polymax]
            rawVal = lowVal + (topVal - lowVal) / (topX - lowX) * (xdata - lowX)
        } else {
            var result = polyY[0]
            var lowVal = polyY[0]
            var lowLabl = polyX[0]
            for i in 0 ... polymax {
                let step = polyX[i], sVal = polyY[i]
                if step == xdata {
                    result = sVal
                    break
                } else if step > xdata {
                    result = lowVal + (sVal - lowVal) / (step - lowLabl) * (xdata - lowLabl)
                    break
                }
                lowVal = sVal
                lowLabl = step
            }
            rawVal = result
        }
        return xdata > 100 ? rawVal * higherWeight : rawVal * lowerWeight
    }

    /// Clamp `liftISF` to `[autoISF_min, autoISF_max]` then combine with `sensitivityRatio`.
    ///
    /// - Exercise / resistance mode: multiply the two factors (both effects apply fully).
    /// - Normal: take the more aggressive of autoISF or autosens (max when ≥ 1, min when < 1).
    private static func withinISFlimits(
        liftISF: Decimal,
        min minISF: Decimal,
        max maxISF: Decimal,
        sensitivityRatio: Decimal,
        exerciseModeActive: Bool,
        resistanceModeActive: Bool
    ) -> Decimal {
        let limited = liftISF.clamp(lowerBound: minISF, upperBound: maxISF)
        if exerciseModeActive || resistanceModeActive {
            return limited * sensitivityRatio
        } else if limited >= 1 {
            return Swift.max(limited, sensitivityRatio)
        } else {
            return Swift.min(limited, sensitivityRatio)
        }
    }
}
