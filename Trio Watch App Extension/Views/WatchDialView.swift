import SwiftUI

/// First page of the watch app in the style of a watch face with complications: the glucose value
/// large in the middle, COB and loop as small ring gauges in the lower corners. IOB sits as a ring
/// gauge in the top leading corner of the toolbar (`WatchIOBGauge`), the system shows the time.
/// The action buttons stay in the bottom bar.
struct WatchDialView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        let metrics = WatchDialMetrics(deviceType: state.deviceType)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            glucose(metrics: metrics)
            Spacer(minLength: 2)
            HStack(alignment: .center) {
                WatchRingGauge(
                    value: isWatchStateDated ? "--" : (state.cob ?? "--"),
                    fraction: isWatchStateDated ? 0 : cobFraction,
                    tint: Color.orange,
                    diameter: metrics.gaugeDiameter
                )
                Text("COB", comment: "Carbs on board, short")
                    .font(.system(size: metrics.labelSize, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Spacer(minLength: 4)
                Text("Loop")
                    .font(.system(size: metrics.labelSize, weight: .semibold))
                    .foregroundStyle(loopColor)
                WatchRingGauge(
                    value: loopText,
                    fraction: 1,
                    tint: loopColor,
                    diameter: metrics.gaugeDiameter
                )
                .accessibilityLabel(Text("Loop"))
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Glucose

    private func glucose(metrics: WatchDialMetrics) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text(isWatchStateDated ? "--" : state.currentGlucose)
                    .font(.system(size: metrics.glucoseSize, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !isWatchStateDated {
                    Image(systemName: "arrow.right")
                        .font(.system(size: metrics.glucoseSize * 0.4, weight: .bold))
                        .foregroundStyle(glucoseColor)
                        .rotationEffect(.degrees(rotationDegrees))
                        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                        .accessibilityHidden(true)
                }
                if state.showSyncingAnimation {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: metrics.labelSize))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                        .symbolEffect(.variableColor.iterative, options: .repeating, value: state.showSyncingAnimation)
                        .accessibilityHidden(true)
                }
            }
            TimelineView(.everyMinute) { context in
                Text(subtitle(now: context.date))
                    .font(.system(size: metrics.labelSize + 1))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Green inside the target range, otherwise the phone's out-of-range colour; grey when stale.
    private var glucoseColor: Color {
        guard !isWatchStateDated else { return Color.secondary }
        guard let value = state.glucoseValues.last?.glucose else { return state.currentGlucoseColorString.toColor() }
        let low = NSDecimalNumber(decimal: state.lowGlucose).doubleValue
        let high = NSDecimalNumber(decimal: state.highGlucose).doubleValue
        if value > low, value < high { return Color.loopGreen }
        return state.currentGlucoseColorString.toColor()
    }

    private func subtitle(now: Date) -> String {
        guard !isWatchStateDated else {
            return String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.")
        }
        let delta = state.delta ?? "--"
        guard let latest = state.glucoseValues.map(\.date).max() else { return delta }
        let minutes = max(0, Int(now.timeIntervalSince(latest) / 60))
        return delta + " · " +
            String(localized: "\(minutes) min ago", comment: "Age of the latest glucose reading on the watch")
    }

    // MARK: - Corners

    /// The COB ring is full at 100 g.
    private var cobFraction: Double {
        guard let cob = WatchNumber.parse(state.cob) else { return 0 }
        return min(max(cob / 100, 0), 1)
    }

    /// Minutes since the last loop, short ("1′").
    private var loopText: String {
        guard !isWatchStateDated,
              let text = state.lastLoopTime,
              let minutes = text.split(separator: " ").first.flatMap({ Int($0) })
        else { return "--" }
        return "\(minutes)′"
    }

    /// Same thresholds as the loop ring of the classic watch face: green up to 5 min, yellow up to 10, red after.
    private var loopColor: Color {
        guard !isWatchStateDated,
              let text = state.lastLoopTime,
              let minutes = text.split(separator: " ").first.flatMap({ Int($0) })
        else { return Color.secondary }
        switch minutes {
        case ...5: return Color.loopGreen
        case ...10: return Color.loopYellow
        default: return Color.loopRed
        }
    }
}

/// IOB as a ring gauge for the top leading corner of the toolbar; the ring is full at Max Bolus.
struct WatchIOBGauge: View {
    let state: WatchState
    let isWatchStateDated: Bool

    var body: some View {
        let metrics = WatchDialMetrics(deviceType: state.deviceType)
        HStack(spacing: 4) {
            WatchRingGauge(
                value: isWatchStateDated ? "--" : (state.iob ?? "--"),
                fraction: isWatchStateDated ? 0 : fraction,
                tint: Color.insulin,
                diameter: metrics.gaugeDiameter
            )
            Text("IOB", comment: "Insulin on board, short")
                .font(.system(size: metrics.labelSize, weight: .semibold))
                .foregroundStyle(Color.insulin)
        }
        .accessibilityElement(children: .combine)
    }

    private var fraction: Double {
        guard let iob = WatchNumber.parse(state.iob) else { return 0 }
        let maxBolus = NSDecimalNumber(decimal: state.maxBolus).doubleValue
        guard maxBolus > 0 else { return 0 }
        return min(max(iob / maxBolus, 0), 1)
    }
}

/// A small ring with a value in the middle, like a watch face complication.
struct WatchRingGauge: View {
    let value: String
    /// 0 ... 1 of the ring that is filled.
    let fraction: Double
    let tint: Color
    let diameter: CGFloat

    var body: some View {
        let lineWidth = max(3, diameter * 0.12)
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value)
                .font(.system(size: diameter * 0.3, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .padding(lineWidth / 2)
    }
}

struct WatchDialMetrics {
    let glucoseSize: CGFloat
    let gaugeDiameter: CGFloat
    let labelSize: CGFloat
    let horizontalPadding: CGFloat

    init(deviceType: WatchSize) {
        switch deviceType {
        case .watch40mm,
             .watch41mm:
            glucoseSize = 42
            gaugeDiameter = 30
            labelSize = 10
        case .watch42mm,
             .watch44mm:
            glucoseSize = 48
            gaugeDiameter = 33
            labelSize = 11
        case .unknown,
             .watch45mm:
            glucoseSize = 54
            gaugeDiameter = 36
            labelSize = 11
        case .watch49mm:
            glucoseSize = 56
            gaugeDiameter = 38
            labelSize = 12
        }
        horizontalPadding = 8
    }
}

/// Reads the formatted numbers the phone sends ("2.35" or "2,35").
enum WatchNumber {
    static func parse(_ text: String?) -> Double? {
        guard let text, text != "--" else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: text) { return number.doubleValue }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }
}
