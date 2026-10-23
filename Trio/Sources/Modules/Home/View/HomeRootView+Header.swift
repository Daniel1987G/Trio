import SwiftUI
import UIKit

// MARK: - Device pickers

/// Presents the "Add CGM" / "Add Pump" pickers for the home screen.
///
/// Both selections are applied in `onDismiss` rather than inline: the home view already stacks several sheets,
/// and presenting the device setup sheet while the picker is still dismissing gets dropped by SwiftUI.
private struct DevicePickersModifier: ViewModifier {
    @Binding var showPumpSelection: Bool
    @Binding var showCGMSelection: Bool
    @Binding var pendingPump: PumpCatalogEntry?
    @Binding var pendingCGM: CGMCatalogEntry?
    let state: Home.StateModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPumpSelection, onDismiss: {
                if let entry = pendingPump {
                    pendingPump = nil
                    state.addPump(entry)
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add Pump", comment: "The title of the pump chooser in settings"),
                    entries: DeviceCatalog.pumps
                ) { entry in
                    pendingPump = entry
                    showPumpSelection = false
                }
            }
            .sheet(isPresented: $showCGMSelection, onDismiss: {
                if let entry = pendingCGM {
                    pendingCGM = nil
                    state.addCGM(cgm: CGMModel(entry))
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add CGM", comment: "The title of the CGM chooser in settings"),
                    entries: DeviceCatalog.cgms
                ) { entry in
                    pendingCGM = entry
                    showCGMSelection = false
                }
            }
    }
}

extension View {
    func devicePickers(
        showPumpSelection: Binding<Bool>,
        showCGMSelection: Binding<Bool>,
        pendingPump: Binding<PumpCatalogEntry?>,
        pendingCGM: Binding<CGMCatalogEntry?>,
        state: Home.StateModel
    ) -> some View {
        modifier(DevicePickersModifier(
            showPumpSelection: showPumpSelection,
            showCGMSelection: showCGMSelection,
            pendingPump: pendingPump,
            pendingCGM: pendingCGM,
            state: state
        ))
    }
}

// MARK: - Zone B: header (pump panel / glucose bobble / loop status)

extension Home.RootView {
    var glucoseView: some View {
        CurrentGlucoseView(
            timerDate: state.timerDate,
            units: state.units,
            alarm: state.alarm,
            lowGlucose: state.lowGlucose,
            highGlucose: state.highGlucose,
            cgmAvailable: state.cgmAvailable,
            currentGlucoseTarget: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme,
            glucose: state.latestTwoGlucoseValues,
            cgmProgress: state.cgmProgressHighlight,
            cgmStatus: state.cgmDisplayState,
            cgmSensorExpiresAt: state.cgmSensorExpiresAt,
            cgmWarmupEndsAt: state.cgmWarmupEndsAt
        )
        .onTapGesture {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }
        .onLongPressGesture {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()
            showSnoozeSheet = true
        }
        .accessibilityAction {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }
        .accessibilityAction(named: Text("Snooze alerts")) {
            showSnoozeSheet = true
        }
    }

    // Nur UI-Daten. Die Loop-Berechnung selbst bleibt unverändert.
    private var blackLayoutProfileISF: Decimal? {
        guard let entries = state.blackLayoutISFProfile?.sensitivities,
              !entries.isEmpty
        else {
            return nil
        }

        let calendar = Calendar.current
        let now = state.timerDate
        let midnight = calendar.startOfDay(for: now)
        let currentMinutes = calendar.dateComponents(
            [.minute], from: midnight, to: now
        ).minute ?? 0

        let sortedEntries = entries.sorted { $0.offset < $1.offset }

        guard let current = sortedEntries.last(where: {
            $0.offset <= currentMinutes
        }) ?? sortedEntries.last,
            current.sensitivity > 0
        else {
            return nil
        }

        return current.sensitivity
    }

    // Zuletzt berechneter ISF – Autosens oder Dynamic ISF.
    private var blackLayoutDynamicISF: Decimal? {
        guard let latest = state.enactedAndNonEnactedDeterminations.first,
              let date = latest.deliverAt,
              (0 ... 900).contains(Date().timeIntervalSince(date)),
              let sensitivity = latest.insulinSensitivity,
              sensitivity.decimalValue > 0
        else {
            return nil
        }

        return sensitivity.decimalValue
    }

    private func blackLayoutISFText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        ).stringValue
    }

    private var blackLayoutISFChangedAt: Date? {
        guard let current = blackLayoutDynamicISF else { return nil }

        func displayed(_ value: Decimal) -> Decimal {
            let scale: Int = state.units == .mmolL ? 1 : 0
            return Trio.rounded(
                value.asUnit(state.units),
                scale: scale,
                roundingMode: .plain
            )
        }

        let now = Date()
        let history = state.enactedAndNonEnactedDeterminations
            .compactMap { entry -> (value: Decimal, date: Date)? in
                guard let date = entry.deliverAt,
                      date <= now,
                      let isf = entry.insulinSensitivity,
                      isf.decimalValue > 0
                else {
                    return nil
                }
                return (displayed(isf.decimalValue), date)
            }
            .sorted { $0.date > $1.date }

        guard let first = history.first,
              first.value == displayed(current)
        else {
            return nil
        }

        var changedAt = first.date
        var previousDate = first.date

        for entry in history.dropFirst() {
            // Bei größeren Datenlücken keine Uhrzeit behaupten.
            guard previousDate.timeIntervalSince(entry.date) <= 900 else {
                return nil
            }

            if entry.value != first.value {
                return changedAt
            }

            changedAt = entry.date
            previousDate = entry.date
        }

        return nil
    }

    var pumpView: some View {
        PumpView(
            reservoir: state.reservoir,
            name: state.pumpName,
            expiresAtDate: state.pumpExpiresAtDate,
            activatedAtDate: state.pumpActivatedAtDate,
            timerDate: state.timerDate,
            pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
            battery: state.batteryFromPersistence,
            isfUnits: state.units,
            profileISF: blackLayoutProfileISF,
            dynamicISF: blackLayoutDynamicISF,
            dynamicISFChangedAt: blackLayoutISFChangedAt
        )
        .onTapGesture {
            if state.pumpDisplayState == nil {
                // shows user confirmation dialog with pump model choices, then proceeds to setup
                showPumpSelection.toggle()
            } else {
                // sends user to pump settings
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
        // group reservoir/battery/pod into one button so VO reads it as a single control
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(
            state.pumpDisplayState == nil
                ? String(localized: "Opens pump setup", comment: "Accessibility hint")
                : String(localized: "Opens pump settings", comment: "Accessibility hint")
        ))
        .accessibilityAction {
            if state.pumpDisplayState == nil {
                showPumpSelection.toggle()
            } else {
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
    }

    // Restlaufzeit im rechten Header, unabhängig vom CGM-Fortschrittsring.
    private func sensorRemainingString(until date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(state.timerDate))
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if days >= 1 { return "\(days)d \(hours)h" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func sensorRemainingColor(until date: Date) -> Color {
        date.timeIntervalSince(state.timerDate) <= 36 * 60 * 60 ? .loopRed : .white
    }

    private func sensorFrameColor(until date: Date) -> Color {
        date.timeIntervalSince(state.timerDate) <= 36 * 60 * 60
            ? Color.loopRed.opacity(0.65)
            : Color.white.opacity(0.45)
    }

    @ViewBuilder func rightHeaderPanel() -> some View {
        VStack(alignment: .center, spacing: 20) {
            /// Loop view at bottomLeading
            LoopView(
                dosingMode: state.dosingMode,
                timerDate: state.timerDate,
                isLooping: state.isLooping,
                lastLoopDate: state.lastLoopDate,
                manualTempBasal: state.manualTempBasal,
                lastGlucoseDate: state.lastGlucoseDate,
                lastPumpCommsDate: state.lastPumpCommsDate,
                hasDeviceIssue: state.hasDeviceIssue,
                determination: state.determinationsFromPersistence
            )
            .onTapGesture {
                state.isLoopStatusPresented = true
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(String(localized: "Opens loop status", comment: "Accessibility hint")))
            .accessibilityAction { state.isLoopStatusPresented = true }
            /// eventualBG string at bottomTrailing

            if let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG {
                let eventualGlucose = eventualBG as Decimal
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .font(.callout)
                        .fontWeight(.bold)

                    Text(state.units == .mgdL ? eventualGlucose.description : eventualGlucose.formattedAsMmolL)
                        .font(.callout)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Eventual glucose"))
                .accessibilityValue(Text(
                    (state.units == .mgdL ? eventualGlucose.description : eventualGlucose.formattedAsMmolL)
                        + " " + state.units.spokenValue
                ))
            } else {
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .font(.callout).fontWeight(.bold)
                    Text("--")
                        .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Eventual glucose"))
                .accessibilityValue(Text(verbatim: "--"))
            }

            // Sensor-Restlaufzeit rechts direkt unter dem erwarteten Wert.
            if let sensorExpiresAt = state.cgmSensorExpiresAt {
                HStack {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                    Text(sensorRemainingString(until: sensorExpiresAt))
                        .font(.body)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                        .foregroundStyle(sensorRemainingColor(until: sensorExpiresAt))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .overlay {
                    Capsule()
                        .stroke(sensorFrameColor(until: sensorExpiresAt), lineWidth: 1.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Sensor remaining time"))
                .accessibilityValue(Text(sensorRemainingString(until: sensorExpiresAt)))
            }
        }
    }
}
