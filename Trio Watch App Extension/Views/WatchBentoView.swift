import SwiftUI

/// First page of the watch app as bento tiles, matching the iPhone header: a large glucose tile
/// on top, below it three tiles for loop, active insulin and active carbs.
/// Active overrides and temp targets show on the tinted buttons of the bottom bar.
struct WatchBentoView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        let metrics = Metrics(deviceType: state.deviceType)
        VStack(spacing: metrics.spacing) {
            glucoseTile(metrics: metrics)
                .frame(height: metrics.glucoseTileHeight)
            HStack(spacing: metrics.spacing) {
                loopTile(metrics: metrics)
                valueTile(
                    metrics: metrics,
                    title: String(localized: "IOB", comment: "Insulin on board, short"),
                    value: isWatchStateDated ? "--" : (state.iob ?? "--"),
                    tint: Color.insulin
                )
                valueTile(
                    metrics: metrics,
                    title: String(localized: "COB", comment: "Carbs on board, short"),
                    value: carbsText,
                    tint: Color.orange
                )
            }
            .frame(height: metrics.smallTileHeight)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tiles

    private var glucoseColor: Color {
        isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor()
    }

    private func glucoseTile(metrics: Metrics) -> some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.everyMinute) { context in
                    Text(glucoseAgeText(now: context.date))
                        .font(.system(size: metrics.captionSize, weight: .semibold))
                        .foregroundStyle(isWatchStateDated ? Color.secondary : glucoseColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(isWatchStateDated ? "--" : state.currentGlucose)
                    .font(.system(size: metrics.glucoseSize, weight: .bold, design: .rounded))
                    .foregroundStyle(isWatchStateDated ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                if state.showSyncingAnimation {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: metrics.captionSize))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                        .symbolEffect(.variableColor.iterative, options: .repeating, value: state.showSyncingAnimation)
                        .accessibilityHidden(true)
                }
                if !isWatchStateDated {
                    Image(systemName: "arrow.right")
                        .font(.system(size: metrics.glucoseSize * 0.45, weight: .bold))
                        .rotationEffect(.degrees(rotationDegrees))
                        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                        .accessibilityHidden(true)
                }
                Text(isWatchStateDated ? "--" : (state.delta ?? "--"))
                    .font(.system(size: metrics.captionSize + 1, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, metrics.tilePadding + 2)
        .padding(.vertical, metrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: metrics.largeCornerRadius)
                .fill(glucoseColor.opacity(isWatchStateDated ? 0.12 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.largeCornerRadius)
                .strokeBorder(glucoseColor.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func loopTile(metrics: Metrics) -> some View {
        VStack(spacing: 3) {
            Circle()
                .strokeBorder(loopColor, lineWidth: metrics.ringWidth)
                .frame(width: metrics.ringSize, height: metrics.ringSize)
                .accessibilityHidden(true)
            Text(
                isWatchStateDated ?
                    String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.") :
                    (state.lastLoopTime ?? "--")
            )
            .font(.system(size: metrics.captionSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: metrics.smallCornerRadius).fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Loop"))
    }

    private func valueTile(metrics: Metrics, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: metrics.captionSize, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: metrics.valueSize, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, metrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: metrics.smallCornerRadius).fill(tint.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Values

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
        let glucoseTileHeight: CGFloat
        let smallTileHeight: CGFloat
        let glucoseSize: CGFloat
        let valueSize: CGFloat
        let captionSize: CGFloat
        let spacing: CGFloat
        let horizontalPadding: CGFloat
        let tilePadding: CGFloat
        let ringSize: CGFloat
        let ringWidth: CGFloat
        let largeCornerRadius: CGFloat
        let smallCornerRadius: CGFloat

        init(deviceType: WatchSize) {
            switch deviceType {
            case .watch40mm,
                 .watch41mm:
                glucoseTileHeight = 64
                smallTileHeight = 42
                glucoseSize = 34
                valueSize = 14
                captionSize = 10
                spacing = 4
            case .watch42mm,
                 .watch44mm:
                glucoseTileHeight = 70
                smallTileHeight = 46
                glucoseSize = 38
                valueSize = 15
                captionSize = 11
                spacing = 5
            case .unknown,
                 .watch45mm:
                glucoseTileHeight = 76
                smallTileHeight = 50
                glucoseSize = 42
                valueSize = 16
                captionSize = 11
                spacing = 5
            case .watch49mm:
                glucoseTileHeight = 80
                smallTileHeight = 52
                glucoseSize = 44
                valueSize = 17
                captionSize = 12
                spacing = 6
            }
            horizontalPadding = 4
            tilePadding = 6
            ringSize = smallTileHeight * 0.36
            ringWidth = 3
            largeCornerRadius = 16
            smallCornerRadius = 13
        }
    }
}
