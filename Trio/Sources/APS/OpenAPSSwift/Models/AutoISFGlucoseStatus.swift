import Foundation

/// AutoISF-enhanced glucose status
/// Extends GlucoseStatus with additional autoISF-specific metrics
/// These are only calculated when autoISF is enabled
///
/// IMPORTANT: Ported directly from JavaScript glucose-get-last.js
/// Keep these structs aligned with the sister JavaScript project
///
/// Calculation logic lives in AutoISFGlucose_Helpers.swift
struct AutoISFGlucoseStatus {
    /// Reference to base GlucoseStatus data (glucose, delta, shortAvgDelta, longAvgDelta, etc.)
    let glucoseStatus: GlucoseStatus

    // autoISF specific fields (from JavaScript glucose-get-last.js)
    /// Minutes where glucose is relatively flat/stable
    let cgmFlatMinutes: Decimal

    /// Duration in minutes for ISF adjustment window (moving average window)
    let dura_ISF_minutes: Decimal

    /// Average glucose over the dura_ISF_minutes window
    let dura_ISF_average: Decimal

    /// Parabola fit duration in minutes
    let dura_p: Decimal

    /// Parabola last delta: 5-minute delta from the past
    let delta_pl: Decimal

    /// Parabola next delta: predicted 5-minute delta into the future
    let delta_pn: Decimal

    /// Glucose acceleration from parabola fit
    let bg_acceleration: Decimal

    /// R-squared value from parabola fit (0.0 to 1.0, quality of fit)
    let r_squ: Decimal

    /// Parabola coefficient a0 (constant term)
    let a_0: Decimal

    /// Parabola coefficient a1 (linear term)
    let a_1: Decimal

    /// Parabola coefficient a2 (quadratic term)
    let a_2: Decimal

    /// Debug string with all calculated values for comparison with JavaScript
    /// Formatted to match JavaScript `ppDebug` output for validation
    let debugInfo: String
}
