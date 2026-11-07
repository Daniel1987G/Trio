import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Data

/// What the watch app last received from the phone (written by `WatchState.saveComplicationSnapshot`).
struct GlucoseComplicationData {
    var glucose: String
    var color: Color
    /// oref direction ("Flat", "FortyFiveUp", …).
    var trend: String
    var delta: String
    var iob: String
    var cob: String
    var glucoseDate: Date?

    static let freshness: TimeInterval = 12 * 60

    static var defaults: UserDefaults? {
        // org.nightscout.<TEAM>.trio.watchkitapp.TrioWatchComplication → group.org.nightscout.<TEAM>.trio.trio-app-group
        let parts = (Bundle.main.bundleIdentifier ?? "").split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return UserDefaults(suiteName: "group.org.nightscout.\(parts[2]).trio.trio-app-group")
    }

    static func load() -> GlucoseComplicationData? {
        guard let raw = defaults?.dictionary(forKey: "openTrio.complication") else { return nil }
        let timestamp = raw["glucoseDate"] as? TimeInterval ?? 0
        return GlucoseComplicationData(
            glucose: raw["glucose"] as? String ?? "--",
            color: Color(complicationHex: raw["colorHex"] as? String ?? "") ?? .primary,
            trend: raw["trend"] as? String ?? "",
            delta: raw["delta"] as? String ?? "",
            iob: raw["iob"] as? String ?? "",
            cob: raw["cob"] as? String ?? "",
            glucoseDate: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        )
    }

    static let placeholder = GlucoseComplicationData(
        glucose: "123",
        color: .green,
        trend: "Flat",
        delta: "+4",
        iob: "1.25",
        cob: "20",
        glucoseDate: Date().addingTimeInterval(-120)
    )

    func isFresh(at date: Date) -> Bool {
        guard let glucoseDate else { return false }
        return date.timeIntervalSince(glucoseDate) < Self.freshness
    }

    func minutes(at date: Date) -> Int? {
        glucoseDate.map { max(0, Int(date.timeIntervalSince($0) / 60)) }
    }

    var trendSymbol: String? {
        switch trend {
        case "DoubleUp",
             "TripleUp": return "arrow.up.to.line"
        case "SingleUp": return "arrow.up"
        case "FortyFiveUp": return "arrow.up.right"
        case "Flat": return "arrow.right"
        case "FortyFiveDown": return "arrow.down.right"
        case "SingleDown": return "arrow.down"
        case "DoubleDown",
             "TripleDown": return "arrow.down.to.line"
        default: return nil
        }
    }
}

private extension Color {
    init?(complicationHex hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt64(string, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Timeline

/// What the rectangular complication shows; chosen when editing the watch face.
enum GlucoseComplicationLayout: String, AppEnum {
    case standard
    case glucoseOnly

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Layout" }

    static var caseDisplayRepresentations: [GlucoseComplicationLayout: DisplayRepresentation] {
        [
            .standard: "Glucose with IOB and COB",
            .glucoseOnly: "Glucose only (large)"
        ]
    }
}

struct GlucoseComplicationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "OpenTrio Glucose" }
    static var description: IntentDescription { "Choose what the large complication shows." }

    @Parameter(title: "Layout", default: .standard) var layout: GlucoseComplicationLayout

    init() {}

    init(layout: GlucoseComplicationLayout) {
        self.layout = layout
    }
}

struct GlucoseComplicationEntry: TimelineEntry {
    let date: Date
    let data: GlucoseComplicationData?
    var layout: GlucoseComplicationLayout = .standard
}

struct GlucoseComplicationProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> GlucoseComplicationEntry {
        GlucoseComplicationEntry(date: Date(), data: .placeholder)
    }

    func snapshot(for configuration: GlucoseComplicationIntent, in context: Context) async -> GlucoseComplicationEntry {
        GlucoseComplicationEntry(
            date: Date(),
            data: GlucoseComplicationData.load() ?? (context.isPreview ? .placeholder : nil),
            layout: configuration.layout
        )
    }

    /// One entry per minute for 15 minutes: the age advances and a missing reading turns grey without
    /// the watch app; the watch app reloads the timeline with every new reading.
    func timeline(for configuration: GlucoseComplicationIntent, in _: Context) async -> Timeline<GlucoseComplicationEntry> {
        let data = GlucoseComplicationData.load()
        let now = Date()
        let start = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        var entries = [GlucoseComplicationEntry(date: now, data: data, layout: configuration.layout)]
        for minute in 1 ... 15 {
            entries.append(GlucoseComplicationEntry(
                date: start.addingTimeInterval(Double(minute) * 60),
                data: data,
                layout: configuration.layout
            ))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    #if os(watchOS)
        /// watchOS offers configurable complications as ready-made choices in the face editor.
        func recommendations() -> [AppIntentRecommendation<GlucoseComplicationIntent>] {
            [
                AppIntentRecommendation(
                    intent: GlucoseComplicationIntent(layout: .standard),
                    description: Text("Glucose with IOB and COB")
                ),
                AppIntentRecommendation(
                    intent: GlucoseComplicationIntent(layout: .glucoseOnly),
                    description: Text("Glucose only (large)")
                )
            ]
        }
    #endif
}

// MARK: - Views

struct GlucoseComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseComplicationEntry

    private var data: GlucoseComplicationData { entry.data ?? .placeholder }
    private var hasData: Bool { entry.data != nil }
    private var fresh: Bool { hasData && data.isFresh(at: entry.date) }
    private var value: String { fresh ? data.glucose : "--" }
    private var color: Color { fresh ? data.color : .secondary }
    private var age: String {
        guard hasData, let minutes = data.minutes(at: entry.date) else { return "" }
        return minutes > 99 ? ">99′" : "\(minutes)′"
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular:
            if entry.layout == .glucoseOnly { rectangularLarge } else { rectangular }
        case .accessoryInline: inline
        #if os(watchOS)
            case .accessoryCorner: corner
        #endif
        default: circular
        }
    }

    private var arrow: some View {
        Group {
            if fresh, let symbol = data.trendSymbol {
                Image(systemName: symbol)
            }
        }
    }

    /// Reading in the middle, trend arrow above, change below.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                arrow
                    .font(.system(size: 10, weight: .bold))
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(fresh ? data.delta : age)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(2)
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
    }

    /// Reading, arrow and change on the first line; IOB, COB and age below.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                arrow
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                if fresh {
                    Text(data.delta)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 0)
                Text(age)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label {
                    Text(data.iob + " U")
                } icon: {
                    Image(systemName: "drop.fill")
                }
                .foregroundStyle(.blue)
                Label {
                    Text(data.cob + " g")
                } icon: {
                    Image(systemName: "fork.knife")
                }
                .foregroundStyle(.orange)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
    }

    /// The whole area for the reading: big value and arrow, change and age on the right.
    private var rectangularLarge: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(value)
                .font(.system(size: 50, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) {
                arrow
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(color)
                if fresh {
                    Text(data.delta)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                Text(age)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
    }

    /// One line above the time, e.g. "123 → +4 · 3′".
    private var inline: some View {
        let parts = [value, fresh ? data.delta : "", age].filter { !$0.isEmpty }
        return Group {
            if fresh, let symbol = data.trendSymbol {
                Text("\(Image(systemName: symbol)) ") + Text(parts.joined(separator: " · "))
            } else {
                Text(parts.joined(separator: " · "))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    #if os(watchOS)
        /// Reading in the corner, change and age along the bezel.
        private var corner: some View {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .widgetCurvesContent()
                .widgetLabel {
                    Text([fresh ? data.delta : "", age].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                .containerBackground(for: .widget) { Color.clear }
        }
    #endif
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

// MARK: - Widget

struct GlucoseComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "OpenTrioGlucoseComplication",
            intent: GlucoseComplicationIntent.self,
            provider: GlucoseComplicationProvider()
        ) { entry in
            GlucoseComplicationView(entry: entry)
        }
        .configurationDisplayName("OpenTrio Glucose")
        .description("Glucose, trend and change; IOB and COB in the large version.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
        #else
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}
