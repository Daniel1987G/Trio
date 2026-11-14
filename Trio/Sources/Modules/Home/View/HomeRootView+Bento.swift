import SwiftUI
import UIKit

// MARK: - Zone B/C as bento tiles

/// The tiled header. It fills the classic header slot (glucose, loop, IOB, COB) and the meal slot
/// below it (pump and forecast tiles plus the alarms bell), so the chart keeps its height. Taps
/// open the same screens as in the classic layout.
extension Home.RootView {
    @ViewBuilder func bentoHeaderTop() -> some View {
        // two equal halves: glucose left, loop / IOB / COB right
        HStack(spacing: BentoLayout.spacing) {
            bentoGlucoseTile
                .frame(maxWidth: .infinity)
            VStack(spacing: BentoLayout.spacing) {
                bentoLoopTile
                    .frame(height: BentoLayout.tileHeight)
                HStack(spacing: BentoLayout.spacing) {
                    BentoValueTile(
                        title: String(localized: "IOB", comment: "Insulin on board, short"),
                        value: Formatter.decimalFormatterWithTwoFractionDigits
                            .string(from: state.currentIOB as NSNumber) ?? "0",
                        unit: String(localized: "U", comment: "Insulin unit"),
                        tint: Color.insulin,
                        titleColor: Color.insulin
                    )
                    BentoValueTile(
                        title: String(localized: "COB", comment: "Carbs on board, short"),
                        value: Formatter.integerFormatter.string(
                            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                        ) ?? "0",
                        unit: String(localized: "g", comment: "gram of carbs"),
                        tint: Color.orange,
                        titleColor: Color.orange
                    )
                }
                .frame(height: BentoLayout.tileHeight)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var bentoGlucoseTile: some View {
        BentoGlucoseTile(
            timerDate: state.timerDate,
            units: state.units,
            lowGlucose: state.lowGlucose,
            highGlucose: state.highGlucose,
            cgmAvailable: state.cgmAvailable,
            currentGlucoseTarget: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme,
            glucose: state.latestTwoGlucoseValues,
            cgmStatus: state.cgmDisplayState,
            cgmSensorExpiresAt: state.cgmSensorExpiresAt,
            cgmWarmupEndsAt: state.cgmWarmupEndsAt
        )
        .frame(height: BentoLayout.tileHeight * 2 + BentoLayout.spacing)
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
        .accessibilityAddTraits(.isButton)
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

    /// ISF badge of the loop tile: Dynamic ISF's sensitivity ratio or the autoISF factor.
    @ViewBuilder private var loopTileISFBadge: some View {
        if state.isDynamicISFEnabled,
           let ratio = state.enactedAndNonEnactedDeterminations.first?.sensitivityRatio?.decimalValue,
           ratio > 0
        {
            DynamicISFBadge(ratio: ratio)
        } else if state.isAutoISFEnabled,
                  let reason = state.enactedAndNonEnactedDeterminations.first?.reason,
                  let factor = AutoISFReason.finalRatio(fromReason: reason),
                  factor > 0
        {
            DynamicISFBadge(ratio: factor, source: .autoISF)
        }
    }

    private var bentoLoopTile: some View {
        BentoTile(tint: nil) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.dosingMode.displayName)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    // the classic loop indicator, so ring colour, open-ring modes and caption stay identical
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
                    if state.isDynamicISFEnabled || state.isAutoISFEnabled {
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            loopTileISFBadge
                            if let fclSet = state.activeFCLSet {
                                FCLBadge(preset: fclSet, isAdjusted: state.isFCLSetAdjusted)
                            }
                        }
                    }
                }
            }
        }
        .onTapGesture {
            state.isLoopStatusPresented = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(String(localized: "Opens loop status", comment: "Accessibility hint")))
        .accessibilityAction { state.isLoopStatusPresented = true }
    }

    /// Lives in the meal slot; the chart readout fades over it while scrubbing, as in the classic layout.
    @ViewBuilder var bentoBottomRow: some View {
        HStack(spacing: BentoLayout.spacing) {
            statisticsButton(tile: true)

            BentoPumpTile(
                reservoir: state.reservoir,
                expiresAtDate: state.pumpExpiresAtDate,
                activatedAtDate: state.pumpActivatedAtDate,
                timerDate: state.timerDate,
                pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
                battery: state.batteryFromPersistence,
                insulinConcentration: state.pumpInsulinConcentration,
                insulinConcentrationSyncPending: state.pumpInsulinConcentrationSyncPending
            )
            .onTapGesture {
                if state.pumpDisplayState == nil {
                    showPumpSelection.toggle()
                } else {
                    state.shouldDisplayPumpSetupSheet.toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if state.pumpDisplayState == nil {
                    showPumpSelection.toggle()
                } else {
                    state.shouldDisplayPumpSetupSheet.toggle()
                }
            }

            BentoTile(tint: nil, cornerRadius: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                        .font(.footnote).fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text(bentoEventualGlucoseText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 84)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Eventual glucose"))
            .accessibilityValue(Text(bentoEventualGlucoseText + " " + state.units.spokenValue))

            alarmsPill
        }
        .frame(height: HomeLayout.mealSlotHeight - 8)
        .padding(.horizontal, 16)
        // top-aligned: 10 pt below the tiles above, 8 pt free towards the chart
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var bentoEventualGlucoseText: String {
        guard let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG else { return "--" }
        let value = eventualBG as Decimal
        return state.units == .mgdL ? value.description : value.formattedAsMmolL
    }
}
