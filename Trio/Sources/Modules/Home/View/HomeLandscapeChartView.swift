import SwiftUI
import UIKit

/// Which way the phone is turned while the landscape chart is shown.
enum LandscapeChartOrientation: String, Identifiable {
    /// Device `.landscapeLeft` (top of the phone points left): content turns clockwise.
    case left
    /// Device `.landscapeRight`: content turns counterclockwise.
    case right

    var id: String { rawValue }

    var angle: Angle { self == .left ? .degrees(90) : .degrees(-90) }

    init?(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .landscapeLeft: self = .left
        case .landscapeRight: self = .right
        default: return nil
        }
    }
}

/// The Home chart across the whole display, opened with the statistics button in the header.
///
/// The app itself stays portrait-only; this view is presented full screen and turned by 90°, so
/// no other screen has to support landscape. Glucose, trend, delta, IOB and COB stay visible in a
/// slim header; pan, pinch and press work as on the Home screen. The close button dismisses it.
struct HomeLandscapeChartView: View {
    let state: Home.StateModel
    let orientation: LandscapeChartOrientation
    let onClose: () -> Void

    @State private var selection: Date?

    var body: some View {
        GeometryReader { screen in
            // landscape canvas: the screen's height becomes the width
            let width = screen.size.height
            let height = screen.size.width
            content(width: width, height: height)
                .frame(width: width, height: height)
                .rotationEffect(orientation.angle)
                .position(x: screen.size.width / 2, y: screen.size.height / 2)
        }
        .ignoresSafeArea()
        .background(Color.chart.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func content(width _: CGFloat, height _: CGFloat) -> some View {
        VStack(spacing: 4) {
            header
            GeometryReader { geo in
                MainChartView(
                    geo: geo,
                    chartHeight: geo.size.height,
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    displayXgridLines: state.displayXgridLines,
                    displayYgridLines: state.displayYgridLines,
                    thresholdLines: state.thresholdLines,
                    state: state,
                    selection: $selection
                )
            }
        }
        // room for the camera cut-out on one long side and the home indicator below
        .padding(.horizontal, 52)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(glucoseText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseTint)
                ForEach(Array(trendSymbols.enumerated()), id: \.offset) { _, symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(glucoseTint)
                        .accessibilityHidden(true)
                }
                if let delta = deltaText {
                    Text(delta)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Text(selectionText ?? ageText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("IOB", comment: "Insulin on board, short")
                    .font(.footnote).fontWeight(.semibold)
                    .foregroundStyle(Color.insulin)
                Text(
                    (Formatter.decimalFormatterWithTwoFractionDigits.string(from: state.currentIOB as NSNumber) ?? "0") +
                        " " + String(localized: "U", comment: "Insulin unit")
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("COB", comment: "Carbs on board, short")
                    .font(.footnote).fontWeight(.semibold)
                    .foregroundStyle(Color.orange)
                Text(
                    (
                        Formatter.integerFormatter.string(
                            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                        ) ?? "0"
                    ) + " " + String(localized: "g", comment: "gram of carbs")
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .accessibilityElement(children: .combine)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: - Values

    /// Latest reading if it is fresh (same 12 min gate as the Home header).
    private var freshValue: Int16? {
        guard let last = state.latestTwoGlucoseValues.last, let date = last.date,
              state.timerDate.timeIntervalSince(date) < 12 * 60
        else { return nil }
        return last.glucose
    }

    private var glucoseText: String {
        guard let value = freshValue else { return "– –" }
        return state.units == .mgdL ? Decimal(value).description : Decimal(value).formattedAsMmolL
    }

    private var glucoseTint: Color {
        guard let value = freshValue else { return .secondary }
        if Decimal(value) < state.lowGlucose { return .loopRed }
        if Decimal(value) > state.highGlucose { return .orange }
        return .loopGreen
    }

    private var deltaText: String? {
        let values = state.latestTwoGlucoseValues
        guard values.count >= 2, freshValue != nil else { return nil }
        var last = Decimal(values.last?.glucose ?? 0)
        var previous = Decimal(values.first?.glucose ?? 0)
        if state.units == .mmolL {
            last = last.asMmolL
            previous = previous.asMmolL
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = state.units == .mmolL ? 1 : 0
        formatter.minimumFractionDigits = state.units == .mmolL ? 1 : 0
        formatter.positivePrefix = "+"
        return formatter.string(from: (last - previous) as NSNumber)
    }

    private var trendSymbols: [String] {
        guard freshValue != nil else { return [] }
        switch state.latestTwoGlucoseValues.last?.directionEnum {
        case .doubleUp,
             .tripleUp: return ["arrow.up", "arrow.up"]
        case .singleUp: return ["arrow.up"]
        case .fortyFiveUp: return ["arrow.up.right"]
        case .flat: return ["arrow.right"]
        case .fortyFiveDown: return ["arrow.down.right"]
        case .singleDown: return ["arrow.down"]
        case .doubleDown,
             .tripleDown: return ["arrow.down", "arrow.down"]
        default: return []
        }
    }

    private var ageText: String {
        guard let date = state.latestTwoGlucoseValues.last?.date else { return "" }
        let minutes = max(0, Int(state.timerDate.timeIntervalSince(date) / 60))
        return String(localized: "\(minutes) min ago", comment: "Age of the latest glucose reading on the watch")
    }

    /// While the chart is pressed, the time under the finger.
    private var selectionText: String? {
        guard let selection else { return nil }
        return selection.formatted(date: .omitted, time: .shortened)
    }
}
