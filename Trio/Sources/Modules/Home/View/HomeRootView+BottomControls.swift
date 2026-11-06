import CoreData
import SwiftDate
import SwiftUI

// MARK: - Zone E: bottom controls (adjustment panel / bolus progress)

extension Home.RootView {
    var bolusProgressFormatter: NumberFormatter {
        let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
        case 0.1: 1
        case 0.025: 3
        default: 2
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = fractionDigits
        formatter.allowsFloats = true
        formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
        return formatter
    }

    private var fetchedTargetFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if state.units == .mmolL {
            formatter.maximumFractionDigits = 1
        } else { formatter.maximumFractionDigits = 0 }
        return formatter
    }

    func remainingFraction(start: Date?, durationMinutes: Decimal?, indefinite: Bool) -> Double? {
        guard !indefinite, let start = start, let durationMinutes = durationMinutes, durationMinutes > 0 else {
            return nil
        }
        let total = Double(truncating: durationMinutes as NSNumber) * 60
        let elapsed = Date().timeIntervalSince(start)
        guard total > 0 else { return nil }
        return min(max(1 - elapsed / total, 0), 1)
    }

    var overrideRemainingFraction: Double? {
        guard let o = latestOverride.first else { return nil }
        return remainingFraction(start: o.date, durationMinutes: o.duration as Decimal?, indefinite: o.indefinite)
    }

    var tempTargetRemainingFraction: Double? {
        guard let t = latestTempTarget.first else { return nil }
        return remainingFraction(start: t.date, durationMinutes: t.duration as Decimal?, indefinite: false)
    }

    @ViewBuilder func adjustmentIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint.opacity(0.18)))
            .accessibilityHidden(true)
    }

    var adjustmentTint: Color? {
        if overrideString != nil { return Color.purple }
        if tempTargetString != nil { return Color.loopGreen }
        return nil
    }

    var overrideString: String? {
        guard let latestOverride = latestOverride.first else {
            return nil
        }

        guard let settingsManager = state.settingsManager else {
            return nil
        }

        let percent = latestOverride.percentage
        let percentString = percent == 100 ? "" : "\(percent.formatted(.number)) %"

        let unit = state.units
        var target = (latestOverride.target ?? 0) as Decimal
        target = unit == .mmolL ? target.asMmolL : target

        var targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " + unit
            .rawValue
        if tempTargetString != nil {
            targetString = ""
        }

        let duration = latestOverride.duration ?? 0
        let addedMinutes = Int(truncating: duration)
        let date = latestOverride.date ?? Date()
        let newDuration = max(
            Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
            0
        )
        let indefinite = latestOverride.indefinite
        var durationString = ""

        if !indefinite {
            if newDuration >= 1 {
                durationString = formatHrMin(Int(newDuration))
            } else if newDuration > 0 {
                durationString = "\(Int(newDuration * 60)) s"

            } else {
                /// Do not show the Override anymore
                Task {
                    guard let objectID = self.latestOverride.first?.objectID else { return }
                    await state.cancelOverride(withID: objectID)
                }
            }
        }

        let smbScheduleString = latestOverride
            .smbIsScheduledOff && ((latestOverride.start?.stringValue ?? "") != (latestOverride.end?.stringValue ?? ""))
            ? " \(formatTimeRange(start: latestOverride.start?.stringValue, end: latestOverride.end?.stringValue))"
            : ""

        let smbToggleString = latestOverride.smbIsOff || latestOverride
            .smbIsScheduledOff ? String(localized: "SMBs Off\(smbScheduleString)") : ""

        var smbMinuteString: String = ""
        var uamMinuteString: String = ""

        if !latestOverride.smbIsOff, latestOverride.advancedSettings {
            if let smbMinutes = latestOverride.smbMinutes,
               smbMinutes.decimalValue != settingsManager.preferences.maxSMBBasalMinutes
            {
                smbMinuteString = "SMB\u{00A0}\(smbMinutes)\u{00A0}" +
                    String(localized: "m", comment: "Abbreviation for Minutes")
            }

            if let uamMinutes = latestOverride.uamMinutes,
               uamMinutes.decimalValue != settingsManager.preferences.maxUAMSMBBasalMinutes
            {
                uamMinuteString = "UAM\u{00A0}\(uamMinutes)\u{00A0}" +
                    String(localized: "m", comment: "Abbreviation for Minutes")
            }
        }

        let components = [durationString, percentString, targetString, smbToggleString, smbMinuteString, uamMinuteString]
            .filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    var tempTargetString: String? {
        guard let latestTempTarget = latestTempTarget.first else {
            return nil
        }
        let duration = latestTempTarget.duration
        let addedMinutes = Int(truncating: duration ?? 0)
        let date = latestTempTarget.date ?? Date()
        let newDuration = max(
            Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
            0
        )
        var durationString = ""
        var percentageString = ""
        var target = (latestTempTarget.target ?? 100) as Decimal
        // Use TempTargetCalculations to get effective HBT (handles both custom and auto-adjusted standard TT)
        let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
            tempTargetHalfBasalTarget: latestTempTarget.halfBasalTarget?.decimalValue,
            settingHalfBasalTarget: state.settingHalfBasalTarget,
            target: target,
            autosensMax: state.autosensMax
        ) ?? state.settingHalfBasalTarget
        var showPercentage = false
        if target > 100, state.isExerciseModeActive || state.highTTraisesSens { showPercentage = true }
        if target < 100, state.lowTTlowersSens, state.autosensMax > 1 { showPercentage = true }
        if showPercentage {
            percentageString =
                " \(Int(TempTargetCalculations.computeAdjustedPercentage(halfBasalTarget: effectiveHBT, target: target, autosensMax: state.autosensMax)))%"
        }
        target = state.units == .mmolL ? target.asMmolL : target
        let targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " +
            state.units.rawValue + percentageString

        if newDuration >= 1 {
            durationString =
                "\(newDuration.formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) min"
        } else if newDuration > 0 {
            durationString =
                "\((newDuration * 60).formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) s"
        } else {
            /// Do not show the Temp Target anymore
            Task {
                guard let objectID = self.latestTempTarget.first?.objectID else { return }
                await state.cancelTempTarget(withID: objectID)
            }
        }

        let components = [targetString, durationString].filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    @ViewBuilder func adjustmentsOverrideView(_ overrideString: String) -> some View {
        Group {
            adjustmentIcon("clock.arrow.2.circlepath", tint: Color.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(latestOverride.first?.name ?? String(localized: "Custom Override"))
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(alignment: .leading)

                Text(overrideString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func adjustmentsTempTargetView(_ tempTargetString: String) -> some View {
        Group {
            adjustmentIcon("target", tint: Color.loopGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(latestTempTarget.first?.name ?? String(localized: "Temp Target"))
                    .font(.subheadline).fontWeight(.semibold)
                Text(tempTargetString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func adjustmentsCancelView(_ cancelAction: @escaping () -> Void) -> some View {
        Image(systemName: "xmark.app")
            .font(.title)
            .onTapGesture {
                cancelAction()
            }
            .accessibilityLabel(Text("Stop adjustment"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { cancelAction() }
    }

    @ViewBuilder func adjustmentsCancelTempTargetView() -> some View {
        Image(systemName: "xmark.app")
            .font(.title)
            .glassActionSheet(
                "Stop the Temp Target \"\(latestTempTarget.first?.name ?? "")\"?",
                isPresented: $isConfirmStopTempTargetShown,
                actions: [
                    GlassSheetAction("Stop", role: .destructive) {
                        Task {
                            guard let objectID = latestTempTarget.first?.objectID else { return }
                            await state.cancelTempTarget(withID: objectID)
                        }
                    }
                ]
            )
            .padding(.trailing, 8)
            .onTapGesture {
                if !latestTempTarget.isEmpty {
                    isConfirmStopTempTargetShown = true
                }
            }
            .accessibilityLabel(Text("Stop temp target"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if !latestTempTarget.isEmpty {
                    isConfirmStopTempTargetShown = true
                }
            }
    }

    @ViewBuilder func adjustmentsCancelOverrideView() -> some View {
        Image(systemName: "xmark.app")
            .font(.title)
            .glassActionSheet(
                "Stop the Override \"\(latestOverride.first?.name ?? "")\"?",
                isPresented: $isConfirmStopOverridePresented,
                actions: [
                    GlassSheetAction("Stop", role: .destructive) {
                        Task {
                            guard let objectID = latestOverride.first?.objectID else { return }
                            await state.cancelOverride(withID: objectID)
                        }
                    }
                ]
            )
            .padding(.trailing, 8)
            .onTapGesture {
                if !latestOverride.isEmpty {
                    isConfirmStopOverridePresented = true
                }
            }
            .accessibilityLabel(Text("Stop override"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if !latestOverride.isEmpty {
                    isConfirmStopOverridePresented = true
                }
            }
    }

    @ViewBuilder func noActiveAdjustmentsView() -> some View {
        Group {
            adjustmentIcon("slider.horizontal.2.gobackward", tint: Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("No Active Adjustment")
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Profile at 100 %")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // clear icon keeps text aligned with the cancel-button states
            Image(systemName: "xmark.app")
                .font(.title)
                .foregroundStyle(Color.clear)
        }
    }

    // same track pattern as BolusProgressBar, slightly slimmer
    @ViewBuilder func remainingBar(_ fraction: Double?, tint: Color) -> some View {
        GeometryReader { barGeo in
            if let fraction {
                RoundedRectangle(cornerRadius: 15)
                    .fill(tint.opacity(0.85))
                    .frame(width: barGeo.size.width * fraction, height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder func adjustmentView() -> some View {
        let tint = adjustmentTint
        // concurrent override + temp target: halved tint, one remaining bar per half
        let isConcurrent = overrideString != nil && tempTargetString != nil

        ZStack {
            if isConcurrent {
                // halved tint layer the single-tint glass chrome can't express
                HStack(spacing: 0) {
                    Color.purple.opacity(0.12)
                    Color.loopGreen.opacity(0.12)
                }
                .clipShape(GlassChrome.panelShape)
            }
            HStack {
                if let overrideString = overrideString, let tempTargetString = tempTargetString {
                    // content halves match the tint halves so icons clear the seam
                    HStack(spacing: 0) {
                        HStack {
                            adjustmentsOverrideView(overrideString)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)

                        HStack {
                            adjustmentsTempTargetView(tempTargetString)
                                .padding(.leading, 8)

                            Spacer(minLength: 0)

                            adjustmentsCancelView({
                                if !latestTempTarget.isEmpty, !latestOverride.isEmpty {
                                    showCancelConfirmDialog = true
                                } else if !latestOverride.isEmpty {
                                    showCancelAlert = true
                                } else if !latestTempTarget.isEmpty {
                                    showCancelAlert = true
                                }
                            })
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else if let overrideString = overrideString {
                    adjustmentsOverrideView(overrideString)
                    Spacer()
                    adjustmentsCancelOverrideView()

                } else if let tempTargetString = tempTargetString {
                    HStack {
                        adjustmentsTempTargetView(tempTargetString)
                        Spacer()
                        adjustmentsCancelTempTargetView()
                    }
                } else {
                    noActiveAdjustmentsView()
                }
            }.padding(.horizontal, 10)
                .glassActionSheet(
                    "Adjustment to Stop",
                    message: Text("Select Adjustment"),
                    isPresented: $showCancelConfirmDialog,
                    actions: [
                        GlassSheetAction("Stop Override", role: .destructive) {
                            Task {
                                guard let objectID = latestOverride.first?.objectID else { return }
                                await state.cancelOverride(withID: objectID)
                            }
                        },
                        GlassSheetAction("Stop Temp Target", role: .destructive) {
                            Task {
                                guard let objectID = latestTempTarget.first?.objectID else { return }
                                await state.cancelTempTarget(withID: objectID)
                            }
                        },
                        GlassSheetAction("Stop All Adjustments", role: .destructive) {
                            Task {
                                guard let overrideObjectID = latestOverride.first?.objectID else { return }
                                await state.cancelOverride(withID: overrideObjectID)

                                guard let tempTargetObjectID = latestTempTarget.first?.objectID else { return }
                                await state.cancelTempTarget(withID: tempTargetObjectID)
                            }
                        }
                    ]
                )
        }
        .frame(height: HomeLayout.bottomPanelHeight)
        .glassPanel(
            tint: isConcurrent ? nil : tint,
            tintOpacity: 0.12,
            strokeOpacity: isConcurrent ? 0 : (tint == nil ? 0.08 : 0.30)
        )
        .overlay(
            // concurrent halves get a bicolor rim the single-tint chrome can't express
            isConcurrent
                ? GlassChrome.panelShape.strokeBorder(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.30), Color.loopGreen.opacity(0.30)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
                : nil
        )
        .overlay(alignment: .bottom) {
            // anchored like the bolus progress bar so both panels match
            Group {
                if isConcurrent {
                    HStack(spacing: 6) {
                        remainingBar(overrideRemainingFraction, tint: .purple)
                        remainingBar(tempTargetRemainingFraction, tint: .loopGreen)
                    }
                } else if let tint = tint {
                    remainingBar(overrideRemainingFraction ?? tempTargetRemainingFraction, tint: tint)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 1)
        }
        // whole panel navigates; the cancel buttons' own gestures take precedence
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTab = 2
        }
        .accessibilityHint(Text(String(localized: "Opens adjustments", comment: "Accessibility hint")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectedTab = 2 }
        .padding(.horizontal, 10)
    }

    @ViewBuilder func bolusView(_ progress: Decimal) -> some View {
        /// ensure that state.lastPumpBolus has a value, i.e. there is a last bolus done by the pump and not an external bolus
        /// - TRUE:  show the pump bolus
        /// - FALSE:  do not show a progress bar at all
        if let bolusTotal = state.lastPumpBolus?.bolus?.amount {
            let bolusFraction = progress * (bolusTotal as Decimal)
            let bolusString =
                (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view") +
                    (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")
            let bolusLabel = state
                .bolusStatus == .inProgress ? String(localized: "Bolusing") : String(localized: "Initiating…")
            let pulses = omnipodPulses(total: bolusTotal as Decimal, progress: progress)

            HStack {
                Image(systemName: "cross.vial.fill")
                    .font(.system(size: 25))
                    .accessibilityHidden(true)

                Spacer()

                VStack {
                    Text(bolusLabel)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(bolusString + (pulses.map { " · " + $0 } ?? ""))
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(bolusLabel))
                    .accessibilityValue(Text(bolusString + (pulses.map { ", " + $0 } ?? "")))

                Spacer()

                if state.bolusStatus == .inProgress {
                    Button {
                        state.showProgressView()
                        state.cancelBolus()
                    } label: {
                        Image(systemName: "xmark.app")
                            .font(.system(size: 25))
                    }
                    .accessibilityLabel(Text("Cancel bolus"))
                } else if state.bolusStatus == .initiating {
                    ProgressView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.trailing, 8)
            .frame(height: HomeLayout.bottomPanelHeight)
            .glassPanel(tint: .insulin, tintOpacity: 0.18, strokeOpacity: 0.30)
            .overlay(alignment: .bottom) {
                // bar hugs the panel's bottom edge (the slot no longer has outer bottom padding)
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .padding(.horizontal, 10)
        }
    }

    /// "10 of 20 pulses" for an Omnipod bolus. The total is in actual units, so it is converted to pump
    /// units for the insulin concentration first (2 U of U200 are 1 pump U = 20 pulses).
    func omnipodPulses(total: Decimal, progress: Decimal) -> String? {
        guard let pulseSize = state.omnipodPulseSize, pulseSize > 0 else { return nil }
        let pumpUnits = state.pumpInsulinConcentration.toPump(total)
        let totalPulses = Int(Double(truncating: (pumpUnits / pulseSize) as NSNumber).rounded())
        guard totalPulses > 0 else { return nil }
        let fraction = min(max(Double(truncating: progress as NSNumber), 0), 1)
        let delivered = Int((fraction * Double(totalPulses)).rounded(.down))
        return String(
            localized: "\(delivered) of \(totalPulses) pulses",
            comment: "Omnipod bolus progress: delivered and total pod pulses"
        )
    }

    func statsDistributionBar(_ segments: [(color: Color, fraction: CGFloat)]) -> some View {
        GeometryReader { g in
            let spacing: CGFloat = 2
            let shown = segments.filter { $0.fraction > 0.005 }
            let available = max(g.size.width - spacing * CGFloat(max(shown.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: available * segment.fraction)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func averageGlucoseString(_ meanGlucose: Double?) -> String {
        guard let mean = meanGlucose else { return "--" }
        if state.units == .mmolL {
            return Decimal(mean).asMmolL.formatted(.number.precision(.fractionLength(1))) + " " + GlucoseUnits.mmolL.rawValue
        }
        return "\(Int(mean.rounded())) " + GlucoseUnits.mgdL.rawValue
    }

    private func gmiString(_ meanGlucose: Double?) -> String {
        guard let mean = meanGlucose else { return "--" }
        let gmiPercentage = 3.31 + 0.02392 * mean
        // settingsManager is injected after first render; default until then
        if state.settingsManager?.settings.eA1cDisplayUnit == .mmolMol {
            let gmiMmolMol = (gmiPercentage - 2.152) * 10.929
            return "\(Int(gmiMmolMol.rounded())) mmol/mol"
        }
        return gmiPercentage.formatted(.number.precision(.fractionLength(1))) + " %"
    }

    @ViewBuilder func statsBanner() -> some View {
        let face = state.settingsManager?.settings.homeStatsPanelFace ?? .timeInRange
        let range = state.homeStatsPanelRange
        let stats = state.statsPanelStats
        let hasData = stats.hasData
        let averageString = averageGlucoseString(stats.meanGlucose)
        let gmiValueString = gmiString(stats.meanGlucose)
        let tirString = hasData
            ? stats.inRangePct.formatted(.number.precision(.fractionLength(0 ... 1))) + " %"
            : "-- %"
        let segments: [(color: Color, fraction: CGFloat)] = hasData ? [
            (.red, CGFloat(stats.veryLowPct / 100)),
            (.orange, CGFloat(stats.lowPct / 100)),
            (.loopGreen, CGFloat(stats.inRangePct / 100)),
            (.purple, CGFloat((stats.highPct + stats.veryHighPct) / 100))
        ] : [(Color.secondary.opacity(0.3), 1)]

        Button {
            state.showModal(for: .statistics)
        } label: {
            ZStack {
                HStack(alignment: .center, spacing: 12) {
                    switch face {
                    case .timeInRange:
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(tirString)
                                    .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                                    .foregroundStyle(.primary)
                                // chart shows 72h; make the reported scope explicit
                                (
                                    Text("Time in Range", comment: "Stats banner subtitle").fontWeight(.semibold)
                                        + Text(" ")
                                        + Text(range.scopeName)
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            }

                            statsDistributionBar(segments)
                                .frame(height: 6)
                        }
                    case .distributionBar:
                        VStack(alignment: .leading, spacing: 6) {
                            (
                                Text("Time in Range", comment: "Stats banner subtitle").fontWeight(.semibold)
                                    + Text(" ")
                                    + Text(range.scopeName)
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                            statsDistributionBar(segments)
                                .frame(height: 6)
                        }
                    case .averages:
                        VStack(alignment: .leading, spacing: 6) {
                            // "⌀" read as a diameter sign, so spell the label out (#1474)
                            (
                                Text("Avg. Glucose:", comment: "Stats banner label")
                                    + Text(" \(averageString) \u{00B7} GMI \(gmiValueString)")
                            )
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            Text(range.averageSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .hidden:
                        Text("View Statistics", comment: "Stats banner hidden face")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: HomeLayout.statsBannerHeight)
            .glassPanel()
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var multiUsePanelState: MultiUsePanelState {
        MultiUsePanelState.resolve(
            notificationsDisabled: notificationsDisabled,
            pumpTimeMismatch: state.pumpStatusBadgeImage != nil,
            lastGlucoseDate: state.glucoseFromPersistence.last?.date,
            maxIOB: state.maxIOB,
            hasUnacknowledgedReleaseNotes: releaseNotesService.hasUnacknowledgedNotes,
            dosingMode: state.dosingMode,
            now: state.timerDate,
            extendedBolus: state.visibleExtendedBolus
        )
    }

    /// Shared chrome for the non-stats panel states.
    @ViewBuilder func panelBanner(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        isCritical: Bool = false,
        tintOpacity: Double? = nil,
        strokeOpacity: Double? = nil,
        strokeWidth: CGFloat? = nil,
        accessorySystemImage: String = "chevron.right",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 12) {
                    adjustmentIcon(systemImage, tint: tint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: accessorySystemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: HomeLayout.statsBannerHeight)
            .glassPanel(
                tint: tint,
                tintOpacity: tintOpacity ?? (isCritical ? 0.30 : 0.12),
                strokeOpacity: strokeOpacity ?? (isCritical ? 0.8 : 0.35),
                strokeWidth: strokeWidth ?? (isCritical ? 1.5 : 1)
            )
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One slot, highest-priority state wins; stats is the default face.
    @ViewBuilder func multiUsePanel() -> some View {
        switch multiUsePanelState {
        case .notificationsDisabled:
            panelBanner(
                systemImage: "bell.slash.fill",
                title: String(localized: "Notifications Disabled"),
                subtitle: String(localized: "Alarms cannot alert you. Tap to fix."),
                tint: .red,
                isCritical: true
            ) {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
        case .pumpTimeMismatch:
            panelBanner(
                systemImage: "clock.badge.exclamationmark.fill",
                title: String(localized: "Time Change Detected"),
                subtitle: String(localized: "Pump clock differs from phone. Tap to review."),
                tint: .orange
            ) {
                if state.pumpDisplayState != nil {
                    state.shouldDisplayPumpSetupSheet.toggle()
                }
            }
        case .cgmStale:
            panelBanner(
                systemImage: "drop.fill",
                title: String(localized: "No Recent Glucose"),
                subtitle: String(localized: "Tap to add a fingerstick reading."),
                tint: .orange
            ) {
                showManualGlucose = true
            }
        case .maxIOBZero:
            panelBanner(
                systemImage: "exclamationmark.triangle.fill",
                title: String(localized: "Max IOB is 0 U"),
                subtitle: String(localized: "Automated dosing is limited. Tap to review."),
                tint: .orange
            ) {
                openMaxIOBSetting()
            }
        case .whatsNew:
            panelBanner(
                systemImage: "sparkles",
                title: String(
                    localized: "New Release v\(releaseNotesService.notes?.version ?? "")",
                    comment: "Home panel title offering the release notes; the placeholder is a version number"
                ),
                subtitle: String(localized: "See what's new in this version."),
                tint: .insulin,
                tintOpacity: 0.24,
                strokeOpacity: 0.7,
                strokeWidth: 1.5
            ) {
                showReleaseNotes = true
            }
        case let .extendedBolus(bolus):
            extendedBolusBanner(bolus)
        case let .dosingModeLimited(mode):
            panelBanner(
                systemImage: mode.icon,
                title: mode.displayName,
                subtitle: mode.miniHint,
                tint: .orange
            ) {
                openDosingModeSetting()
            }
        case .stats:
            statsBanner()
        }
    }

    @ViewBuilder func extendedBolusBanner(_ bolus: ExtendedBolus) -> some View {
        let delivered = insulinText(bolus.deliveredUnits)
        let total = insulinText(bolus.totalUnits)
        if bolus.isActive {
            let minutesLeft = max(0, Int(bolus.endDate.timeIntervalSince(state.timerDate) / 60))
            let minutesToStart = Int((bolus.extendedStartDate.timeIntervalSince(state.timerDate) / 60).rounded(.up))
            panelBanner(
                systemImage: "timer",
                title: String(localized: "Extended Bolus", comment: "Home panel title for a running extended bolus"),
                subtitle: bolus.isWaitingForStart(at: state.timerDate) ?
                    String(
                        localized: "\(total) starts in \(formatHrMin(max(1, minutesToStart))) · tap to stop",
                        comment: "Home panel subtitle while an extended bolus waits for its delayed start: total, time until start"
                    ) :
                    String(
                        localized: "\(delivered) of \(total) · \(formatHrMin(minutesLeft)) left · tap to stop",
                        comment: "Home panel subtitle for a running extended bolus: delivered, total, time left"
                    ),
                tint: .insulin
            ) {
                showCancelExtendedBolusDialog = true
            }
            .confirmationDialog(
                String(localized: "Stop Extended Bolus?"),
                isPresented: $showCancelExtendedBolusDialog,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Stop Extended Bolus"), role: .destructive) {
                    state.cancelExtendedBolus()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("\(delivered) of \(total) have been delivered. The rest will not be given.")
            }
        } else {
            panelBanner(
                systemImage: "exclamationmark.triangle.fill",
                title: String(localized: "Extended Bolus Stopped", comment: "Home panel title"),
                subtitle: (
                    bolus.endReason == .lowGlucose
                        ? String(localized: "Low glucose · \(delivered) of \(total) delivered")
                        : String(localized: "Not completed in time · \(delivered) of \(total) delivered")
                ) + " · " + String(localized: "tap to dismiss", comment: "Home panel: hides the notice"),
                tint: .orange,
                accessorySystemImage: "xmark"
            ) {
                state.dismissStoppedExtendedBolus()
            }
            .accessibilityHint(Text(String(localized: "Hides this notice", comment: "Accessibility hint")))
        }
    }

    private func insulinText(_ units: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: units as NSNumber) ?? "0") + String(localized: " U", comment: "Insulin unit")
    }

    /// The mode picker sits on the Settings root, so there is no sub-screen target to push.
    func openDosingModeSetting() {
        selectedTab = 3
    }

    func openMaxIOBSetting() {
        // same target search results push, so scroll + highlight wiggle match
        selectedTab = 3
        settingsPath.append(SearchResultTarget(
            screen: .unitsAndLimits,
            scrollLabel: "Maximum Insulin on Board (IOB)".localized
        ))
    }

    // MARK: - Rescue carbs

    /// Temp target of the rescue carbs setting in the user's glucose unit.
    private var rescueTempTargetText: String {
        let mgdL = Decimal(RescueCarbSettings.tempTarget)
        if state.units == .mmolL {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return (formatter.string(from: mgdL.asMmolL as NSNumber) ?? "") + " " + GlucoseUnits.mmolL.rawValue
        }
        return "\(RescueCarbSettings.tempTarget) " + GlucoseUnits.mgdL.rawValue
    }

    private var rescueCarbsDialogMessage: String {
        var lines = [String(
            localized: "Logs \(RescueCarbSettings.grams) g rescue carbs. They are not counted as carbs on board, so Trio does not give insulin for them.",
            comment: "Rescue carbs confirmation"
        )]
        if RescueCarbSettings.tempTargetEnabled {
            lines.append(String(
                localized: "Starts a temp target of \(rescueTempTargetText) for \(RescueCarbSettings.duration) min.",
                comment: "Rescue carbs confirmation"
            ))
        }
        if let recent = rescueCarbsRecent {
            let minutes = max(0, Int(Date().timeIntervalSince(recent.date) / 60))
            lines.append(String(
                localized: "Rescue carbs were already logged \(minutes) min ago (\(recent.grams) g).",
                comment: "Rescue carbs confirmation"
            ))
        }
        return lines.joined(separator: "\n\n")
    }

    private func rescueCarbsResultText(_ result: RescueCarbsResult) -> String {
        var text = String(localized: "\(result.grams) g rescue carbs logged.", comment: "Rescue carbs result")
        switch result.tempTarget {
        case let .started(_, minutes):
            text += " " + String(
                localized: "Temp target \(rescueTempTargetText) for \(minutes) min started.",
                comment: "Rescue carbs result"
            )
        case .keptActive:
            text += " " + String(
                localized: "The active temp target is at least as high and keeps running.",
                comment: "Rescue carbs result"
            )
        case .disabled:
            break
        case let .failed(message):
            text += " " + String(
                localized: "The temp target could not be started: \(message)",
                comment: "Rescue carbs result"
            )
        }
        return text
    }

    @ViewBuilder var rescueCarbsButton: some View {
        Button {
            rescueCarbsRecent = state.rescueCarbsManager?.recentEntry()
            showRescueCarbsDialog = true
        } label: {
            VStack(spacing: 2) {
                // ear of wheat: ties the button to carbs
                Image("wheatEar")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("\(RescueCarbSettings.grams) g")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.red)
            .frame(width: 54, height: HomeLayout.bottomPanelHeight)
            .glassPanel(tint: .red, tintOpacity: 0.12, strokeOpacity: 0.30)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .accessibilityLabel(Text("Rescue Carbs"))
        .confirmationDialog(
            Text("Rescue Carbs"),
            isPresented: $showRescueCarbsDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Log \(RescueCarbSettings.grams) g Rescue Carbs", comment: "Rescue carbs button")) {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()
                Task {
                    guard let manager = state.rescueCarbsManager else { return }
                    let result = await manager.logRescueCarbs()
                    await MainActor.run { rescueCarbsMessage = rescueCarbsResultText(result) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rescueCarbsDialogMessage)
        }
        .alert(
            Text("Rescue Carbs"),
            isPresented: Binding(
                get: { rescueCarbsMessage != nil },
                set: { if !$0 { rescueCarbsMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rescueCarbsMessage ?? "")
        }
    }

    /// Bottom-anchored fixed zone: adjustment/bolus panel above the stats banner.
    @ViewBuilder func bottomControls() -> some View {
        VStack(spacing: HomeLayout.bottomZonePadding) {
            HStack(spacing: 0) {
                Group {
                    if let progress = state.bolusProgress {
                        bolusView(progress)
                    } else {
                        adjustmentView()
                    }
                }
                .frame(height: HomeLayout.bottomPanelHeight)
                .animation(.easeInOut(duration: 0.2), value: state.bolusProgress != nil)

                rescueCarbsButton
            }

            multiUsePanel()
                .frame(height: HomeLayout.statsBannerHeight)
        }
        .padding(.vertical, HomeLayout.bottomZonePadding)
    }
}
