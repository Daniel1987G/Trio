import SwiftUI

/// Sensitivity by time of day with suggested profile factors (computed on the phone, no AI).
struct SensitivityReportView: View {
    let report: SensitivityReport
    /// "mg/dL" or "mmol/L", for the ISF values.
    let displayUnits: String

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var isMmol: Bool { displayUnits == GlucoseUnits.mmolL.rawValue }

    var body: some View {
        List {
            Section {
                summary
            } footer: {
                Text(
                    "For every 3-hour block the factor is the median of the sensitivity ratio the loop calculated (autosens or dynamic ISF). A block is only suggested when it deviates by at least 8 % on most of its values and on at least half of the days. Above 1 means resistant, below 1 sensitive."
                )
            }
            .listRowBackground(Color.chart)

            Section(header: Text("By Time of Day")) {
                ForEach(report.blocks) { block in
                    blockRow(block)
                }
            }
            .listRowBackground(Color.chart)

            Section {
                ShareLink(item: shareText) {
                    Label("Share Sensitivity Report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if report.isDynamicISF {
                        Text(
                            "Dynamic ISF is on: its ratio also follows glucose level and total daily dose, so the factors are a hint rather than a measurement."
                        )
                    }
                    Text(
                        "These are suggestions only. Nothing is changed automatically. Change your profile in small steps, check the effect for a few days and talk to your diabetes team."
                    )
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Sensitivity")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Parts

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Period")
                Spacer()
                Text(String(localized: "\(report.periodDays) days", comment: "AI report period"))
                    .foregroundStyle(.secondary)
            }
            if let median = report.overallMedian {
                HStack {
                    Text("Median Ratio")
                    Spacer()
                    Text(Self.factor(median)).foregroundStyle(.secondary)
                }
            }
            let suggestions = report.suggestions
            Text(
                suggestions.isEmpty ?
                    String(localized: "No clear deviation – no profile change suggested.", comment: "Sensitivity report") :
                    String(
                        localized: "Suggested change in \(suggestions.count) of \(report.blocks.count) time blocks.",
                        comment: "Sensitivity report"
                    )
            )
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(suggestions.isEmpty ? Color.secondary : Color.primary)
        }
    }

    private func blockRow(_ block: SensitivityReport.Block) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.timeRange(block)).font(.headline).monospacedDigit()
                Spacer()
                verdictBadge(block)
            }
            if let median = block.median, let lower = block.lowerQuartile, let upper = block.upperQuartile {
                Text(
                    String(
                        localized: "Median \(Self.factor(median)) (middle half \(Self.factor(lower))–\(Self.factor(upper))) · \(block.dayCount) days",
                        comment: "Sensitivity report block"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No values").font(.caption).foregroundStyle(.secondary)
            }
            if block.factor != nil {
                changeLines(String(localized: "Basal", comment: "Sensitivity report"), block.basal, unit: "U/h") {
                    Self.decimal($0, digits: 2)
                }
                changeLines(String(localized: "ISF", comment: "Sensitivity report"), block.isfMgdl, unit: displayUnits + "/U") {
                    isMmol ? Self.decimal($0 * GlucoseUnits.exchangeRate, digits: 1) : Self.decimal($0, digits: 0)
                }
                changeLines(
                    String(localized: "Carb Ratio", comment: "Sensitivity report"),
                    block.carbRatio,
                    unit: "g/U"
                ) { Self.decimal($0, digits: 1) }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func changeLines(
        _ title: String,
        _ changes: [SensitivityReport.Change],
        unit: String,
        format: @escaping (Decimal) -> String
    ) -> some View {
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(changes, id: \.start) { change in
                    HStack(spacing: 4) {
                        Text(title).fontWeight(.semibold)
                        if changes.count > 1 {
                            Text(String(localized: "from \(change.start)", comment: "Sensitivity report profile entry"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(format(change.current)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(format(change.proposed)).fontWeight(.semibold)
                        Text(unit).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .monospacedDigit()
                }
            }
        }
    }

    private func verdictBadge(_ block: SensitivityReport.Block) -> some View {
        let (text, color): (String, Color) = {
            switch block.verdict {
            case .resistant:
                return (
                    String(localized: "resistant × \(Self.factor(block.factor ?? 1))", comment: "Sensitivity report"),
                    .orange
                )
            case .sensitive:
                return (
                    String(localized: "sensitive × \(Self.factor(block.factor ?? 1))", comment: "Sensitivity report"),
                    .teal
                )
            case .unremarkable:
                return (String(localized: "unremarkable", comment: "Sensitivity report"), .green)
            case .insufficientData:
                return (String(localized: "too little data", comment: "Sensitivity report"), .secondary)
            }
        }()
        return Text(text)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: - Share

    private var shareText: String {
        var lines = [
            String(localized: "OpenTrio sensitivity report", comment: "Sensitivity report share title"),
            String(localized: "\(report.periodDays) days", comment: "AI report period") + " · " +
                Date().formatted(date: .abbreviated, time: .shortened),
            ""
        ]
        for block in report.blocks {
            var line = Self.timeRange(block) + ": "
            switch block.verdict {
            case .resistant,
                 .sensitive:
                line += (
                    block.verdict == .resistant ?
                        String(localized: "resistant", comment: "Sensitivity report") :
                        String(localized: "sensitive", comment: "Sensitivity report")
                ) +
                    " × " + Self.factor(block.factor ?? 1)
            case .unremarkable: line += String(localized: "unremarkable", comment: "Sensitivity report")
            case .insufficientData: line += String(localized: "too little data", comment: "Sensitivity report")
            }
            if let median = block.median { line += " (Median \(Self.factor(median)), \(block.dayCount) d)" }
            lines.append(line)
            for change in block.basal {
                lines
                    .append(
                        "  Basal \(change.start): \(Self.decimal(change.current, digits: 2)) → \(Self.decimal(change.proposed, digits: 2)) U/h"
                    )
            }
            for change in block.isfMgdl {
                let current = isMmol ? Self.decimal(change.current * GlucoseUnits.exchangeRate, digits: 1) : Self
                    .decimal(change.current, digits: 0)
                let proposed = isMmol ? Self.decimal(change.proposed * GlucoseUnits.exchangeRate, digits: 1) : Self
                    .decimal(change.proposed, digits: 0)
                lines.append("  ISF \(change.start): \(current) → \(proposed) \(displayUnits)/U")
            }
            for change in block.carbRatio {
                lines.append(
                    "  " + String(localized: "Carb Ratio", comment: "Sensitivity report") +
                        " \(change.start): \(Self.decimal(change.current, digits: 1)) → \(Self.decimal(change.proposed, digits: 1)) g/U"
                )
            }
        }
        lines.append("")
        lines.append(String(
            localized: "Suggestions only – change the profile in small steps and talk to your diabetes team.",
            comment: "Sensitivity report share footer"
        ))
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func timeRange(_ block: SensitivityReport.Block) -> String {
        String(format: "%02d–%02d", block.startHour, block.endHour) + " " +
            String(localized: "o'clock", comment: "Sensitivity report time block suffix")
    }

    static func factor(_ value: Decimal) -> String { decimal(value, digits: 2) }

    static func decimal(_ value: Decimal, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }
}
