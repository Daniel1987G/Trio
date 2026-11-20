import SwiftUI

/// Profile (basal, ISF, carb ratio) and autoISF weight suggestions from the user's own data,
/// calculated on the phone. Each can be taken over after a confirmation.
struct TuningSuggestionsView: View {
    @ObservedObject var state: AIReport.StateModel

    @State private var confirmProfile = false
    @State private var confirmWeight = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            if let tuning = state.tuning {
                introSection(tuning)
                basalSection(tuning)
                isfSection(tuning)
                carbRatioSection(tuning)
                profileActionSection
                if let weights = tuning.autoISF {
                    autoISFSection(tuning, weights)
                }
                notesSection
            } else {
                HStack {
                    ProgressView()
                    Text("Calculating…").foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Settings Suggestions")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            state.tuningMessage?.title ?? "",
            isPresented: Binding(get: { state.tuningMessage != nil }, set: { if !$0 { state.tuningMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.tuningMessage?.text ?? "")
        }
    }

    // MARK: - Summary for the overview

    static func summary(_ tuning: TuningAnalysis.Report) -> String {
        let profileCount = tuning.basal.filter { $0.suggestion.factor != nil }.count +
            (tuning.isf.factor != nil ? 1 : 0) +
            tuning.carbRatio.filter { $0.suggestion.factor != nil }.count
        var parts: [String] = [
            profileCount == 0 ?
                String(localized: "Profile: no change suggested", comment: "Tuning summary") :
                String(localized: "Profile: \(profileCount) suggestions", comment: "Tuning summary")
        ]
        if let weights = tuning.autoISF {
            parts.append(
                weights.weight == nil ?
                    String(localized: "autoISF: no change", comment: "Tuning summary") :
                    String(localized: "autoISF: next step", comment: "Tuning summary")
            )
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    private func introSection(_ tuning: TuningAnalysis.Report) -> some View {
        Section {
            Text(
                String(
                    localized: "From the last \(tuning.periodDays) days of glucose, insulin and carbs. A time block needs data on at least \(TuningAnalysis.minimumDays(for: tuning.periodDays)) days.",
                    comment: "Tuning intro"
                )
            )
            .font(.callout)
        } footer: {
            Text(
                "Like autotune: what glucose did beyond the effect of the insulin shows where the profile is off. Suggestions go half way to the measured value and at most 20 % per step."
            )
        }
        .listRowBackground(Color.chart)
    }

    private func basalSection(_ tuning: TuningAnalysis.Report) -> some View {
        Section(header: Text("Basal Rates"), footer: Text("From times without carbs and meal boluses.")) {
            ForEach(tuning.basal) { block in
                blockRow(
                    title: Self.timeRange(block.startHour, block.endHour),
                    suggestion: block.suggestion,
                    moreInsulinWhenUp: true
                )
            }
        }
        .listRowBackground(Color.chart)
    }

    private func isfSection(_ tuning: TuningAnalysis.Report) -> some View {
        Section(
            header: Text("Insulin Sensitivity (ISF)"),
            footer: Text(
                "From times without carbs in which extra insulin brought high glucose down. One factor for the whole day."
            )
        ) {
            blockRow(
                title: String(localized: "All Day", comment: "Tuning ISF row"),
                suggestion: tuning.isf,
                moreInsulinWhenUp: false
            )
        }
        .listRowBackground(Color.chart)
    }

    private func carbRatioSection(_ tuning: TuningAnalysis.Report) -> some View {
        Section(
            header: Text("Carb Ratios"),
            footer: Text(
                "From meals of at least 20 g without further carbs in the 4 hours after: carbs divided by the insulin the meal needed."
            )
        ) {
            ForEach(tuning.carbRatio) { block in
                blockRow(
                    title: Self.mealTime(block.startHour),
                    suggestion: block.suggestion,
                    moreInsulinWhenUp: false
                )
            }
        }
        .listRowBackground(Color.chart)
    }

    private func blockRow(title: String, suggestion: TuningAnalysis.Suggestion, moreInsulinWhenUp: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).monospacedDigit()
                Text(String(localized: "\(suggestion.days) days", comment: "Tuning: days with data"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch suggestion.confidence {
            case .tooLittleData:
                Text("too little data").font(.caption).foregroundStyle(.secondary)
            case .sufficient:
                if let factor = suggestion.factor {
                    let up = factor > 1
                    let more = up == moreInsulinWhenUp
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Self.percent(factor)).fontWeight(.semibold).monospacedDigit()
                        Text(more ? String(localized: "more insulin") : String(localized: "less insulin"))
                            .font(.caption2)
                    }
                    .foregroundStyle(more ? Color.orange : Color.teal)
                } else {
                    Text("fits").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder private var profileActionSection: some View {
        if let proposed = state.proposedProfile, let current = state.currentProfile {
            Section {
                ForEach(changes(current: current, proposed: proposed), id: \.self) { line in
                    Text(line).font(.footnote).monospacedDigit()
                }
                Button {
                    confirmProfile = true
                } label: {
                    HStack {
                        Label("Use Suggested Profile", systemImage: "checkmark.circle")
                        if state.isApplying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(state.isApplying)
            } header: {
                Text("Suggested Profile")
            } footer: {
                Text(
                    "Your profile in use is saved first and can be restored under Therapy → Saved Profiles. The basal rates are sent to the pump."
                )
            }
            .listRowBackground(Color.chart)
            .confirmationDialog(
                String(localized: "Use the suggested profile?", comment: "Tuning confirmation"),
                isPresented: $confirmProfile,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Use Suggested Profile")) { state.applyProfileSuggestion() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("Change one thing at a time if you can, and watch the effect for a few days.")
            }
        }
    }

    private func autoISFSection(_ tuning: TuningAnalysis.Report, _ weights: TuningAnalysis.WeightSuggestion) -> some View {
        Section(
            header: Text("autoISF Weights"),
            footer: Text(
                "In the order of the FCL e-book: first acceleration, then post-meal, brake and duration. One step of 15–20 % at a time; give each step a few days."
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "\(tuning.meals.count) meals, \(tuning.meals.unannounced) without carb entry",
                    comment: "Tuning meals"
                ))
                Text(String(
                    localized: "High peaks: \(tuning.meals.highPeaks) · late lows: \(tuning.meals.lateLows) · long highs: \(tuning.meals.plateaus)",
                    comment: "Tuning meals"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(Self.verdictText(weights.verdict))
                .font(.callout)
                .foregroundStyle(weights.verdict == .tooStrong ? Color.orange : Color.primary)
            if let weight = weights.weight, let current = weights.current, let proposed = weights.proposed {
                HStack {
                    Text(Self.weightName(weight))
                    Spacer()
                    Text(Self.decimal(current)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(Self.decimal(proposed)).fontWeight(.semibold)
                }
                .monospacedDigit()
                Button {
                    confirmWeight = true
                } label: {
                    Label("Use This Weight", systemImage: "checkmark.circle")
                }
                .confirmationDialog(
                    String(localized: "Change \(Self.weightName(weight))?", comment: "Tuning confirmation"),
                    isPresented: $confirmWeight,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Use This Weight")) { state.applyWeight(weights) }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text("\(Self.decimal(current)) → \(Self.decimal(proposed))")
                }
            }
        }
        .listRowBackground(Color.chart)
    }

    private var notesSection: some View {
        Section {
            Text(
                "Suggestions only, calculated from your data with fixed rules (no AI). Overrides and temporary targets are left out. Sport, illness or unusual days can mislead them: check before you use them and talk to your diabetes team."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Texts

    private func changes(current: ProfileSnapshot, proposed: ProfileSnapshot) -> [String] {
        var lines: [String] = []
        let basalNow = current.basalProfile.sorted { $0.minutes < $1.minutes }
        for entry in proposed.basalProfile.sorted(by: { $0.minutes < $1.minutes }) {
            let now = basalNow.last { $0.minutes <= entry.minutes }?.rate ?? entry.rate
            if now != entry.rate {
                lines.append("Basal \(entry.start.prefix(5)): \(Self.decimal(now)) → \(Self.decimal(entry.rate)) U/h")
            }
        }
        let isfNow = current.insulinSensitivities.sensitivities.sorted { $0.offset < $1.offset }
        for entry in proposed.insulinSensitivities.sensitivities.sorted(by: { $0.offset < $1.offset }) {
            let now = isfNow.last { $0.offset <= entry.offset }?.sensitivity ?? entry.sensitivity
            if now != entry.sensitivity {
                lines.append("ISF \(entry.start.prefix(5)): \(Self.decimal(now)) → \(Self.decimal(entry.sensitivity))")
            }
        }
        let ratioNow = current.carbRatios.schedule.sorted { $0.offset < $1.offset }
        for entry in proposed.carbRatios.schedule.sorted(by: { $0.offset < $1.offset }) {
            let now = ratioNow.last { $0.offset <= entry.offset }?.ratio ?? entry.ratio
            if now != entry.ratio {
                lines.append(
                    String(localized: "CR", comment: "Carb ratio short") +
                        " \(entry.start.prefix(5)): \(Self.decimal(now)) → \(Self.decimal(entry.ratio)) g/U"
                )
            }
        }
        return lines
    }

    static func verdictText(_ verdict: TuningAnalysis.WeightSuggestion.Verdict) -> String {
        switch verdict {
        case .tooStrong:
            return String(localized: "Several meals end in a low: autoISF acts too strongly.", comment: "Tuning verdict")
        case .tooWeak:
            return String(
                localized: "Meals peak high without later lows: autoISF can act more strongly.",
                comment: "Tuning verdict"
            )
        case .plateau:
            return String(localized: "Glucose often stays high for long after meals.", comment: "Tuning verdict")
        case .fine:
            return String(localized: "Meals look fine: no change needed.", comment: "Tuning verdict")
        case .tooFewMeals:
            return String(localized: "Too few meals to judge yet.", comment: "Tuning verdict")
        case .cappedByMax:
            return String(
                localized: "autoISF often reaches autoISF Max: a higher weight would not add more. Check autoISF Max first.",
                comment: "Tuning verdict"
            )
        }
    }

    static func weightName(_ weight: TuningAnalysis.Weight) -> String {
        switch weight {
        case .bgAccel: return String(localized: "Acceleration Weight")
        case .bgBrake: return String(localized: "Brake Weight")
        case .pp: return String(localized: "Post-Meal Weight")
        case .dura: return String(localized: "Duration Weight")
        }
    }

    static func timeRange(_ start: Int, _ end: Int) -> String {
        String(format: "%02d–%02d", start, end % 24) + " " +
            String(localized: "o'clock", comment: "Sensitivity report time block suffix")
    }

    static func mealTime(_ startHour: Int) -> String {
        switch startHour {
        case 5: return String(localized: "Morning (5–11)", comment: "Tuning meal time")
        case 11: return String(localized: "Midday (11–16)", comment: "Tuning meal time")
        default: return String(localized: "Evening (16–5)", comment: "Tuning meal time")
        }
    }

    static func percent(_ factor: Decimal) -> String {
        let change = NSDecimalNumber(decimal: (factor - 1) * 100).intValue
        return (change > 0 ? "+" : "") + "\(change) %"
    }

    static func decimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }
}
