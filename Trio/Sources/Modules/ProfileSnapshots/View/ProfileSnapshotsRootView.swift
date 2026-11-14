import SwiftUI
import Swinject

extension ProfileSnapshots {
    /// Saved profiles (basal rates, ISF, carb ratios): save the one in use before trying changes,
    /// compare, and restore one if the changes did not work out.
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var showSaveAlert = false
        @State private var newName = ""

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                currentSection
                savedSection
                notesSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .onAppear { state.refresh() }
            .refreshable { state.refresh() }
            .alert(String(localized: "Save Profile", comment: "Profile snapshot alert title"), isPresented: $showSaveAlert) {
                TextField(String(localized: "Name", comment: "Profile snapshot name field"), text: $newName)
                Button(String(localized: "Save")) { state.saveCurrent(name: newName) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("Saves the basal rates, ISF and carb ratios in use.")
            }
            .alert(
                state.message?.title ?? "",
                isPresented: Binding(
                    get: { state.message != nil },
                    set: { if !$0 { state.message = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.message?.text ?? "")
            }
            .navigationTitle("Saved Profiles")
            .navigationBarTitleDisplayMode(.automatic)
        }

        // MARK: - Sections

        private var currentSection: some View {
            Section {
                if let current = state.current {
                    ProfileSummary(snapshot: current, units: state.units)
                    if let saved = state.savedCurrent {
                        Label(
                            String(localized: "Saved as \"\(saved.name)\"", comment: "Profile snapshot: current is saved"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.green)
                    }
                    Button {
                        newName = ""
                        showSaveAlert = true
                    } label: {
                        Label("Save Current Profile", systemImage: "square.and.arrow.down")
                    }
                } else {
                    Text("Set basal rates, ISF and carb ratios first.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Profile in Use")
            }
            .listRowBackground(Color.chart)
        }

        private var savedSection: some View {
            Section {
                if state.snapshots.isEmpty {
                    Text("No saved profiles yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.snapshots) { snapshot in
                        NavigationLink {
                            DetailView(state: state, snapshotID: snapshot.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(snapshot.name).fontWeight(.semibold)
                                    if snapshot.origin == .beforeRestore {
                                        Text("auto")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                    }
                                    if let current = state.current, snapshot.hasSameValues(as: current) {
                                        Text("in use")
                                            .font(.caption2).fontWeight(.semibold)
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 5)
                                            .background(Capsule().fill(Color.green.opacity(0.15)))
                                    }
                                }
                                Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ProfileSummary(snapshot: snapshot, units: state.units, compact: true)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            state.delete(state.snapshots[index])
                        }
                    }
                }
            } header: {
                Text("Saved Profiles")
            }
            .listRowBackground(Color.chart)
        }

        private var notesSection: some View {
            Section {
                Text(
                    "Restoring sends the basal rates to the pump first and only then takes over ISF and carb ratios. Before that, the profile in use is saved as \"Before Restore\" and a settings backup is made. Glucose targets and all other settings stay as they are."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// Daily basal, ISF and carb ratio ranges in one or three lines.
    struct ProfileSummary: View {
        let snapshot: ProfileSnapshot
        let units: GlucoseUnits
        var compact = false

        var body: some View {
            let parts = [
                String(localized: "Basal \(Formatting.units(snapshot.dailyBasal)) U/day", comment: "Profile summary"),
                String(localized: "ISF \(Formatting.isfRange(snapshot.isfRange, units: units))", comment: "Profile summary"),
                String(localized: "CR \(Formatting.ratioRange(snapshot.carbRatioRange)) g/U", comment: "Profile summary")
            ]
            if compact {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(parts, id: \.self) { Text($0) }
                }
                .font(.subheadline)
                .monospacedDigit()
            }
        }
    }

    enum Formatting {
        static func number(_ value: Decimal, digits: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            return formatter.string(from: value as NSNumber) ?? "\(value)"
        }

        static func units(_ value: Decimal) -> String { number(value, digits: 2) }

        static func isf(_ mgdl: Decimal, units: GlucoseUnits) -> String {
            units == .mmolL ? number(mgdl.asMmolL, digits: 1) : number(mgdl, digits: 0)
        }

        static func isfRange(_ range: ClosedRange<Decimal>?, units: GlucoseUnits) -> String {
            guard let range else { return "–" }
            let unit = units == .mmolL ? "mmol/L/U" : "mg/dL/U"
            if range.lowerBound == range.upperBound { return "\(isf(range.lowerBound, units: units)) \(unit)" }
            return "\(isf(range.lowerBound, units: units))–\(isf(range.upperBound, units: units)) \(unit)"
        }

        static func ratioRange(_ range: ClosedRange<Decimal>?) -> String {
            guard let range else { return "–" }
            if range.lowerBound == range.upperBound { return number(range.lowerBound, digits: 1) }
            return "\(number(range.lowerBound, digits: 1))–\(number(range.upperBound, digits: 1))"
        }
    }

    /// One line of a schedule: start time and formatted value.
    struct ScheduleRow: Identifiable, Equatable {
        var id: String { start }
        let start: String
        let value: String

        /// "06:30:00" → "06:30"
        init(_ start: String, _ value: String) {
            self.start = String(start.prefix(5))
            self.value = value
        }
    }

    /// One saved profile with its values, compared with the profile in use, and restore.
    struct DetailView: View {
        @ObservedObject var state: StateModel
        let snapshotID: UUID

        @State private var confirmRestore = false
        @State private var showRename = false
        @State private var newName = ""
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var snapshot: ProfileSnapshot? { state.snapshots.first { $0.id == snapshotID } }

        var body: some View {
            List {
                if let snapshot {
                    let differences = state.current.map { snapshot.differences(from: $0) }
                    Section {
                        ProfileSummary(snapshot: snapshot, units: state.units)
                        if let differences {
                            if differences.any {
                                Text(differenceText(differences))
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Same as the profile in use", systemImage: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            }
                        }
                    } header: {
                        Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    .listRowBackground(Color.chart)

                    scheduleSection(
                        title: String(localized: "Basal Rates"),
                        rows: snapshot.basalProfile.sorted { $0.minutes < $1.minutes }
                            .map { ScheduleRow($0.start, Formatting.units($0.rate) + " U/h") },
                        currentRows: state.current?.basalProfile.sorted { $0.minutes < $1.minutes }
                            .map { ScheduleRow($0.start, Formatting.units($0.rate) + " U/h") },
                        changed: differences?.basal ?? false
                    )
                    scheduleSection(
                        title: String(localized: "Insulin Sensitivities"),
                        rows: snapshot.insulinSensitivities.sensitivities.sorted { $0.offset < $1.offset }
                            .map { ScheduleRow($0.start, Formatting.isf($0.sensitivity, units: state.units)) },
                        currentRows: state.current?.insulinSensitivities.sensitivities.sorted { $0.offset < $1.offset }
                            .map { ScheduleRow($0.start, Formatting.isf($0.sensitivity, units: state.units)) },
                        changed: differences?.isf ?? false
                    )
                    scheduleSection(
                        title: String(localized: "Carb Ratios"),
                        rows: snapshot.carbRatios.schedule.sorted { $0.offset < $1.offset }
                            .map { ScheduleRow($0.start, Formatting.number($0.ratio, digits: 1) + " g/U") },
                        currentRows: state.current?.carbRatios.schedule.sorted { $0.offset < $1.offset }
                            .map { ScheduleRow($0.start, Formatting.number($0.ratio, digits: 1) + " g/U") },
                        changed: differences?.carbRatio ?? false
                    )

                    Section {
                        Button {
                            confirmRestore = true
                        } label: {
                            HStack {
                                Label("Restore This Profile", systemImage: "arrow.uturn.backward.circle")
                                if state.isWorking {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(state.isWorking || differences?.any == false)
                        Button {
                            newName = snapshot.name
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            state.delete(snapshot)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.chart)
                    .confirmationDialog(
                        String(localized: "Restore \"\(snapshot.name)\"?", comment: "Profile snapshot restore title"),
                        isPresented: $confirmRestore,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Restore Profile", comment: "Profile snapshot restore button")) {
                            state.restore(snapshot)
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    } message: {
                        Text(
                            "The basal rates are sent to the pump, ISF and carb ratios are replaced. The profile in use is saved as \"Before Restore\" first."
                        )
                    }
                    .alert(String(localized: "Rename", comment: "Profile snapshot rename"), isPresented: $showRename) {
                        TextField(String(localized: "Name", comment: "Profile snapshot name field"), text: $newName)
                        Button(String(localized: "Save")) { state.rename(snapshot, to: newName) }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    }
                } else {
                    Text("This profile no longer exists.").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(snapshot?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }

        private func differenceText(_ differences: ProfileSnapshot.Differences) -> String {
            var parts: [String] = []
            if differences.basal { parts.append(String(localized: "Basal Rates")) }
            if differences.isf { parts.append(String(localized: "Insulin Sensitivities")) }
            if differences.carbRatio { parts.append(String(localized: "Carb Ratios")) }
            return String(
                localized: "Differs from the profile in use: \(parts.joined(separator: ", "))",
                comment: "Profile snapshot comparison"
            )
        }

        /// Saved values; when they differ, the values in use are shown next to them.
        private func scheduleSection(
            title: String,
            rows: [ScheduleRow],
            currentRows: [ScheduleRow]?,
            changed: Bool
        ) -> some View {
            let current = Dictionary((currentRows ?? []).map { ($0.start, $0.value) }, uniquingKeysWith: { first, _ in first })
            return Section {
                ForEach(rows) { row in
                    let start = row.start
                    let value = row.value
                    HStack {
                        Text(start).monospacedDigit()
                        Spacer()
                        if changed, let now = current[start], now != value {
                            Text(String(localized: "now \(now)", comment: "Profile snapshot: value in use"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if changed, current[start] == nil {
                            Text(String(localized: "not in use", comment: "Profile snapshot: time not in the profile in use"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(value).monospacedDigit().fontWeight(.semibold)
                    }
                }
            } header: {
                HStack {
                    Text(title)
                    if changed {
                        Spacer()
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}
