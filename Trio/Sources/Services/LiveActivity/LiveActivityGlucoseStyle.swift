import Foundation
import SwiftUI
import UIKit

enum LiveActivityFontSize: String, Codable, Hashable, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var basePointSize: CGFloat {
        switch self {
        case .small:
            return 30
        case .medium:
            return 40
        case .large:
            return 50
        case .extraLarge:
            return 64
        }
    }

    var verticalPadding: CGFloat? {
        self == .extraLarge ? 0 : nil
    }

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .small:
            return .title2
        case .medium:
            return .title1
        case .extraLarge,
             .large:
            return .largeTitle
        }
    }

    var displayName: String {
        switch self {
        case .small:
            return String(localized: "Small", comment: "Live Activity glucose reading font size")
        case .medium:
            return String(localized: "Medium", comment: "Live Activity glucose reading font size")
        case .large:
            return String(localized: "Large", comment: "Live Activity glucose reading font size")
        case .extraLarge:
            return String(localized: "Extra Large", comment: "Live Activity glucose reading font size")
        }
    }
}

extension LiveActivityAttributes.SimpleViewStyle {
    var glucoseFont: Font {
        let scaled = UIFontMetrics(forTextStyle: fontSize.uiTextStyle).scaledValue(for: fontSize.basePointSize)
        return .system(size: scaled, weight: .bold)
    }
}

/// User-chosen colours for the Live Activity elements, as "#RRGGBB" (or "#RRGGBBAA").
/// `nil` keeps the built-in look of that element.
struct LiveActivityColors: Codable, Hashable {
    /// Glucose reading; nil = coloured by range (glucose colour scheme).
    var glucose: String?
    /// Trend arrow and change; nil = as before.
    var trend: String?
    var iob: String?
    var cob: String?
    var tdd: String?
    /// Time of the last reading.
    var updated: String?
    /// Captions such as "IOB", "COB", "Updated".
    var labels: String?
    /// Readings in the chart; nil = coloured by range.
    var chartPoints: String?
    /// Background of the lock-screen banner; nil = system default.
    var background: String?

    static let `default` = LiveActivityColors()

    var isDefault: Bool { self == .default }

    enum Element: String, CaseIterable, Identifiable {
        case glucose
        case trend
        case iob
        case cob
        case tdd
        case updated
        case labels
        case chartPoints
        case background

        var id: String { rawValue }

        var keyPath: WritableKeyPath<LiveActivityColors, String?> {
            switch self {
            case .glucose: return \.glucose
            case .trend: return \.trend
            case .iob: return \.iob
            case .cob: return \.cob
            case .tdd: return \.tdd
            case .updated: return \.updated
            case .labels: return \.labels
            case .chartPoints: return \.chartPoints
            case .background: return \.background
            }
        }

        var displayName: String {
            switch self {
            case .glucose: return String(localized: "Glucose Reading", comment: "Live Activity colour element")
            case .trend: return String(localized: "Trend and Change", comment: "Live Activity colour element")
            case .iob: return String(localized: "IOB", comment: "Live Activity colour element")
            case .cob: return String(localized: "COB", comment: "Live Activity colour element")
            case .tdd: return String(localized: "TDD", comment: "Live Activity colour element")
            case .updated: return String(localized: "Time of Reading", comment: "Live Activity colour element")
            case .labels: return String(localized: "Captions", comment: "Live Activity colour element")
            case .chartPoints: return String(localized: "Chart Readings", comment: "Live Activity colour element")
            case .background: return String(localized: "Background", comment: "Live Activity colour element")
            }
        }

        /// What the element shows while no own colour is chosen.
        var defaultDescription: String {
            switch self {
            case .chartPoints,
                 .glucose: return String(localized: "By glucose range", comment: "Live Activity default colour")
            case .background: return String(localized: "System", comment: "Live Activity default colour")
            default: return String(localized: "Standard", comment: "Live Activity default colour")
            }
        }
    }

    subscript(element: Element) -> String? {
        get { self[keyPath: element.keyPath] }
        set { self[keyPath: element.keyPath] = newValue }
    }

    /// Colour for an element, or nil when the built-in look applies.
    func color(_ element: Element) -> Color? {
        self[element].flatMap(Color.init(liveActivityHex:))
    }
}

extension Color {
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    init?(liveActivityHex hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8, let value = UInt64(string, radix: 16) else { return nil }
        let hasAlpha = string.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// "#RRGGBB" (or "#RRGGBBAA" when not opaque), for storing a picked colour.
    var liveActivityHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a < 0.999 ? rgb + String(format: "%02X", byte(a)) : rgb
    }
}
