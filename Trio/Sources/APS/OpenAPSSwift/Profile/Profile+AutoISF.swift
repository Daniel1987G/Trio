import Foundation

extension Profile {
    /// Copies the autoISF and B30 settings from the preferences. Called right before a
    /// determination, like `supportedBasalRates`; nothing of it is written to profile.json.
    mutating func applyAutoISF(from preferences: Preferences) {
        autoisf = preferences.autoisf
        autoISFmax = preferences.autoISFmax
        autoISFmin = preferences.autoISFmin
        smbMaxRangeExtension = preferences.smbMaxRangeExtension
        smbDeliveryRatioBGrange = preferences.smbDeliveryRatioBGrange
        smbDeliveryRatioMin = preferences.smbDeliveryRatioMin
        smbDeliveryRatioMax = preferences.smbDeliveryRatioMax
        autoISFhourlyChange = preferences.autoISFhourlyChange
        higherISFrangeWeight = preferences.higherISFrangeWeight
        lowerISFrangeWeight = preferences.lowerISFrangeWeight
        postMealISFweight = preferences.postMealISFweight
        enableBGacceleration = preferences.enableBGacceleration
        bgAccelISFweight = preferences.bgAccelISFweight
        bgBrakeISFweight = preferences.bgBrakeISFweight
        iobThresholdPercent = preferences.iobThresholdPercent
        enableSMBEvenOnOddOffAlways = preferences.enableSMBEvenOnOddOffAlways
        autoISFoffSport = preferences.autoISFoffSport
        enableB30 = preferences.enableB30
        B30iTimeStartBolus = preferences.B30iTimeStartBolus
        B30iTime = preferences.B30iTime
        B30iTimeTarget = preferences.B30iTimeTarget
        B30upperLimit = preferences.B30upperLimit
        B30upperDelta = preferences.B30upperDelta
        B30basalFactor = preferences.B30basalFactor
    }
}
