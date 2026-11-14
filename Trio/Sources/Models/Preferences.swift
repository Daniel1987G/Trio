import Foundation

struct Preferences: JSON, Equatable {
    var maxIOB: Decimal = 0
    var maxDailySafetyMultiplier: Decimal = 3
    var currentBasalSafetyMultiplier: Decimal = 4
    var autosensMax: Decimal = 1.2
    var autosensMin: Decimal = 0.7
    var smbDeliveryRatio: Decimal = 0.5
    var rewindResetsAutosens: Bool = true
    var highTemptargetRaisesSensitivity: Bool = false
    var lowTemptargetLowersSensitivity: Bool = false
    var sensitivityRaisesTarget: Bool = false
    var resistanceLowersTarget: Bool = false
    var advTargetAdjustments: Bool = false
    var exerciseMode: Bool = false
    var halfBasalExerciseTarget: Decimal = 160
    var maxCOB: Decimal = 120
    var maxMealAbsorptionTime: Decimal = 6
    var wideBGTargetRange: Bool = false
    var skipNeutralTemps: Bool = false
    var unsuspendIfNoTemp: Bool = false
    var min5mCarbimpact: Decimal = 8
    var remainingCarbsFraction: Decimal = 1.0
    var remainingCarbsCap: Decimal = 90
    var enableUAM: Bool = false
    var a52RiskEnable: Bool = false
    var enableSMBWithCOB: Bool = false
    var enableSMBWithTemptarget: Bool = false
    var enableSMBAlways: Bool = false
    var enableSMBAfterCarbs: Bool = false
    var allowSMBWithHighTemptarget: Bool = false
    var maxSMBBasalMinutes: Decimal = 30
    var maxUAMSMBBasalMinutes: Decimal = 30
    var smbInterval: Decimal = 3
    var bolusIncrement: Decimal = 0.1
    var curve: InsulinCurve = .rapidActing
    var useCustomPeakTime: Bool = false
    var insulinPeakTime: Decimal = 75
    var carbsReqThreshold: Decimal = 1.0
    var noisyCGMTargetMultiplier: Decimal = 1.3
    var suspendZerosIOB: Bool = true
    var timestamp: Date?
    var maxDeltaBGthreshold: Decimal = 0.2
    var adjustmentFactor: Decimal = 0.8
    var adjustmentFactorSigmoid: Decimal = 0.5
    var sigmoid: Bool = false
    var useNewFormula: Bool = false
    var useWeightedAverage: Bool = false
    var weightPercentage: Decimal = 0.35
    var tddAdjBasal: Bool = false
    var enableSMB_high_bg: Bool = false
    var enableSMB_high_bg_target: Decimal = 110
    var threshold_setting: Decimal = 60
    var updateInterval: Decimal = 20
    // autoISF (from Tai); off by default, see AutoISFSettings
    var autoisf: Bool = false
    var autoISFmax: Decimal = 1.5
    var autoISFmin: Decimal = 0.7
    var smbMaxRangeExtension: Decimal = 1
    var smbDeliveryRatioBGrange: Decimal = 0
    var smbDeliveryRatioMin: Decimal = 0.5
    var smbDeliveryRatioMax: Decimal = 0.8
    var autoISFhourlyChange: Decimal = 0.2
    var higherISFrangeWeight: Decimal = 0
    var lowerISFrangeWeight: Decimal = 0
    var postMealISFweight: Decimal = 0.005
    var enableBGacceleration: Bool = true
    var bgAccelISFweight: Decimal = 0.05
    var bgBrakeISFweight: Decimal = 0.025
    var iobThresholdPercent: Decimal = 1
    var enableSMBEvenOnOddOffAlways: Bool = false
    var autoISFoffSport: Bool = false
    var enableB30: Bool = false
    var B30iTimeStartBolus: Decimal = 1
    var B30iTime: Decimal = 30
    var B30iTimeTarget: Decimal = 90
    var B30upperLimit: Decimal = 130
    var B30upperDelta: Decimal = 8
    var B30basalFactor: Decimal = 5
    /// The autoISF value set last applied (AutoISFStartPreset raw value), "" if none.
    var autoISFValueSet: String = ""
}

extension Preferences {
    private enum CodingKeys: String, CodingKey {
        case maxIOB = "max_iob"
        case maxDailySafetyMultiplier = "max_daily_safety_multiplier"
        case currentBasalSafetyMultiplier = "current_basal_safety_multiplier"
        case autosensMax = "autosens_max"
        case autosensMin = "autosens_min"
        case smbDeliveryRatio = "smb_delivery_ratio"
        case rewindResetsAutosens = "rewind_resets_autosens"
        case highTemptargetRaisesSensitivity = "high_temptarget_raises_sensitivity"
        case lowTemptargetLowersSensitivity = "low_temptarget_lowers_sensitivity"
        case sensitivityRaisesTarget = "sensitivity_raises_target"
        case resistanceLowersTarget = "resistance_lowers_target"
        case advTargetAdjustments = "adv_target_adjustments"
        case exerciseMode = "exercise_mode"
        case halfBasalExerciseTarget = "half_basal_exercise_target"
        case maxCOB
        case maxMealAbsorptionTime
        case wideBGTargetRange = "wide_bg_target_range"
        case skipNeutralTemps = "skip_neutral_temps"
        case unsuspendIfNoTemp = "unsuspend_if_no_temp"
        case min5mCarbimpact = "min_5m_carbimpact"
        case remainingCarbsFraction
        case remainingCarbsCap
        case enableUAM
        case a52RiskEnable = "A52_risk_enable"
        case enableSMBWithCOB = "enableSMB_with_COB"
        case enableSMBWithTemptarget = "enableSMB_with_temptarget"
        case enableSMBAlways = "enableSMB_always"
        case enableSMBAfterCarbs = "enableSMB_after_carbs"
        case allowSMBWithHighTemptarget = "allowSMB_with_high_temptarget"
        case maxSMBBasalMinutes
        case maxUAMSMBBasalMinutes
        case smbInterval = "SMBInterval"
        case bolusIncrement = "bolus_increment"
        case curve
        case useCustomPeakTime
        case insulinPeakTime
        case carbsReqThreshold
        case noisyCGMTargetMultiplier
        case suspendZerosIOB = "suspend_zeros_iob"
        case maxDeltaBGthreshold = "maxDelta_bg_threshold"
        case adjustmentFactor
        case adjustmentFactorSigmoid
        case sigmoid
        case useNewFormula
        case useWeightedAverage
        case weightPercentage
        case tddAdjBasal
        case enableSMB_high_bg
        case enableSMB_high_bg_target
        case threshold_setting
        case updateInterval
        // autoISF
        case autoisf = "use_autoisf"
        case autoISFmax = "autoISF_max"
        case autoISFmin = "autoISF_min"
        case smbMaxRangeExtension = "smb_max_range_extension"
        case smbDeliveryRatioBGrange = "smb_delivery_ratio_bg_range"
        case smbDeliveryRatioMin = "smb_delivery_ratio_min"
        case smbDeliveryRatioMax = "smb_delivery_ratio_max"
        case autoISFhourlyChange = "dura_ISF_weight"
        case higherISFrangeWeight = "higher_ISFrange_weight"
        case lowerISFrangeWeight = "lower_ISFrange_weight"
        case postMealISFweight = "pp_ISF_weight"
        case enableBGacceleration = "enable_BG_acceleration"
        case bgAccelISFweight = "bgAccel_ISF_weight"
        case bgBrakeISFweight = "bgBrake_ISF_weight"
        case iobThresholdPercent = "iob_threshold_percent"
        case enableSMBEvenOnOddOffAlways = "enableSMB_EvenOn_OddOff_always"
        case autoISFoffSport = "autoISF_off_Sport"
        case enableB30 = "use_B30"
        case B30iTimeStartBolus = "iTime_Start_Bolus"
        case B30iTime = "b30_duration"
        case B30iTimeTarget = "iTime_target"
        case B30upperLimit = "b30_upperBG"
        case B30upperDelta = "b30_upperdelta"
        case B30basalFactor = "b30_factor"
        case autoISFValueSet = "autoisf_value_set"
    }
}

enum InsulinCurve: String, JSON, Identifiable, CaseIterable {
    case rapidActing = "rapid-acting"
    case ultraRapid = "ultra-rapid"
    case bilinear

    var id: InsulinCurve { self }
}

extension Preferences: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var preferences = Preferences()

        if let maxIOB = try? container.decode(Decimal.self, forKey: .maxIOB) {
            preferences.maxIOB = maxIOB
        }

        if let maxDailySafetyMultiplier = try? container.decode(Decimal.self, forKey: .maxDailySafetyMultiplier) {
            preferences.maxDailySafetyMultiplier = maxDailySafetyMultiplier
        }

        if let currentBasalSafetyMultiplier = try? container.decode(Decimal.self, forKey: .currentBasalSafetyMultiplier) {
            preferences.currentBasalSafetyMultiplier = currentBasalSafetyMultiplier
        }

        if let autosensMax = try? container.decode(Decimal.self, forKey: .autosensMax) {
            preferences.autosensMax = autosensMax
        }

        if let autosensMin = try? container.decode(Decimal.self, forKey: .autosensMin) {
            preferences.autosensMin = autosensMin
        }

        if let smbDeliveryRatio = try? container.decode(Decimal.self, forKey: .smbDeliveryRatio) {
            preferences.smbDeliveryRatio = smbDeliveryRatio
        }

        if let rewindResetsAutosens = try? container.decode(Bool.self, forKey: .rewindResetsAutosens) {
            preferences.rewindResetsAutosens = rewindResetsAutosens
        }

        if let highTemptargetRaisesSensitivity = try? container.decode(Bool.self, forKey: .highTemptargetRaisesSensitivity) {
            preferences.highTemptargetRaisesSensitivity = highTemptargetRaisesSensitivity
        }

        if let lowTemptargetLowersSensitivity = try? container.decode(Bool.self, forKey: .lowTemptargetLowersSensitivity) {
            preferences.lowTemptargetLowersSensitivity = lowTemptargetLowersSensitivity
        }

        if let sensitivityRaisesTarget = try? container.decode(Bool.self, forKey: .sensitivityRaisesTarget) {
            preferences.sensitivityRaisesTarget = sensitivityRaisesTarget
        }

        if let resistanceLowersTarget = try? container.decode(Bool.self, forKey: .resistanceLowersTarget) {
            preferences.resistanceLowersTarget = resistanceLowersTarget
        }

        if let advTargetAdjustments = try? container.decode(Bool.self, forKey: .advTargetAdjustments) {
            preferences.advTargetAdjustments = advTargetAdjustments
        }

        if let exerciseMode = try? container.decode(Bool.self, forKey: .exerciseMode) {
            preferences.exerciseMode = exerciseMode
        }

        if let halfBasalExerciseTarget = try? container.decode(Decimal.self, forKey: .halfBasalExerciseTarget) {
            preferences.halfBasalExerciseTarget = halfBasalExerciseTarget
        }

        if let maxCOB = try? container.decode(Decimal.self, forKey: .maxCOB) {
            preferences.maxCOB = maxCOB
        }

        if let maxMealAbsorptionTime = try? container.decode(Decimal.self, forKey: .maxMealAbsorptionTime) {
            preferences.maxMealAbsorptionTime = maxMealAbsorptionTime
        }

        if let wideBGTargetRange = try? container.decode(Bool.self, forKey: .wideBGTargetRange) {
            preferences.wideBGTargetRange = wideBGTargetRange
        }

        if let skipNeutralTemps = try? container.decode(Bool.self, forKey: .skipNeutralTemps) {
            preferences.skipNeutralTemps = skipNeutralTemps
        }

        if let unsuspendIfNoTemp = try? container.decode(Bool.self, forKey: .unsuspendIfNoTemp) {
            preferences.unsuspendIfNoTemp = unsuspendIfNoTemp
        }

        if let min5mCarbimpact = try? container.decode(Decimal.self, forKey: .min5mCarbimpact) {
            preferences.min5mCarbimpact = min5mCarbimpact
        }

        if let remainingCarbsFraction = try? container.decode(Decimal.self, forKey: .remainingCarbsFraction) {
            preferences.remainingCarbsFraction = remainingCarbsFraction
        }

        if let remainingCarbsCap = try? container.decode(Decimal.self, forKey: .remainingCarbsCap) {
            preferences.remainingCarbsCap = remainingCarbsCap
        }

        if let enableUAM = try? container.decode(Bool.self, forKey: .enableUAM) {
            preferences.enableUAM = enableUAM
        }

        if let a52RiskEnable = try? container.decode(Bool.self, forKey: .a52RiskEnable) {
            preferences.a52RiskEnable = a52RiskEnable
        }

        if let enableSMBWithCOB = try? container.decode(Bool.self, forKey: .enableSMBWithCOB) {
            preferences.enableSMBWithCOB = enableSMBWithCOB
        }

        if let enableSMBWithTemptarget = try? container.decode(Bool.self, forKey: .enableSMBWithTemptarget) {
            preferences.enableSMBWithTemptarget = enableSMBWithTemptarget
        }

        if let enableSMBAlways = try? container.decode(Bool.self, forKey: .enableSMBAlways) {
            preferences.enableSMBAlways = enableSMBAlways
        }

        if let enableSMBAfterCarbs = try? container.decode(Bool.self, forKey: .enableSMBAfterCarbs) {
            preferences.enableSMBAfterCarbs = enableSMBAfterCarbs
        }

        if let allowSMBWithHighTemptarget = try? container.decode(Bool.self, forKey: .allowSMBWithHighTemptarget) {
            preferences.allowSMBWithHighTemptarget = allowSMBWithHighTemptarget
        }

        if let maxSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxSMBBasalMinutes) {
            preferences.maxSMBBasalMinutes = maxSMBBasalMinutes
        }

        if let maxUAMSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxUAMSMBBasalMinutes) {
            preferences.maxUAMSMBBasalMinutes = maxUAMSMBBasalMinutes
        }

        if let smbInterval = try? container.decode(Decimal.self, forKey: .smbInterval) {
            preferences.smbInterval = smbInterval
        }

        if let bolusIncrement = try? container.decode(Decimal.self, forKey: .bolusIncrement) {
            preferences.bolusIncrement = bolusIncrement > 0 ? bolusIncrement : 0.1
        }

        if let curve = try? container.decode(InsulinCurve.self, forKey: .curve) {
            preferences.curve = curve
        }

        if let useCustomPeakTime = try? container.decode(Bool.self, forKey: .useCustomPeakTime) {
            preferences.useCustomPeakTime = useCustomPeakTime
        }

        if let insulinPeakTime = try? container.decode(Decimal.self, forKey: .insulinPeakTime) {
            preferences.insulinPeakTime = insulinPeakTime
        }

        if let carbsReqThreshold = try? container.decode(Decimal.self, forKey: .carbsReqThreshold) {
            preferences.carbsReqThreshold = carbsReqThreshold
        }

        if let noisyCGMTargetMultiplier = try? container.decode(Decimal.self, forKey: .noisyCGMTargetMultiplier) {
            preferences.noisyCGMTargetMultiplier = noisyCGMTargetMultiplier
        }

        if let suspendZerosIOB = try? container.decode(Bool.self, forKey: .suspendZerosIOB) {
            preferences.suspendZerosIOB = suspendZerosIOB
        }

        if let maxDeltaBGthreshold = try? container.decode(Decimal.self, forKey: .maxDeltaBGthreshold) {
            preferences.maxDeltaBGthreshold = maxDeltaBGthreshold
        }

        if let adjustmentFactor = try? container.decode(Decimal.self, forKey: .adjustmentFactor) {
            preferences.adjustmentFactor = adjustmentFactor
        }

        if let adjustmentFactorSigmoid = try? container.decode(Decimal.self, forKey: .adjustmentFactorSigmoid) {
            preferences.adjustmentFactorSigmoid = adjustmentFactorSigmoid
        }

        if let sigmoid = try? container.decode(Bool.self, forKey: .sigmoid) {
            preferences.sigmoid = sigmoid
        }

        if let useNewFormula = try? container.decode(Bool.self, forKey: .useNewFormula) {
            preferences.useNewFormula = useNewFormula
        }

        if let useWeightedAverage = try? container.decode(Bool.self, forKey: .useWeightedAverage) {
            preferences.useWeightedAverage = useWeightedAverage
        }

        if let weightPercentage = try? container.decode(Decimal.self, forKey: .weightPercentage) {
            preferences.weightPercentage = weightPercentage
        }

        if let tddAdjBasal = try? container.decode(Bool.self, forKey: .tddAdjBasal) {
            preferences.tddAdjBasal = tddAdjBasal
        }

        if let enableSMB_high_bg = try? container.decode(Bool.self, forKey: .enableSMB_high_bg) {
            preferences.enableSMB_high_bg = enableSMB_high_bg
        }

        if let enableSMB_high_bg_target = try? container.decode(Decimal.self, forKey: .enableSMB_high_bg_target) {
            preferences.enableSMB_high_bg_target = enableSMB_high_bg_target
        }

        if let threshold_setting = try? container.decode(Decimal.self, forKey: .threshold_setting) {
            preferences.threshold_setting = threshold_setting
        }

        if let updateInterval = try? container.decode(Decimal.self, forKey: .updateInterval) {
            preferences.updateInterval = updateInterval
        }

        // autoISF
        if let autoisf = try? container.decode(Bool.self, forKey: .autoisf) {
            preferences.autoisf = autoisf
        }
        if let autoISFmax = try? container.decode(Decimal.self, forKey: .autoISFmax) {
            preferences.autoISFmax = autoISFmax
        }
        if let autoISFmin = try? container.decode(Decimal.self, forKey: .autoISFmin) {
            preferences.autoISFmin = autoISFmin
        }
        if let smbMaxRangeExtension = try? container.decode(Decimal.self, forKey: .smbMaxRangeExtension) {
            preferences.smbMaxRangeExtension = smbMaxRangeExtension
        }
        if let smbDeliveryRatioBGrange = try? container.decode(Decimal.self, forKey: .smbDeliveryRatioBGrange) {
            preferences.smbDeliveryRatioBGrange = smbDeliveryRatioBGrange
        }
        if let smbDeliveryRatioMin = try? container.decode(Decimal.self, forKey: .smbDeliveryRatioMin) {
            preferences.smbDeliveryRatioMin = smbDeliveryRatioMin
        }
        if let smbDeliveryRatioMax = try? container.decode(Decimal.self, forKey: .smbDeliveryRatioMax) {
            preferences.smbDeliveryRatioMax = smbDeliveryRatioMax
        }
        if let autoISFhourlyChange = try? container.decode(Decimal.self, forKey: .autoISFhourlyChange) {
            preferences.autoISFhourlyChange = autoISFhourlyChange
        }
        if let higherISFrangeWeight = try? container.decode(Decimal.self, forKey: .higherISFrangeWeight) {
            preferences.higherISFrangeWeight = higherISFrangeWeight
        }
        if let lowerISFrangeWeight = try? container.decode(Decimal.self, forKey: .lowerISFrangeWeight) {
            preferences.lowerISFrangeWeight = lowerISFrangeWeight
        }
        if let postMealISFweight = try? container.decode(Decimal.self, forKey: .postMealISFweight) {
            preferences.postMealISFweight = postMealISFweight
        }
        if let enableBGacceleration = try? container.decode(Bool.self, forKey: .enableBGacceleration) {
            preferences.enableBGacceleration = enableBGacceleration
        }
        if let bgAccelISFweight = try? container.decode(Decimal.self, forKey: .bgAccelISFweight) {
            preferences.bgAccelISFweight = bgAccelISFweight
        }
        if let bgBrakeISFweight = try? container.decode(Decimal.self, forKey: .bgBrakeISFweight) {
            preferences.bgBrakeISFweight = bgBrakeISFweight
        }
        if let iobThresholdPercent = try? container.decode(Decimal.self, forKey: .iobThresholdPercent) {
            preferences.iobThresholdPercent = iobThresholdPercent
        }
        if let enableSMBEvenOnOddOffAlways = try? container.decode(Bool.self, forKey: .enableSMBEvenOnOddOffAlways) {
            preferences.enableSMBEvenOnOddOffAlways = enableSMBEvenOnOddOffAlways
        }
        if let autoISFoffSport = try? container.decode(Bool.self, forKey: .autoISFoffSport) {
            preferences.autoISFoffSport = autoISFoffSport
        }
        if let enableB30 = try? container.decode(Bool.self, forKey: .enableB30) {
            preferences.enableB30 = enableB30
        }
        if let B30iTimeStartBolus = try? container.decode(Decimal.self, forKey: .B30iTimeStartBolus) {
            preferences.B30iTimeStartBolus = B30iTimeStartBolus
        }
        if let B30iTime = try? container.decode(Decimal.self, forKey: .B30iTime) {
            preferences.B30iTime = B30iTime
        }
        if let B30iTimeTarget = try? container.decode(Decimal.self, forKey: .B30iTimeTarget) {
            preferences.B30iTimeTarget = B30iTimeTarget
        }
        if let B30upperLimit = try? container.decode(Decimal.self, forKey: .B30upperLimit) {
            preferences.B30upperLimit = B30upperLimit
        }
        if let B30upperDelta = try? container.decode(Decimal.self, forKey: .B30upperDelta) {
            preferences.B30upperDelta = B30upperDelta
        }
        if let B30basalFactor = try? container.decode(Decimal.self, forKey: .B30basalFactor) {
            preferences.B30basalFactor = B30basalFactor
        }
        if let autoISFValueSet = try? container.decode(String.self, forKey: .autoISFValueSet) {
            preferences.autoISFValueSet = autoISFValueSet
        }

        preferences.resolveISFModeConflict()
        self = preferences
    }
}

extension Preferences {
    /// autoISF and Dynamic ISF must never run together. Dynamic ISF is the established setting,
    /// so when both are on (an older backup, a hand-edited file) autoISF and B30 are switched off.
    mutating func resolveISFModeConflict() {
        guard useNewFormula, autoisf || enableB30 else { return }
        autoisf = false
        enableB30 = false
    }
}

/// Value sets for autoISF: the OpenTrio defaults, and two starting points for a Full Closed Loop
/// from the FCL e-book by BerNie (sections 2 "General Settings" V.4.3 and 4 "Meals: Setting
/// ISF_weights" V.5.8.1). Max IOB and the safety multipliers stay as the user set them.
enum AutoISFStartPreset: String, CaseIterable, Identifiable {
    /// The values a fresh OpenTrio installation has, for everything the FCL sets change
    /// (autoISF stays on, Dynamic ISF stays off).
    case standard
    /// The e-book's starting values for the weights (bgAccel 0.05, pp 0.005, dura 0.2).
    case moderate
    /// The values the e-book cites from experienced users and its own examples
    /// (bgAccel about 0.2, pp 0.02, delivery ratio 0.7, iobTH 60 %, range extension 2.5).
    case aggressive

    var id: String { rawValue }

    private static func dec(_ text: String) -> Decimal { Decimal(string: text)! }

    func apply(to preferences: inout Preferences) {
        preferences.autoISFValueSet = rawValue
        if self == .standard {
            applyDefaults(to: &preferences)
            return
        }

        // section 2
        preferences.autoisf = true
        preferences.useNewFormula = false
        preferences.sigmoid = false
        preferences.autoISFmax = 2
        preferences.autoISFmin = Self.dec("0.3")
        preferences.smbDeliveryRatioBGrange = 0
        preferences.enableSMBEvenOnOddOffAlways = true
        preferences.enableSMBAlways = true
        preferences.allowSMBWithHighTemptarget = true
        preferences.enableUAM = true
        preferences.maxSMBBasalMinutes = 120
        preferences.maxUAMSMBBasalMinutes = 120
        preferences.smbInterval = 3
        preferences.autosensMax = 1
        preferences.autosensMin = 1
        preferences.highTemptargetRaisesSensitivity = true

        // section 4: bg_ISF off in FCL, brake about half of accel
        preferences.enableBGacceleration = true
        preferences.higherISFrangeWeight = 0
        preferences.lowerISFrangeWeight = 0
        preferences.autoISFhourlyChange = Self.dec("0.2")

        switch self {
        case .standard:
            break // handled above
        case .moderate:
            preferences.smbMaxRangeExtension = 2
            preferences.smbDeliveryRatio = Self.dec("0.6")
            preferences.iobThresholdPercent = Self.dec("0.5")
            preferences.bgAccelISFweight = Self.dec("0.05")
            preferences.bgBrakeISFweight = Self.dec("0.025")
            preferences.postMealISFweight = Self.dec("0.005")
        case .aggressive:
            preferences.smbMaxRangeExtension = Self.dec("2.5")
            preferences.smbDeliveryRatio = Self.dec("0.7")
            preferences.iobThresholdPercent = Self.dec("0.6")
            preferences.bgAccelISFweight = Self.dec("0.2")
            preferences.bgBrakeISFweight = Self.dec("0.1")
            preferences.postMealISFweight = Self.dec("0.02")
        }
    }

    /// Every value the FCL sets touch, plus the rest of autoISF and B30, back to a fresh install.
    private func applyDefaults(to preferences: inout Preferences) {
        let defaults = Preferences()
        preferences.autoisf = true
        preferences.useNewFormula = false
        preferences.sigmoid = false
        preferences.autoISFmax = defaults.autoISFmax
        preferences.autoISFmin = defaults.autoISFmin
        preferences.smbMaxRangeExtension = defaults.smbMaxRangeExtension
        preferences.smbDeliveryRatioBGrange = defaults.smbDeliveryRatioBGrange
        preferences.smbDeliveryRatioMin = defaults.smbDeliveryRatioMin
        preferences.smbDeliveryRatioMax = defaults.smbDeliveryRatioMax
        preferences.autoISFhourlyChange = defaults.autoISFhourlyChange
        preferences.higherISFrangeWeight = defaults.higherISFrangeWeight
        preferences.lowerISFrangeWeight = defaults.lowerISFrangeWeight
        preferences.postMealISFweight = defaults.postMealISFweight
        preferences.enableBGacceleration = defaults.enableBGacceleration
        preferences.bgAccelISFweight = defaults.bgAccelISFweight
        preferences.bgBrakeISFweight = defaults.bgBrakeISFweight
        preferences.iobThresholdPercent = defaults.iobThresholdPercent
        preferences.enableSMBEvenOnOddOffAlways = defaults.enableSMBEvenOnOddOffAlways
        preferences.autoISFoffSport = defaults.autoISFoffSport
        preferences.enableB30 = defaults.enableB30
        preferences.B30iTimeStartBolus = defaults.B30iTimeStartBolus
        preferences.B30iTime = defaults.B30iTime
        preferences.B30iTimeTarget = defaults.B30iTimeTarget
        preferences.B30upperLimit = defaults.B30upperLimit
        preferences.B30upperDelta = defaults.B30upperDelta
        preferences.B30basalFactor = defaults.B30basalFactor
        preferences.smbDeliveryRatio = defaults.smbDeliveryRatio
        preferences.enableSMBAlways = defaults.enableSMBAlways
        preferences.allowSMBWithHighTemptarget = defaults.allowSMBWithHighTemptarget
        preferences.enableUAM = defaults.enableUAM
        preferences.maxSMBBasalMinutes = defaults.maxSMBBasalMinutes
        preferences.maxUAMSMBBasalMinutes = defaults.maxUAMSMBBasalMinutes
        preferences.smbInterval = defaults.smbInterval
        preferences.autosensMax = defaults.autosensMax
        preferences.autosensMin = defaults.autosensMin
        preferences.highTemptargetRaisesSensitivity = defaults.highTemptargetRaisesSensitivity
    }

    /// The FCL set the loop runs with: the one last applied, while autoISF is on and Dynamic ISF off.
    static func activeFCL(in preferences: Preferences) -> AutoISFStartPreset? {
        guard preferences.autoisf, !preferences.useNewFormula,
              let preset = AutoISFStartPreset(rawValue: preferences.autoISFValueSet),
              preset != .standard
        else { return nil }
        return preset
    }

    /// Whether settings were changed after the set was applied (tuning, as the e-book asks for).
    func isAdjusted(in preferences: Preferences) -> Bool {
        var pristine = preferences
        apply(to: &pristine)
        return pristine != preferences
    }
}
