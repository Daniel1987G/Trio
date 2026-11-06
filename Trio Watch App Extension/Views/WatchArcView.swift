import SwiftUI

/// First page of the watch app with a target range arc: a half circle from low to high glucose,
/// the target range marked green, a dot at the current value and the value itself inside the arc.
/// Below it one line with IOB, COB and the loop age.
struct WatchArcView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        let metrics = Metrics(deviceType: state.deviceType)
        VStack(spacing: metrics.spacing) {
            arc(metrics: metrics)
                .frame(height: metrics.arcHeight)
            statusLine(metrics: metrics)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Arc

    /// Scale of the arc in the user's unit: 40–300 mg/dL or 2.2–16.7 mmol/L.
    private var scale: ClosedRange<Double> {
        state.isMmolL ? 2.2 ... 16.7 : 40 ... 300
    }

    private func fraction(_ value: Double) -> Double {
        let span = scale.upperBound - scale.lowerBound
        return min(max((value - scale.lowerBound) / span, 0), 1)
    }

    private var lowFraction: Double { fraction(NSDecimalNumber(decimal: state.lowGlucose).doubleValue) }
    private var highFraction: Double { fraction(NSDecimalNumber(decimal: state.highGlucose).doubleValue) }

    /// Latest reading in the user's unit; nil when stale or missing.
    private var currentValue: Double? {
        guard !isWatchStateDated else { return nil }
        return state.glucoseValues.last?.glucose
    }

    /// Green inside the target range, otherwise the phone's out-of-range colour.
    private var markerColor: Color {
        guard let value = currentValue else { return Color.secondary }
        let low = NSDecimalNumber(decimal: state.lowGlucose).doubleValue
        let high = NSDecimalNumber(decimal: state.highGlucose).doubleValue
        if value > low, value < high { return Color.loopGreen }
        return state.currentGlucoseColorString.toColor()
    }

    private func arc(metrics: Metrics) -> some View {
        ZStack(alignment: .bottom) {
            ArcSegment(from: 0, to: 1, inset: metrics.markerSize / 2)
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: metrics.lineWidth, lineCap: .round))
            ArcSegment(from: lowFraction, to: highFraction, inset: metrics.markerSize / 2)
                .stroke(Color.loopGreen.opacity(0.5), style: StrokeStyle(lineWidth: metrics.lineWidth, lineCap: .butt))
            if let value = currentValue {
                ArcMarker(fraction: fraction(value), size: metrics.markerSize, inset: metrics.markerSize / 2)
                    .fill(markerColor)
                    .overlay(
                        ArcMarker(fraction: fraction(value), size: metrics.markerSize, inset: metrics.markerSize / 2)
                            .stroke(Color.black, lineWidth: 2)
                    )
                    .animation(.easeInOut(duration: 0.4), value: value)
            }

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 3) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .font(.system(size: metrics.glucoseSize, weight: .bold, design: .rounded))
                        .foregroundStyle(isWatchStateDated ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !isWatchStateDated {
                        Image(systemName: "arrow.right")
                            .font(.system(size: metrics.glucoseSize * 0.42, weight: .bold))
                            .rotationEffect(.degrees(rotationDegrees))
                            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                            .accessibilityHidden(true)
                    }
                }
                TimelineView(.everyMinute) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: metrics.captionSize))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, metrics.lineWidth + metrics.markerSize)
            .padding(.bottom, metrics.markerSize / 2)
        }
        .accessibilityElement(children: .combine)
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

    // MARK: - Status line

    private func statusLine(metrics: Metrics) -> some View {
        HStack(spacing: metrics.spacing * 3) {
            HStack(spacing: 3) {
                Text("IOB", comment: "Insulin on board, short").foregroundStyle(Color.insulin).fontWeight(.semibold)
                Text(isWatchStateDated ? "--" : (state.iob ?? "--"))
            }
            HStack(spacing: 3) {
                Text("COB", comment: "Carbs on board, short").foregroundStyle(Color.orange).fontWeight(.semibold)
                Text(isWatchStateDated ? "--" : (state.cob ?? "--"))
            }
            HStack(spacing: 3) {
                Circle()
                    .fill(loopColor)
                    .frame(width: metrics.captionSize * 0.7, height: metrics.captionSize * 0.7)
                    .accessibilityHidden(true)
                Text(isWatchStateDated ? "--" : (state.lastLoopTime ?? "--"))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Loop"))
        }
        .font(.system(size: metrics.captionSize + 1))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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

    // MARK: - Sizes

    private struct Metrics {
        let arcHeight: CGFloat
        let lineWidth: CGFloat
        let markerSize: CGFloat
        let glucoseSize: CGFloat
        let captionSize: CGFloat
        let spacing: CGFloat
        let horizontalPadding: CGFloat

        init(deviceType: WatchSize) {
            switch deviceType {
            case .watch40mm,
                 .watch41mm:
                arcHeight = 82
                lineWidth = 7
                glucoseSize = 32
                captionSize = 10
            case .watch42mm,
                 .watch44mm:
                arcHeight = 88
                lineWidth = 8
                glucoseSize = 36
                captionSize = 11
            case .unknown,
                 .watch45mm:
                arcHeight = 96
                lineWidth = 9
                glucoseSize = 40
                captionSize = 11
            case .watch49mm:
                arcHeight = 100
                lineWidth = 9
                glucoseSize = 42
                captionSize = 12
            }
            markerSize = lineWidth + 6
            spacing = 4
            horizontalPadding = 6
        }
    }
}

// MARK: - Shapes

/// Point on the upper half circle that fits `rect` (centre at the bottom middle, `inset` kept free
/// on every side for the stroke and the marker) for a fraction 0 (left end) ... 1 (right end).
private func arcPoint(_ fraction: Double, in rect: CGRect, inset: CGFloat) -> CGPoint {
    let radius = max(min(rect.width / 2 - inset, rect.height - 2 * inset), 1)
    let center = CGPoint(x: rect.midX, y: rect.maxY - inset)
    let angle = Double.pi * (1 - fraction)
    return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y - radius * CGFloat(sin(angle)))
}

/// Part of the upper half circle between two fractions, built from short line segments.
private struct ArcSegment: Shape {
    let from: Double
    let to: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        let steps = max(Int((to - from) * 64), 2)
        path.move(to: arcPoint(from, in: rect, inset: inset))
        for step in 1 ... steps {
            path.addLine(to: arcPoint(from + (to - from) * Double(step) / Double(steps), in: rect, inset: inset))
        }
        return path
    }
}

/// Dot on the half circle at `fraction`.
private struct ArcMarker: Shape {
    let fraction: Double
    let size: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let point = arcPoint(fraction, in: rect, inset: inset)
        return Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
    }
}
