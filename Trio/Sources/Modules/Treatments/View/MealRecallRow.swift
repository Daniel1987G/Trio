import SwiftUI

/// "Last time" row of the bolus calculator: the same meal on an earlier day, its bolus, how
/// glucose went, and the bolus suggested from it.
struct MealRecallRow: View {
    let recall: MealRecall.Recall
    let carbsNow: Decimal
    let units: GlucoseUnits
    let amount: Decimal
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Last Time")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Spacer()
                if let suggested = recall.suggested {
                    Button(action: onUse) {
                        HStack(spacing: 2) {
                            Text(Self.insulin(suggested))
                            Text(String(
                                localized: " U",
                                comment: "Unit in number of units delivered (keep the space character!)"
                            ))
                            .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(.trailing, -10)
                    .disabled(amount == suggested)
                    .accessibilityLabel(Text(
                        String(localized: "Use bolus from last time, \(Self.insulin(suggested)) units", comment: "Meal recall")
                    ))
                }
            }

            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(outcomeText)
                .font(.caption)
                .foregroundStyle(outcomeColor)
            if let note = carbsNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let date = recall.meal.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let carbs = Self.number(recall.meal.carbs, digits: 0)
        if recall.dose > 0 {
            return String(
                localized: "\(date): \(Self.insulin(recall.dose)) U meal bolus for \(carbs) g",
                comment: "Meal recall: date, bolus and carbs of the earlier meal"
            )
        }
        return String(
            localized: "\(date): \(carbs) g without a meal bolus",
            comment: "Meal recall: earlier meal without bolus"
        )
    }

    private var outcomeText: String {
        let step = Self.insulin(recall.step)
        switch recall.outcome {
        case let .low(_, mgdl):
            return String(
                localized: "Then a low (\(glucose(mgdl))): one step (\(step) U) less.",
                comment: "Meal recall outcome"
            )
        case let .highRise(_, rise):
            return String(
                localized: "Then a rise of +\(glucose(rise)): one step (\(step) U) more.",
                comment: "Meal recall outcome"
            )
        case let .onTarget(peakRise):
            return String(
                localized: "Then in range (peak +\(glucose(peakRise))): same bolus.",
                comment: "Meal recall outcome"
            )
        case .unknown:
            return String(
                localized: "How it went is unclear (next meal too soon or no glucose data).",
                comment: "Meal recall outcome"
            )
        }
    }

    private var outcomeColor: Color {
        switch recall.outcome {
        case .low: return .orange
        case .highRise: return .yellow
        case .onTarget: return .green
        case .unknown: return .secondary
        }
    }

    /// Carbs differ by more than 20 %: the dose then is only a rough guide.
    private var carbsNote: String? {
        guard carbsNow > 0, recall.meal.carbs > 0 else { return nil }
        let ratio = carbsNow / recall.meal.carbs
        guard ratio < 0.8 || ratio > 1.2 else { return nil }
        return String(
            localized: "Different amount of carbs today (\(Self.number(carbsNow, digits: 0)) g): compare with the recommendation.",
            comment: "Meal recall"
        )
    }

    private func glucose(_ mgdl: Decimal) -> String {
        units == .mmolL ?
            Self.number(mgdl * Decimal(string: "0.0555")!, digits: 1) + " mmol/L" :
            Self.number(mgdl, digits: 0) + " mg/dL"
    }

    static func insulin(_ value: Decimal) -> String {
        number(value, digits: 2)
    }

    static func number(_ value: Decimal, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }
}
