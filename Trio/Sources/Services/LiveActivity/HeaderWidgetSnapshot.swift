import Foundation
import SwiftUI
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// What the home header shows, handed from the app to the header widget (home screen and CarPlay)
/// through the shared app group. Colours are resolved in the app so the widget matches the header.
struct HeaderWidgetSnapshot: Codable, Equatable {
    /// Latest reading in mg/dL; nil when there is none.
    var glucose: Int?
    var glucoseDate: Date?
    /// Change against the previous reading in mg/dL.
    var delta: Int?
    /// SF Symbols for the trend (two for double arrows).
    var trendSymbols: [String]
    /// "mg/dL" or "mmol/L".
    var units: String
    /// Colour of the reading as in the header ("#RRGGBB").
    var glucoseColorHex: String?
    /// Colour of the glucose tile tint (range colour).
    var rangeColorHex: String?

    var dosingModeName: String
    var lastLoopDate: Date?
    /// Loop ring colour follows the loop age (closed loop with an enacted determination);
    /// otherwise `fixedLoopColorHex` applies.
    var loopColorFollowsAge: Bool
    var fixedLoopColorHex: String?
    /// The app's loop colours (fresh, late, overdue).
    var loopColorHexes: [String]

    /// oref's sensitivity ratio while dynamic ISF is on (ISF = profile ISF / ratio); nil when off.
    var dynamicISFRatio: Double?

    var iob: Double
    var cob: Int
    /// Eventual glucose in mg/dL.
    var eventualGlucose: Int?

    /// Units left; nil when unknown. `reservoirIsOver50` for the pod's "50+" reading.
    var reservoir: Double?
    var reservoirIsOver50: Bool
    var pumpExpiresAt: Date?
    var pumpBatteryPercent: Int?
    var pumpMessage: String?
    var insulinConcentrationBadge: String?

    var updatedAt: Date

    static let widgetKind = "OpenTrioHeaderWidget"
    /// Readings older than this are shown as missing, as in the header.
    static let glucoseFreshness: TimeInterval = 12 * 60

    var isMmol: Bool { units == "mmol/L" }

    func formattedGlucose(_ mgdl: Int) -> String {
        if !isMmol { return mgdl == 400 ? "HIGH" : "\(mgdl)" }
        return String(format: "%.1f", Double(mgdl) / 18.0182)
    }

    func formattedDelta(_ mgdl: Int) -> String {
        let sign = mgdl >= 0 ? "+" : "−"
        if !isMmol { return sign + "\(abs(mgdl))" }
        return sign + String(format: "%.1f", Double(abs(mgdl)) / 18.0182)
    }
}

enum HeaderWidgetStore {
    private static let key = "openTrio.headerWidgetSnapshot"

    /// The app group shared by the app and the widget extension (Info.plist "OpenTrioWidgetAppGroup").
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "OpenTrioWidgetAppGroup") as? String,
              !group.isEmpty, !group.contains("$(")
        else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func load() -> HeaderWidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HeaderWidgetSnapshot.self, from: data)
    }

    /// Saves the snapshot and asks WidgetKit to redraw when something changed.
    static func save(_ snapshot: HeaderWidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        if let old = defaults.data(forKey: key),
           var previous = try? JSONDecoder().decode(HeaderWidgetSnapshot.self, from: old)
        {
            // only the content counts, not the time of writing
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return }
        }
        defaults.set(data, forKey: key)
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: HeaderWidgetSnapshot.widgetKind)
        #endif
    }
}
