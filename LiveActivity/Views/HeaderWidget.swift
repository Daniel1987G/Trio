import SwiftUI
import WidgetKit

// MARK: - Timeline

struct HeaderWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: HeaderWidgetSnapshot?
}

struct HeaderWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> HeaderWidgetEntry {
        HeaderWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeaderWidgetEntry) -> Void) {
        completion(HeaderWidgetEntry(date: Date(), snapshot: HeaderWidgetStore.load() ?? (context.isPreview ? .preview : nil)))
    }

    /// One entry per minute for the next 30 minutes, so ages, loop colour and the
    /// stale reading advance without the app; the app reloads on every change.
    func getTimeline(in _: Context, completion: @escaping (Timeline<HeaderWidgetEntry>) -> Void) {
        let snapshot = HeaderWidgetStore.load()
        let now = Date()
        let start = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        var entries = [HeaderWidgetEntry(date: now, snapshot: snapshot)]
        for minute in 1 ... 30 {
            entries.append(HeaderWidgetEntry(date: start.addingTimeInterval(Double(minute) * 60), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(start.addingTimeInterval(31 * 60))))
    }
}

// MARK: - Widget

/// The home header as a widget: small on the home screen and in CarPlay (iOS 26), medium as tiles.
struct HeaderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HeaderWidgetSnapshot.widgetKind, provider: HeaderWidgetProvider()) { entry in
            HeaderWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color("WidgetBackground") }
                .widgetURL(URL(string: "Trio://"))
        }
        .configurationDisplayName(String(localized: "OpenTrio Header", comment: "Header widget name"))
        .description(String(
            localized: "Glucose, loop, IOB, COB and pod as on the home screen.",
            comment: "Header widget description"
        ))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Content

/// Values derived from a snapshot at the time of a timeline entry.
private struct HeaderWidgetModel {
    let snapshot: HeaderWidgetSnapshot
    let now: Date

    var freshGlucose: Int? {
        guard let value = snapshot.glucose, let date = snapshot.glucoseDate,
              now.timeIntervalSince(date) < HeaderWidgetSnapshot.glucoseFreshness else { return nil }
        return value
    }

    var glucoseText: String { freshGlucose.map(snapshot.formattedGlucose) ?? "– –" }

    var glucoseColor: Color {
        guard freshGlucose != nil else { return .secondary }
        return snapshot.glucoseColorHex.flatMap(Color.init(liveActivityHex:)) ?? .primary
    }

    var rangeColor: Color? {
        guard freshGlucose != nil else { return nil }
        return snapshot.rangeColorHex.flatMap(Color.init(liveActivityHex:))
    }

    var deltaText: String? {
        guard freshGlucose != nil, let delta = snapshot.delta else { return nil }
        return snapshot.formattedDelta(delta)
    }

    var glucoseAge: String? { snapshot.glucoseDate.map { Self.minutes(since: $0, now: now) } }

    var loopAge: String {
        guard let date = snapshot.lastLoopDate else { return "--" }
        return Self.minutes(since: date, now: now)
    }

    var loopColor: Color {
        if !snapshot.loopColorFollowsAge {
            return snapshot.fixedLoopColorHex.flatMap(Color.init(liveActivityHex:)) ?? .secondary
        }
        let colors = snapshot.loopColorHexes.compactMap(Color.init(liveActivityHex:))
        guard colors.count == 3, let last = snapshot.lastLoopDate else { return .secondary }
        let delta = now.timeIntervalSince(last) - 30 // same 30 s lag as the header
        if delta <= 5 * 60 { return colors[0] }
        if delta <= 10 * 60 { return colors[1] }
        return colors[2]
    }

    var iobText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: snapshot.iob as NSNumber) ?? "0"
    }

    var eventualText: String? {
        snapshot.eventualGlucose.map(snapshot.formattedGlucose)
    }

    var reservoirText: String? {
        if snapshot.reservoirIsOver50 { return "50+ " + String(localized: "U", comment: "Insulin unit") }
        guard let reservoir = snapshot.reservoir else { return nil }
        return "\(Int(reservoir.rounded())) " + String(localized: "U", comment: "Insulin unit")
    }

    var reservoirColor: Color {
        guard let reservoir = snapshot.reservoir else { return .secondary }
        if reservoir <= 10 { return .red }
        if reservoir <= 30 { return .orange }
        return Color(red: 0.11, green: 0.51, blue: 0.96)
    }

    var podText: String? {
        guard let expires = snapshot.pumpExpiresAt else {
            return snapshot.pumpBatteryPercent.map { "\($0) %" }
        }
        let time = expires.timeIntervalSince(now)
        guard time > 0 else { return String(localized: "Replace pod", comment: "View/Header when pod expired") }
        let days = Int(time / 86400)
        let hours = Int(time.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(time.truncatingRemainder(dividingBy: 3600) / 60)
        if days >= 1 {
            return "\(days)" + String(localized: "d", comment: "abbreviation for days") + " \(hours)" +
                String(localized: "h", comment: "abbreviation for hours")
        }
        if hours >= 1 {
            return "\(hours)" + String(localized: "h", comment: "abbreviation for hours") + " \(minutes)" +
                String(localized: "m", comment: "abbreviation for minutes")
        }
        return "\(minutes)" + String(localized: "m", comment: "abbreviation for minutes")
    }

    var podColor: Color {
        guard let expires = snapshot.pumpExpiresAt else { return .secondary }
        let time = expires.timeIntervalSince(now)
        if time <= 8 * 3600 { return .red }
        if time <= 86400 { return .orange }
        return .green
    }

    static func minutes(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes > 1440 { return "> 1 " + String(localized: "d", comment: "abbreviation for days") }
        return "\(minutes) " + String(localized: "min", comment: "Minutes ago in the header widget")
    }
}

struct HeaderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HeaderWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let model = HeaderWidgetModel(snapshot: snapshot, now: entry.date)
            switch family {
            case .systemMedium: MediumHeaderView(model: model)
            default: SmallHeaderView(model: model)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "drop.fill").font(.title2)
                Text("Open OpenTrio once to show the header here.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrendArrows: View {
    let symbols: [String]
    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Image(systemName: symbol)
            }
        }
    }
}

private struct LoopRing: View {
    let color: Color
    var size: CGFloat = 14
    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: size / 5)
            .frame(width: size, height: size)
    }
}

/// Small widget (home screen and CarPlay): reading, trend and delta, then loop, IOB, COB and pod.
private struct SmallHeaderView: View {
    let model: HeaderWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                Text(model.glucoseText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(model.glucoseColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if model.freshGlucose != nil {
                    TrendArrows(symbols: model.snapshot.trendSymbols)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(model.glucoseColor)
                }
            }
            HStack(spacing: 4) {
                if let delta = model.deltaText {
                    Text(delta).fontWeight(.semibold)
                }
                if let age = model.glucoseAge {
                    Text(age).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                LoopRing(color: model.loopColor, size: 12)
                Text(model.loopAge)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(model.loopColor)
            }
            .lineLimit(1)

            HStack(spacing: 6) {
                Text(model.iobText + " " + String(localized: "U", comment: "Insulin unit"))
                    .foregroundStyle(Color.blue)
                Text("\(model.snapshot.cob) " + String(localized: "g", comment: "gram of carbs"))
                    .foregroundStyle(Color.orange)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if let message = model.snapshot.pumpMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if model.reservoirText != nil || model.podText != nil {
                HStack(spacing: 4) {
                    if let reservoir = model.reservoirText {
                        Image(systemName: "cross.vial.fill").foregroundStyle(model.reservoirColor)
                        Text(reservoir)
                    }
                    if let pod = model.podText {
                        Text(pod).foregroundStyle(model.podColor)
                    }
                }
                .font(.caption2).fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Rounded tile with a light tint, like the home header tiles.
private struct WidgetTile<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.32), lineWidth: 1)
            )
    }
}

/// Medium widget: the tiled header (glucose left; loop, IOB, COB right; pod and forecast below).
private struct MediumHeaderView: View {
    let model: HeaderWidgetModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                WidgetTile(tint: model.rangeColor) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            String(localized: "Glucose", comment: "Bento glucose tile title") +
                                (model.glucoseAge.map { " · " + $0 } ?? "")
                        )
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Text(model.glucoseText)
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(model.glucoseColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            if model.freshGlucose != nil {
                                TrendArrows(symbols: model.snapshot.trendSymbols)
                                    .font(.system(size: 17, weight: .bold))
                            }
                        }
                        Spacer(minLength: 0)
                        if let delta = model.deltaText {
                            Text(delta + " " + model.snapshot.units)
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 6) {
                    WidgetTile(tint: nil) {
                        HStack(spacing: 6) {
                            LoopRing(color: model.loopColor, size: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.snapshot.dosingModeName)
                                    .font(.caption2).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(model.loopAge)
                                    .font(.caption).fontWeight(.bold)
                                    .foregroundStyle(model.loopColor)
                            }
                            if let ratio = model.snapshot.dynamicISFRatio, ratio > 0 {
                                Spacer(minLength: 0)
                                WidgetDynamicISFBadge(ratio: ratio)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        valueTile(
                            title: String(localized: "IOB", comment: "Insulin on board, short"),
                            value: model.iobText,
                            unit: String(localized: "U", comment: "Insulin unit"),
                            tint: .blue
                        )
                        valueTile(
                            title: String(localized: "COB", comment: "Carbs on board, short"),
                            value: "\(model.snapshot.cob)",
                            unit: String(localized: "g", comment: "gram of carbs"),
                            tint: .orange
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 6) {
                if let message = model.snapshot.pumpMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    if let reservoir = model.reservoirText {
                        Image(systemName: "cross.vial.fill").foregroundStyle(model.reservoirColor)
                        Text(reservoir)
                    }
                    if let pod = model.podText {
                        Text("·").foregroundStyle(.secondary)
                        Text(pod).foregroundStyle(model.podColor)
                    }
                    if let badge = model.snapshot.insulinConcentrationBadge {
                        Text(badge)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.blue))
                    }
                }
                Spacer(minLength: 0)
                if let eventual = model.eventualText {
                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    Text(eventual)
                }
            }
            .font(.caption).fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 16)
        }
    }

    private func valueTile(title: String, value: String, unit: String, tint: Color) -> some View {
        WidgetTile(tint: tint) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Same badge as in the app's loop tile: ISF raised (teal) or lowered (orange) by dynamic ISF.
private struct WidgetDynamicISFBadge: View {
    let ratio: Double

    var body: some View {
        let percent = Int(((1 / ratio - 1) * 100).rounded())
        let color: Color = percent > 0 ? .teal : percent < 0 ? .orange : .secondary
        HStack(spacing: 1) {
            Text("ISF")
                .font(.system(size: 10, weight: .bold, design: .rounded))
            Image(systemName: percent > 0 ? "arrow.up" : percent < 0 ? "arrow.down" : "equal")
                .font(.system(size: 9, weight: .heavy))
            if percent != 0 {
                Text("\(abs(percent)) %")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Preview data

extension HeaderWidgetSnapshot {
    static var preview: HeaderWidgetSnapshot {
        HeaderWidgetSnapshot(
            glucose: 123,
            glucoseDate: Date().addingTimeInterval(-120),
            delta: 4,
            trendSymbols: ["arrow.right"],
            units: "mg/dL",
            glucoseColorHex: nil,
            rangeColorHex: "#34C759",
            dosingModeName: "Closed Loop",
            lastLoopDate: Date().addingTimeInterval(-90),
            loopColorFollowsAge: true,
            fixedLoopColorHex: nil,
            loopColorHexes: ["#34C759", "#FFCC00", "#FF3B30"],
            dynamicISFRatio: 1.25,
            iob: 1.25,
            cob: 20,
            eventualGlucose: 110,
            reservoir: 120,
            reservoirIsOver50: false,
            pumpExpiresAt: Date().addingTimeInterval(2 * 86400 + 3 * 3600),
            pumpBatteryPercent: nil,
            pumpMessage: nil,
            insulinConcentrationBadge: "U200",
            updatedAt: Date()
        )
    }
}
