import SwiftUI
import Swinject

extension AIReport {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                periodSection
                metricsSection
                sensitivitySection
                topicsSection
                reportSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .onAppear { state.refreshProvider() }
            .navigationTitle("AI Therapy Report")
            .navigationBarTitleDisplayMode(.automatic)
            .sheet(isPresented: Binding(get: { state.sharePDFURL != nil }, set: { if !$0 { state.sharePDFURL = nil } })) {
                if let url = state.sharePDFURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .alert(
                String(localized: "AI Therapy Report", comment: "AI report error title"),
                isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(state.errorMessage ?? "")
            }
        }

        // MARK: - Sections

        private var periodSection: some View {
            Section(
                footer: Text(
                    "The figures below are calculated on this iPhone. Only for the AI evaluation is a summary sent to the AI provider you set up for the meal photo analysis."
                )
            ) {
                Picker("Period", selection: Binding(get: { state.days }, set: { state.setDays($0) })) {
                    ForEach(AIReport.Config.dayOptions, id: \.self) { days in
                        Text(String(localized: "\(days) days", comment: "AI report period")).tag(days)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private var metricsSection: some View {
            Section(header: Text("Key Figures")) {
                if let report = state.report {
                    metricRow(
                        "Time in Range 70–180",
                        "\(percent(report.glucose.inRangePercent)) · " +
                            String(localized: "tight \(percent(report.glucose.tightRangePercent))", comment: "70-140 range")
                    )
                    metricRow(
                        "Below 70 / Below 54",
                        "\(percent(report.glucose.lowPercent + report.glucose.veryLowPercent)) / \(percent(report.glucose.veryLowPercent))"
                    )
                    metricRow(
                        "Above 180 / Above 250",
                        "\(percent(report.glucose.highPercent + report.glucose.veryHighPercent)) / \(percent(report.glucose.veryHighPercent))"
                    )
                    metricRow(
                        "Hypoglycemia",
                        String(
                            localized: "\(report.hypoCount) episodes, \(report.severeHypoCount) below 54",
                            comment: "AI report hypo count"
                        )
                    )
                    metricRow(
                        "Mean · GMI · CV",
                        "\(number(report.glucose.meanMgdl)) mg/dL · \(number(report.glucose.gmiPercent)) % · \(number(report.glucose.cvPercent)) %"
                    )
                    metricRow(
                        "Loop",
                        String(
                            localized: "\(percent(report.loop.successPercent)) successful · \(number(report.loop.runsPerDay)) runs/day",
                            comment: "AI report loop figures"
                        )
                    )
                    metricRow(
                        "Total Daily Dose",
                        String(
                            localized: "\(number(report.insulin.tddMean)) U · basal \(percent(report.insulin.basalPercent)) · SMB \(number(report.insulin.smbPerDay)) U/day",
                            comment: "AI report insulin figures"
                        )
                    )
                    metricRow("CGM Coverage", percent(report.glucose.coveragePercent))
                } else {
                    HStack {
                        ProgressView()
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private var sensitivitySection: some View {
            Section(
                header: Text("Sensitivity"),
                footer: Text(
                    "By which factor the profile could change per time of day, from the sensitivity the loop calculated. Calculated on this iPhone, a suggestion only."
                )
            ) {
                if let report = state.report, let sensitivity = report.sensitivityByTime {
                    NavigationLink {
                        SensitivityReportView(
                            report: sensitivity,
                            displayUnits: report.settings?.displayUnits ?? GlucoseUnits.mgdL.rawValue
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .frame(width: 24)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sensitivity by Time of Day")
                                Text(
                                    sensitivity.suggestions.isEmpty ?
                                        String(localized: "No profile change suggested", comment: "Sensitivity report") :
                                        String(
                                            localized: "Suggestion for \(sensitivity.suggestions.count) time blocks",
                                            comment: "Sensitivity report"
                                        )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private var topicsSection: some View {
            Section(
                header: Text("AI Evaluations"),
                footer: Text(
                    "Each topic is evaluated on its own and sends only the data it needs. The AI makes suggestions and never changes anything itself."
                )
            ) {
                ForEach(TherapyReportTopic.allCases) { topic in
                    NavigationLink {
                        AIReportTopicView(state: state, topic: topic)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: topic.systemImage)
                                .frame(width: 24)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title)
                                Text(topicStatus(topic))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.analyzing.contains(topic) {
                                ProgressView()
                            }
                        }
                    }
                }
                if !state.isConfigured {
                    Text("No AI provider is set up yet.")
                        .foregroundStyle(.secondary)
                }
                Text("AI Provider and API Key").navigationLink(to: .mealPhotoSettings, from: self)
            }
            .listRowBackground(Color.chart)
        }

        private var reportSection: some View {
            Section(
                header: Text("Overall Report"),
                footer: Text(
                    "Key figures, tables by time of day, the list of hypoglycemia and every AI evaluation made so far, as an A4 PDF, e.g. for your diabetes team."
                )
            ) {
                Button {
                    state.printReport()
                } label: {
                    Label("Print Report", systemImage: "printer")
                }
                .disabled(state.report == nil)
                Button {
                    state.prepareShare()
                } label: {
                    Label("Share Report as PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(state.report == nil)
            }
            .listRowBackground(Color.chart)
        }

        private func topicStatus(_ topic: TherapyReportTopic) -> String {
            if state.analyzing.contains(topic) {
                return String(localized: "Waiting for \(state.providerName)…", comment: "AI report progress")
            }
            guard let saved = state.saved[topic] else { return topic.subtitle }
            return String(
                localized: "Last: \(saved.date.formatted(date: .abbreviated, time: .shortened)) · \(saved.days) days",
                comment: "AI report topic status"
            )
        }

        // MARK: - Helpers

        private func metricRow(_ title: LocalizedStringKey, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }

        private func number(_ value: Decimal) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter.string(from: value as NSNumber) ?? "\(value)"
        }

        private func percent(_ value: Decimal) -> String {
            "\(number(value)) %"
        }
    }
}

/// One AI evaluation topic: start it, see what is sent, read the answer.
struct AIReportTopicView: View {
    @ObservedObject var state: AIReport.StateModel
    let topic: TherapyReportTopic

    @State private var showSendConfirmation = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                footer: Text(topic.subtitle)
            ) {
                if state.analyzing.contains(topic) {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Waiting for \(state.providerName)…", comment: "AI report progress"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Cancel")) { state.cancelAnalysis(topic) }
                            .buttonStyle(.borderless)
                    }
                } else if state.isConfigured {
                    Button {
                        showSendConfirmation = true
                    } label: {
                        Label(
                            state.saved[topic] == nil ? String(localized: "Start AI Evaluation") :
                                String(localized: "New AI Evaluation"),
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(state.report == nil)
                } else {
                    Text("No AI provider is set up yet.")
                        .foregroundStyle(.secondary)
                }

                if let report = state.report {
                    DisclosureGroup("Data Sent") {
                        Text(report.summaryJSON(for: topic))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Color.chart)

            if let saved = state.saved[topic] {
                Section(
                    header: Text(
                        String(
                            localized: "\(saved.date.formatted(date: .abbreviated, time: .shortened)) · \(saved.days) days · \(saved.provider)",
                            comment: "AI report result header: date, period, provider"
                        )
                    ),
                    footer: Text(
                        "AI evaluations can be wrong. Discuss changes with your diabetes team and change only one setting at a time."
                    )
                ) {
                    AIReportMarkdownView(text: saved.text)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "Send Summary?", comment: "AI report confirmation title"),
            isPresented: $showSendConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Send to \(state.providerName)", comment: "AI report confirmation button")) {
                state.analyze(topic)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                "The summary shown under \"Data Sent\" goes to \(state.providerName). It contains no name and no dates, only statistics, time of day and your settings. The request is billed to your API key."
            )
        }
    }
}

/// Renders the Markdown of the AI answer: headings, bullet and numbered lists, inline emphasis.
struct AIReportMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, rawLine in
                line(rawLine.trimmingCharacters(in: .whitespaces))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ line: String) -> some View {
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            inline(title)
                .font(line.hasPrefix("###") ? .subheadline.weight(.semibold) : .headline)
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(line.dropFirst(2)))
            }
            .font(.subheadline)
        } else if let number = line.split(separator: ".", maxSplits: 1).first, Int(number) != nil, line.contains(". ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(String(number)).").monospacedDigit()
                inline(String(line.dropFirst(number.count + 1)).trimmingCharacters(in: .whitespaces))
            }
            .font(.subheadline)
        } else if line.hasPrefix("---") {
            Divider()
        } else {
            inline(line).font(.subheadline)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
