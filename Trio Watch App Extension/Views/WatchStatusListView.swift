import SwiftUI

/// First page of the watch app in list style: glucose on top, then one row each for active
/// insulin, active carbs, the loop and an active override or temp target.
/// On small watches insulin and carbs share one row when the full list does not fit.
struct WatchStatusListView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool
    let activeOverrideName: String?
    let activeTempTargetName: String?

    var body: some View {
        let metrics = Metrics(deviceType: state.deviceType)
        ViewThatFits(in: .vertical) {
            content(metrics: metrics, compact: false)
            content(metrics: metrics, compact: true)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(metrics: Metrics, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            glucoseRow(metrics: metrics)

            if compact {
                row(
                    metrics: metrics,
                    systemImage: "syringe.fill",
                    tint: Color.insulin,
                    label: String(localized: "IOB", comment: "Insulin on board, short") + " / " +
                        String(localized: "COB", comment: "Carbs on board, short"),
                    value: insulinText + " · " + carbsText
                )
            } else {
                row(
                    metrics: metrics,
                    systemImage: "syringe.fill",
                    tint: Color.insulin,
                    label: String(localized: "Insulin on board", comment: "Watch status list row: active insulin"),
                    value: insulinText
                )
                row(
                    metrics: metrics,
                    systemImage: "fork.knife",
                    tint: Color.orange,
                    label: String(localized: "Carbs", comment: "Watch status list row: active carbs"),
                    value: carbsText
                )
            }

            loopRow(metrics: metrics)

            if let name = activeOverrideName {
                row(
                    metrics: metrics,
                    systemImage: "clock.arrow.2.circlepath",
                    tint: Color.purple,
                    label: String(localized: "Override", comment: "Watch status list row: active override"),
                    value: name,
                    background: Color.purple.opacity(0.22)
                )
            }
            if let name = activeTempTargetName {
                row(
                    metrics: metrics,
                    systemImage: "target",
                    tint: Color.loopGreen,
                    label: String(localized: "Temp target", comment: "Watch status list row: active temp target"),
                    value: name,
                    background: Color.loopGreen.opacity(0.18)
                )
            }
        }
    }

    // MARK: - Rows

    private func glucoseRow(metrics: Metrics) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(isWatchStateDated ? "--" : state.currentGlucose)
                .font(.system(size: metrics.glucoseSize, weight: .bold, design: .rounded))
                .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if !isWatchStateDated {
                Image(systemName: "arrow.right")
                    .font(.system(size: metrics.glucoseSize * 0.5, weight: .bold))
                    .foregroundStyle(state.currentGlucoseColorString.toColor())
                    .rotationEffect(.degrees(rotationDegrees))
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(isWatchStateDated ? "--" : (state.delta ?? "--"))
                    .foregroundStyle(Color.primary)
                TimelineView(.everyMinute) { context in
                    Text(glucoseAgeText(now: context.date))
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.system(size: metrics.rowFontSize))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            if state.showSyncingAnimation {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: metrics.rowFontSize))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                    .symbolEffect(.variableColor.iterative, options: .repeating, value: state.showSyncingAnimation)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
    }

    private func loopRow(metrics: Metrics) -> some View {
        HStack(spacing: 6) {
            Circle()
                .stroke(loopColor, lineWidth: metrics.rowFontSize * 0.25)
                .frame(width: metrics.iconWidth * 0.8, height: metrics.iconWidth * 0.8)
                .frame(width: metrics.iconWidth)
                .accessibilityHidden(true)
            Text("Loop")
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 4)
            if isWatchStateDated {
                Text("STALE DATA", comment: "Information displayed when watch app data outdated or stale.")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.secondary)
            } else {
                Text(state.lastLoopTime ?? "--")
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: metrics.rowFontSize))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .background(RoundedRectangle(cornerRadius: metrics.cornerRadius).fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private func row(
        metrics: Metrics,
        systemImage: String,
        tint: Color,
        label: String,
        value: String,
        background: Color = Color.white.opacity(0.08)
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: metrics.iconWidth)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.system(size: metrics.rowFontSize))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .background(RoundedRectangle(cornerRadius: metrics.cornerRadius).fill(background))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Values

    private var insulinText: String {
        guard !isWatchStateDated, let iob = state.iob, iob != "--" else { return "--" }
        return iob + " " + String(localized: "U", comment: "Insulin unit")
    }

    private var carbsText: String {
        guard !isWatchStateDated, let cob = state.cob, cob != "--" else { return "--" }
        return cob + " " + String(localized: "g", comment: "gram of carbs")
    }

    private func glucoseAgeText(now: Date) -> String {
        guard !isWatchStateDated, let latest = state.glucoseValues.map(\.date).max() else { return "" }
        let minutes = max(0, Int(now.timeIntervalSince(latest) / 60))
        return String(localized: "\(minutes) min ago", comment: "Age of the latest glucose reading on the watch")
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
        let glucoseSize: CGFloat
        let rowFontSize: CGFloat
        let rowVerticalPadding: CGFloat
        let rowHorizontalPadding: CGFloat
        let rowSpacing: CGFloat
        let horizontalPadding: CGFloat
        let iconWidth: CGFloat
        let cornerRadius: CGFloat

        init(deviceType: WatchSize) {
            switch deviceType {
            case .watch40mm,
                 .watch41mm:
                glucoseSize = 30
                rowFontSize = 12
                rowVerticalPadding = 3
                rowSpacing = 3
            case .watch42mm,
                 .watch44mm:
                glucoseSize = 34
                rowFontSize = 13
                rowVerticalPadding = 3
                rowSpacing = 3
            case .unknown,
                 .watch45mm:
                glucoseSize = 38
                rowFontSize = 14
                rowVerticalPadding = 4
                rowSpacing = 4
            case .watch49mm:
                glucoseSize = 40
                rowFontSize = 14
                rowVerticalPadding = 4
                rowSpacing = 4
            }
            rowHorizontalPadding = 8
            horizontalPadding = 6
            iconWidth = rowFontSize + 4
            cornerRadius = rowFontSize
        }
    }
}
