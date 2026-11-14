import Combine
import SwiftUI

extension AutoISFSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var autoisf: Bool = false
        /// Dynamic ISF is on; autoISF and Dynamic ISF exclude each other.
        @Published var dynamicISFActive: Bool = false

        @Published var autoISFmax: Decimal = 1.5
        @Published var autoISFmin: Decimal = 0.7
        @Published var higherISFrangeWeight: Decimal = 0
        @Published var lowerISFrangeWeight: Decimal = 0
        @Published var postMealISFweight: Decimal = 0.005
        @Published var autoISFhourlyChange: Decimal = 0.2
        @Published var enableBGacceleration: Bool = true
        @Published var bgAccelISFweight: Decimal = 0.05
        @Published var bgBrakeISFweight: Decimal = 0.025
        @Published var autoISFoffSport: Bool = false

        @Published var enableSMBEvenOnOddOffAlways: Bool = false
        @Published var iobThresholdPercent: Decimal = 1
        @Published var smbDeliveryRatioBGrange: Decimal = 0
        @Published var smbDeliveryRatioMin: Decimal = 0.5
        @Published var smbDeliveryRatioMax: Decimal = 0.8
        @Published var smbMaxRangeExtension: Decimal = 1

        @Published var enableB30: Bool = false
        @Published var B30iTimeStartBolus: Decimal = 1
        @Published var B30iTime: Decimal = 30
        @Published var B30iTimeTarget: Decimal = 90
        @Published var B30upperLimit: Decimal = 130
        @Published var B30upperDelta: Decimal = 8
        @Published var B30basalFactor: Decimal = 5

        var units: GlucoseUnits = .mgdL
        var maxIOB: Decimal = 0

        override func subscribe() {
            units = settingsManager.settings.units
            maxIOB = settingsManager.preferences.maxIOB
            dynamicISFActive = settingsManager.preferences.useNewFormula

            subscribePreferencesSetting(\.autoisf, on: $autoisf, initial: { autoisf = $0 }, map: { [weak self] isOn in
                // autoISF and Dynamic ISF exclude each other: Dynamic ISF goes off before autoISF is stored
                if isOn, let self, self.settingsManager.preferences.useNewFormula {
                    self.settingsManager.preferences.useNewFormula = false
                    self.settingsManager.preferences.sigmoid = false
                    self.dynamicISFActive = false
                }
                return isOn
            })
            subscribePreferencesSetting(\.autoISFmax, on: $autoISFmax) { autoISFmax = $0 }
            subscribePreferencesSetting(\.autoISFmin, on: $autoISFmin) { autoISFmin = $0 }
            subscribePreferencesSetting(\.higherISFrangeWeight, on: $higherISFrangeWeight) { higherISFrangeWeight = $0 }
            subscribePreferencesSetting(\.lowerISFrangeWeight, on: $lowerISFrangeWeight) { lowerISFrangeWeight = $0 }
            subscribePreferencesSetting(\.postMealISFweight, on: $postMealISFweight) { postMealISFweight = $0 }
            subscribePreferencesSetting(\.autoISFhourlyChange, on: $autoISFhourlyChange) { autoISFhourlyChange = $0 }
            subscribePreferencesSetting(\.enableBGacceleration, on: $enableBGacceleration) { enableBGacceleration = $0 }
            subscribePreferencesSetting(\.bgAccelISFweight, on: $bgAccelISFweight) { bgAccelISFweight = $0 }
            subscribePreferencesSetting(\.bgBrakeISFweight, on: $bgBrakeISFweight) { bgBrakeISFweight = $0 }
            subscribePreferencesSetting(\.autoISFoffSport, on: $autoISFoffSport) { autoISFoffSport = $0 }

            subscribePreferencesSetting(\.enableSMBEvenOnOddOffAlways, on: $enableSMBEvenOnOddOffAlways) {
                enableSMBEvenOnOddOffAlways = $0 }
            subscribePreferencesSetting(\.iobThresholdPercent, on: $iobThresholdPercent) { iobThresholdPercent = $0 }
            subscribePreferencesSetting(\.smbDeliveryRatioBGrange, on: $smbDeliveryRatioBGrange) {
                smbDeliveryRatioBGrange = $0 }
            subscribePreferencesSetting(\.smbDeliveryRatioMin, on: $smbDeliveryRatioMin) { smbDeliveryRatioMin = $0 }
            subscribePreferencesSetting(\.smbDeliveryRatioMax, on: $smbDeliveryRatioMax) { smbDeliveryRatioMax = $0 }
            subscribePreferencesSetting(\.smbMaxRangeExtension, on: $smbMaxRangeExtension) { smbMaxRangeExtension = $0 }

            subscribePreferencesSetting(\.enableB30, on: $enableB30) { enableB30 = $0 }
            subscribePreferencesSetting(\.B30iTimeStartBolus, on: $B30iTimeStartBolus) { B30iTimeStartBolus = $0 }
            subscribePreferencesSetting(\.B30iTime, on: $B30iTime) { B30iTime = $0 }
            subscribePreferencesSetting(\.B30iTimeTarget, on: $B30iTimeTarget) { B30iTimeTarget = $0 }
            subscribePreferencesSetting(\.B30upperLimit, on: $B30upperLimit) { B30upperLimit = $0 }
            subscribePreferencesSetting(\.B30upperDelta, on: $B30upperDelta) { B30upperDelta = $0 }
            subscribePreferencesSetting(\.B30basalFactor, on: $B30basalFactor) { B30basalFactor = $0 }
        }

        /// Sets the FCL e-book starting values (autoISF, SMB and autosens settings) in one go.
        func applyStartPreset(_ preset: AutoISFStartPreset) {
            var preferences = settingsManager.preferences
            preset.apply(to: &preferences)
            settingsManager.preferences = preferences
            dynamicISFActive = false
            autoisf = preferences.autoisf
            autoISFmax = preferences.autoISFmax
            autoISFmin = preferences.autoISFmin
            higherISFrangeWeight = preferences.higherISFrangeWeight
            lowerISFrangeWeight = preferences.lowerISFrangeWeight
            postMealISFweight = preferences.postMealISFweight
            autoISFhourlyChange = preferences.autoISFhourlyChange
            enableBGacceleration = preferences.enableBGacceleration
            bgAccelISFweight = preferences.bgAccelISFweight
            bgBrakeISFweight = preferences.bgBrakeISFweight
            autoISFoffSport = preferences.autoISFoffSport
            enableSMBEvenOnOddOffAlways = preferences.enableSMBEvenOnOddOffAlways
            iobThresholdPercent = preferences.iobThresholdPercent
            smbDeliveryRatioBGrange = preferences.smbDeliveryRatioBGrange
            smbDeliveryRatioMin = preferences.smbDeliveryRatioMin
            smbDeliveryRatioMax = preferences.smbDeliveryRatioMax
            smbMaxRangeExtension = preferences.smbMaxRangeExtension
            enableB30 = preferences.enableB30
        }

        /// The iobTH in units for the current max IOB, for the hint.
        var iobThresholdUnits: Decimal {
            (maxIOB * iobThresholdPercent * 10).rounded() / 10
        }
    }
}
