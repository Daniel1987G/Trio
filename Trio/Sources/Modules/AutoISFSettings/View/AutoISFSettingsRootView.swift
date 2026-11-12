import SwiftUI
import Swinject

extension AutoISFSettings {
    /// autoISF (ported from Tai): adapts the ISF to glucose level, rise and duration, controls SMBs and
    /// offers the B30 boost basal after a meal bolus.
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        @State var hintDetent = PresentationDetent.large
        @State private var hintPayload: HintPayload?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private struct HintPayload: Identifiable {
            let id = UUID()
            let label: String
            let content: AnyView
        }

        private var shouldDisplayHintBinding: Binding<Bool> {
            Binding(
                get: { hintPayload != nil },
                set: { newValue in
                    if !newValue {
                        hintPayload = nil
                    } else if hintPayload == nil {
                        hintPayload = HintPayload(label: "", content: AnyView(EmptyView()))
                    }
                }
            )
        }

        private func verboseHintBinding(label: String) -> Binding<(any View)?> {
            Binding(
                get: { hintPayload?.content },
                set: { newView in
                    if let view = newView {
                        hintPayload = HintPayload(label: label, content: AnyView(view))
                    } else {
                        hintPayload = nil
                    }
                }
            )
        }

        private func decimalRow<Hint: View>(
            _ value: Binding<Decimal>,
            key: String,
            label: String,
            miniHint: String,
            header: String? = nil,
            @ViewBuilder hint: () -> Hint
        ) -> some View {
            SettingInputSection(
                decimalValue: value,
                booleanValue: $booleanPlaceholder,
                shouldDisplayHint: shouldDisplayHintBinding,
                selectedVerboseHint: verboseHintBinding(label: label),
                units: state.units,
                type: .decimal(key),
                label: label,
                miniHint: miniHint,
                verboseHint: VStack(alignment: .leading, spacing: 10) { hint() },
                headerText: header
            )
        }

        private func toggleRow<Hint: View>(
            _ value: Binding<Bool>,
            label: String,
            miniHint: String,
            header: String? = nil,
            disabled: Bool = false,
            @ViewBuilder hint: () -> Hint
        ) -> some View {
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: value,
                shouldDisplayHint: shouldDisplayHintBinding,
                selectedVerboseHint: verboseHintBinding(label: label),
                units: state.units,
                type: .boolean,
                label: label,
                miniHint: miniHint,
                verboseHint: VStack(alignment: .leading, spacing: 10) { hint() },
                headerText: header,
                isToggleDisabled: disabled
            )
        }

        var body: some View {
            List {
                toggleRow(
                    $state.autoisf,
                    label: String(localized: "Activate autoISF"),
                    miniHint: state.dynamicISFActive ?
                        String(localized: "Dynamic ISF is on. Turning on autoISF turns Dynamic ISF off.") :
                        String(localized: "Adapt the ISF to how high glucose is, how fast it rises and how long it stays high."),
                    header: "autoISF"
                ) {
                    Text("Default: Off").bold()
                    Text(
                        "autoISF strengthens your ISF when glucose is above target and keeps rising or stays high, and weakens it below target. The factors below decide how much; the strongest one wins and is kept within autoISF Min and autoISF Max."
                    )
                    Text(
                        "It also controls SMBs (iobTH, even/odd target) and offers the B30 boost basal after a meal bolus."
                    )
                    Text("autoISF and Dynamic ISF exclude each other. Autosens keeps working alongside autoISF.")
                    Text(
                        "Warning: autoISF changes your insulin dosing directly. Start with small weights, watch the reason in the loop status and change one setting at a time."
                    ).bold()
                }

                if state.autoisf {
                    isfSections
                    smbSections
                    b30Sections
                }
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(item: $hintPayload) { payload in
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: shouldDisplayHintBinding,
                    hintLabel: payload.label,
                    hintText: payload.content,
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("autoISF")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }

        // MARK: - ISF

        @ViewBuilder private var isfSections: some View {
            decimalRow(
                $state.autoISFmax,
                key: "autoISFmax",
                label: String(localized: "autoISF Max"),
                miniHint: String(localized: "Upper limit for the autoISF factor."),
                header: String(localized: "ISF Adaptation")
            ) {
                Text("Default: 1.5").bold()
                Text(
                    "The ISF is divided by the autoISF factor: 1.5 turns an ISF of 45 into 30. This limits how much stronger the ISF can get."
                )
            }
            decimalRow(
                $state.autoISFmin,
                key: "autoISFmin",
                label: String(localized: "autoISF Min"),
                miniHint: String(localized: "Lower limit for the autoISF factor.")
            ) {
                Text("Default: 0.7").bold()
                Text("Limits how much weaker the ISF can get below target. 0.7 turns an ISF of 45 into 64 at most.")
            }
            decimalRow(
                $state.higherISFrangeWeight,
                key: "higherISFrangeWeight",
                label: String(localized: "Weight Above Target"),
                miniHint: String(localized: "How strongly glucose above target strengthens the ISF.")
            ) {
                Text("Default: 0.3").bold()
                Text(
                    "bg-ISF: from 20 mg/dL (1.1 mmol/L) above target a curve rises with glucose and reaches 0.7 at 90 mg/dL (5 mmol/L) above target. This weight scales the curve: 0.3 gives a factor of 1.21 there. 0 turns it off."
                )
            }
            decimalRow(
                $state.lowerISFrangeWeight,
                key: "lowerISFrangeWeight",
                label: String(localized: "Weight Below Target"),
                miniHint: String(localized: "How strongly glucose below target weakens the ISF.")
            ) {
                Text("Default: 0.7").bold()
                Text(
                    "Up to 10 mg/dL (0.6 mmol/L) above target the curve turns negative: −0.2 at target, −0.5 from 30 mg/dL (1.7 mmol/L) below. This weight scales it: 0.7 gives 0.86 at target and 0.65 further below, so less insulin. autoISF Min still applies. 0 turns it off."
                )
            }
            decimalRow(
                $state.postMealISFweight,
                key: "postMealISFweight",
                label: String(localized: "Post-Meal Weight"),
                miniHint: String(localized: "Strengthens the ISF while glucose rises above target.")
            ) {
                Text("Default: 0.02").bold()
                Text(
                    "pp-ISF: factor = 1 + delta × weight, only above target + 10 mg/dL and while glucose rises. With 0.02, a rise of 10 mg/dL in 5 minutes gives 1.2."
                )
            }
            decimalRow(
                $state.autoISFhourlyChange,
                key: "autoISFhourlyChange",
                label: String(localized: "Duration Weight"),
                miniHint: String(localized: "Strengthens the ISF the longer glucose stays high.")
            ) {
                Text("Default: 0.6").bold()
                Text(
                    "dura-ISF: when glucose stays within 5 % of its average for at least 10 minutes above target, the factor grows with time and with the distance to target."
                )
            }
            toggleRow(
                $state.enableBGacceleration,
                label: String(localized: "Use Glucose Acceleration"),
                miniHint: String(localized: "Use a curve fit of the last 15 to 45 minutes.")
            ) {
                Text("Default: On").bold()
                Text(
                    "acce-ISF: a parabola is fitted to the recent glucose values. Only a good fit (R² ≥ 0.9) counts: speeding up strengthens the ISF, slowing down weakens it."
                )
            }
            if state.enableBGacceleration {
                decimalRow(
                    $state.bgAccelISFweight,
                    key: "bgAccelISFweight",
                    label: String(localized: "Acceleration Weight"),
                    miniHint: String(localized: "Effect of glucose speeding up away from target.")
                ) {
                    Text("Default: 0.15").bold()
                    Text("Higher values strengthen the ISF more while glucose speeds up away from target.")
                }
                decimalRow(
                    $state.bgBrakeISFweight,
                    key: "bgBrakeISFweight",
                    label: String(localized: "Brake Weight"),
                    miniHint: String(localized: "Effect of glucose slowing down or turning.")
                ) {
                    Text("Default: 0.15").bold()
                    Text(
                        "Higher values weaken the ISF more while glucose slows down, and when the curve predicts glucose below target within 30 minutes."
                    )
                }
            }
            toggleRow(
                $state.autoISFoffSport,
                label: String(localized: "autoISF Off With Exercise"),
                miniHint: String(localized: "No ISF adaptation while a high temp target raises sensitivity.")
            ) {
                Text("Default: Off").bold()
                Text(
                    "With a high temporary target and \"High Temptarget Raises Sensitivity\" on, autoISF leaves the ISF alone."
                )
            }
        }

        // MARK: - SMB

        @ViewBuilder private var smbSections: some View {
            toggleRow(
                $state.enableSMBEvenOnOddOffAlways,
                label: String(localized: "SMB: Even On, Odd Off"),
                miniHint: String(localized: "Even target allows SMBs, odd target blocks them."),
                header: String(localized: "autoISF SMB")
            ) {
                Text("Default: Off").bold()
                Text(
                    "With this on, an odd target (e.g. 99 mg/dL or 5.5 mmol/L) switches SMBs off. An even target allows them, but only if your SMB settings allow them too."
                )
                Text("An even temporary target below 100 mg/dL allows SMBs at full delivery ratio.")
            }
            decimalRow(
                $state.iobThresholdPercent,
                key: "iobThresholdPercent",
                label: String(localized: "IOB Threshold (iobTH)"),
                miniHint: state.iobThresholdPercent < 1 ?
                    String(localized: "SMBs stop above \(state.iobThresholdUnits.description) U IOB.") :
                    String(localized: "100 % turns the threshold off.")
            ) {
                Text("Default: 100 % (off)").bold()
                Text(
                    "Share of Max IOB above which SMBs stop. A single SMB may take IOB to at most 130 % of this threshold. With a high temp target that raises sensitivity, the threshold drops with it."
                )
            }
            decimalRow(
                $state.smbDeliveryRatioBGrange,
                key: "smbDeliveryRatioBGrange",
                label: String(localized: "SMB Ratio Glucose Range"),
                miniHint: String(localized: "0 keeps the fixed SMB delivery ratio.")
            ) {
                Text("Default: 0 (off)").bold()
                Text(
                    "Above 0 the SMB delivery ratio rises from SMB Ratio Min at target to SMB Ratio Max at target + this range."
                )
            }
            if state.smbDeliveryRatioBGrange > 0 {
                decimalRow(
                    $state.smbDeliveryRatioMin,
                    key: "smbDeliveryRatioMin",
                    label: String(localized: "SMB Ratio Min"),
                    miniHint: String(localized: "SMB delivery ratio at target.")
                ) {
                    Text("Default: 50 %").bold()
                }
                decimalRow(
                    $state.smbDeliveryRatioMax,
                    key: "smbDeliveryRatioMax",
                    label: String(localized: "SMB Ratio Max"),
                    miniHint: String(localized: "SMB delivery ratio at the top of the range.")
                ) {
                    Text("Default: 80 %").bold()
                }
            }
            decimalRow(
                $state.smbMaxRangeExtension,
                key: "smbMaxRangeExtension",
                label: String(localized: "SMB Size Extension"),
                miniHint: String(localized: "Multiplies the largest possible SMB.")
            ) {
                Text("Default: 1 (off)").bold()
                Text(
                    "The largest SMB (from Max SMB/UAM Basal Minutes) is multiplied by this value. Max Bolus and Max IOB still apply."
                )
            }
        }

        // MARK: - B30

        @ViewBuilder private var b30Sections: some View {
            toggleRow(
                $state.enableB30,
                label: String(localized: "Activate B30"),
                miniHint: String(localized: "Boost basal after a meal bolus with an eating soon target."),
                header: "B30"
            ) {
                Text("Default: Off").bold()
                Text(
                    "B30 (from AIMI) raises the basal for a while after a manual bolus, to fill the insulin depot before the meal. It starts only when all of this is true:"
                )
                Text(
                    "• a manual bolus of at least the minimum bolus\n• a temporary target equal to the B30 target\n• glucose below the upper limit and its rise below the upper delta"
                )
                Text("While B30 runs, SMBs are off. The max safe basal and the low glucose suspend still apply.")
                Text("Warning: B30 skips most of oref's other checks while it runs.").bold()
            }
            if state.enableB30 {
                decimalRow(
                    $state.B30iTimeStartBolus,
                    key: "B30iTimeStartBolus",
                    label: String(localized: "B30 Minimum Bolus"),
                    miniHint: String(localized: "Smallest manual bolus that starts B30.")
                ) {
                    Text("Default: 1 U").bold()
                }
                decimalRow(
                    $state.B30iTime,
                    key: "B30iTime",
                    label: String(localized: "B30 Duration"),
                    miniHint: String(localized: "Minutes after the bolus during which B30 runs.")
                ) {
                    Text("Default: 30 min").bold()
                }
                decimalRow(
                    $state.B30iTimeTarget,
                    key: "B30iTimeTarget",
                    label: String(localized: "B30 Target"),
                    miniHint: String(localized: "Set exactly this temporary target to start B30.")
                ) {
                    Text("Default: 90 mg/dL (5.0 mmol/L)").bold()
                }
                decimalRow(
                    $state.B30upperLimit,
                    key: "B30upperLimit",
                    label: String(localized: "B30 Upper Glucose Limit"),
                    miniHint: String(localized: "B30 stops at or above this glucose.")
                ) {
                    Text("Default: 130 mg/dL (7.2 mmol/L)").bold()
                }
                decimalRow(
                    $state.B30upperDelta,
                    key: "B30upperDelta",
                    label: String(localized: "B30 Upper Delta"),
                    miniHint: String(localized: "B30 stops when glucose rises faster per 5 minutes.")
                ) {
                    Text("Default: 8 mg/dL (0.4 mmol/L)").bold()
                }
                decimalRow(
                    $state.B30basalFactor,
                    key: "B30basalFactor",
                    label: String(localized: "B30 Basal Factor"),
                    miniHint: String(localized: "Current basal × this factor, at most the max safe basal.")
                ) {
                    Text("Default: 5").bold()
                }
            }
        }
    }
}
