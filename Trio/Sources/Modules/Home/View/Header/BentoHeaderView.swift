import SwiftUI

/// Layout of the home screen area above the chart.
enum HomeHeaderStyle: String, CaseIterable, Identifiable {
    /// Tiles of different sizes (glucose, loop, IOB, COB; pod and forecast in the row below).
    case bento
    /// The original pump panel / glucose bobble / loop status layout.
    case classic

    static let storageKey = "home.headerStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bento: return String(localized: "Tiles", comment: "Home header style")
        case .classic: return String(localized: "Classic", comment: "Home header style")
        }
    }
}

enum BentoLayout {
    static let spacing: CGFloat = 8
    static let tileHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 18
}

// MARK: - Tile chrome

/// Rounded tile with a light tint; neutral when `tint` is nil. Works in light and dark mode.
struct BentoTile<Content: View>: View {
    var tint: Color?
    var cornerRadius: CGFloat = BentoLayout.cornerRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.32), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small caption plus a large rounded value.
struct BentoValueTile: View {
    let title: String
    let value: String
    var unit: String?
    var tint: Color?
    var titleColor: Color = .secondary

    var body: some View {
        BentoTile(tint: tint) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let unit {
                        Text(unit)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value + (unit.map { " " + $0 } ?? "")))
    }
}

// MARK: - Glucose

/// The large glucose tile: value coloured by range, trend arrow, delta, age and the CGM state.
struct BentoGlucoseTile: View {
    let timerDate: Date
    let units: GlucoseUnits
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let cgmAvailable: Bool
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    /// The last two readings (oldest first).
    let glucose: [GlucoseStored]
    let cgmStatus: CgmDisplayState?
    let cgmSensorExpiresAt: Date?
    let cgmWarmupEndsAt: Date?

    /// Same freshness gate as the classic bobble and the loop (12 minutes).
    private var freshValue: Int16? {
        guard let last = glucose.last, let date = last.date, Date().timeIntervalSince(date) < 12 * 60 else { return nil }
        return last.glucose
    }

    private var rangeTint: Color {
        guard let value = freshValue.map({ Decimal($0) }) else { return .secondary }
        if value < lowGlucose { return .loopRed }
        if value > highGlucose { return .orange }
        return .loopGreen
    }

    private var valueText: String {
        guard let value = freshValue else { return "– –" }
        if value == 400 { return "HIGH" }
        return units == .mgdL ? Decimal(value).description : Decimal(value).formattedAsMmolL
    }

    private var deltaText: String? {
        guard glucose.count >= 2, freshValue != nil else { return nil }
        var last = Decimal(glucose.last?.glucose ?? 0)
        var previous = Decimal(glucose.first?.glucose ?? 0)
        if units == .mmolL {
            last = last.asMmolL
            previous = previous.asMmolL
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = units == .mmolL ? 1 : 0
        formatter.minimumFractionDigits = units == .mmolL ? 1 : 0
        formatter.positivePrefix = "+"
        return formatter.string(from: (last - previous) as NSNumber)
    }

    /// SF Symbols for the CGM direction; double arrows repeat the symbol.
    private var trendSymbols: [String] {
        switch glucose.last?.directionEnum {
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

    private var isInWarmup: Bool {
        let message = cgmStatus?.localizedMessage.lowercased() ?? ""
        return message.contains("warming up") || message.contains("warmup")
    }

    /// One line about the sensor when it matters: a status to act on, warmup, or the last 48 h.
    private var sensorNote: (text: String, color: Color)? {
        if let status = cgmStatus, status.status != .normal {
            return (status.localizedMessage.replacingOccurrences(of: "\n", with: " "), status.status.color)
        }
        if isInWarmup {
            let text = cgmWarmupEndsAt.map { SensorRemainingTimeFormatter.format(until: $0) }
                ?? String(localized: "Warming up", comment: "CGM sensor warmup")
            return (text, .orange)
        }
        if let expiresAt = cgmSensorExpiresAt, expiresAt.timeIntervalSinceNow <= 48 * 60 * 60 {
            return (
                SensorRemainingTimeFormatter.format(until: expiresAt),
                expiresAt.timeIntervalSinceNow <= 12 * 60 * 60 ? .loopRed : .orange
            )
        }
        return nil
    }

    var body: some View {
        BentoTile(tint: cgmAvailable ? rangeTint : nil, cornerRadius: 22) {
            if !cgmAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.title2)
                    Text("Add CGM").font(.callout).fontWeight(.bold)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Add CGM"))
                .accessibilityAddTraits(.isButton)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        freshValue == nil
                            ? String(localized: "Glucose", comment: "Bento glucose tile title")
                            : String(localized: "Glucose", comment: "Bento glucose tile title") + " · " +
                            TimeAgoFormatter.minutesAgo(from: glucose.last?.date)
                    )
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    if freshValue == nil, let status = cgmStatus, !status.imageName.isEmpty {
                        Label(status.localizedMessage.replacingOccurrences(of: "\n", with: " "), systemImage: status.imageName)
                            .font(.callout).fontWeight(.bold)
                            .foregroundStyle(status.status.color)
                            .lineLimit(2)
                    } else {
                        HStack(alignment: .center, spacing: 6) {
                            Text(valueText)
                                .font(.system(size: 54, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(
                                    freshValue.map {
                                        CurrentGlucoseView.glucoseColor(
                                            for: $0,
                                            lowGlucose: lowGlucose,
                                            highGlucose: highGlucose,
                                            targetGlucose: currentGlucoseTarget,
                                            scheme: glucoseColorScheme
                                        )
                                    } ?? Color.secondary
                                )
                            if freshValue != nil {
                                HStack(spacing: -4) {
                                    ForEach(Array(trendSymbols.enumerated()), id: \.offset) { _, symbol in
                                        Image(systemName: symbol)
                                    }
                                }
                                .font(.system(size: 22, weight: .bold))
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    if let note = sensorNote {
                        Text(note.text)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(note.color)
                            .lineLimit(1)
                    } else if let delta = deltaText {
                        Text(delta + " " + units.rawValue)
                            .font(.callout).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityText))
            }
        }
    }

    private var accessibilityText: String {
        guard freshValue != nil else {
            return cgmStatus?.localizedMessage.replacingOccurrences(of: "\n", with: " ")
                ?? String(localized: "Glucose unavailable", comment: "Accessibility: no fresh glucose")
        }
        var parts = [String(localized: "Glucose", comment: "Accessibility: glucose label") + " \(valueText) \(units.rawValue)"]
        if let delta = deltaText {
            parts.append(String(localized: "delta", comment: "Accessibility: glucose delta") + " \(delta)")
        }
        parts.append(TimeAgoFormatter.minutesAgoAccessible(from: glucose.last?.date))
        if let note = sensorNote { parts.append(note.text) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Pod / pump

/// Wide tile in the row below: reservoir, insulin concentration, remaining pod time or battery.
struct BentoPumpTile: View {
    let reservoir: Decimal?
    let expiresAtDate: Date?
    let activatedAtDate: Date?
    let timerDate: Date
    let pumpStatusHighlightMessage: String?
    let battery: [OpenAPS_Battery]
    let insulinConcentration: InsulinConcentration
    let insulinConcentrationSyncPending: Bool

    private var reservoirText: String? {
        guard let reservoir else { return nil }
        if reservoir == 0xDEAD_BEEF { return PumpView.unknownReservoirLabel(insulinConcentration) }
        return (Formatter.integerFormatter.string(from: reservoir as NSNumber) ?? "0") +
            String(localized: " U", comment: "Insulin unit")
    }

    private var showsBadge: Bool { !insulinConcentration.isStandard || insulinConcentrationSyncPending }

    var body: some View {
        BentoTile(tint: nil, cornerRadius: 16) {
            HStack(spacing: 8) {
                if let message = pumpStatusHighlightMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message.replacingOccurrences(of: "\n", with: " "))
                        .font(.footnote).fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if reservoir == nil, battery.isEmpty {
                    Image(systemName: "plus.circle.fill")
                    Text("Add pump").font(.footnote).fontWeight(.bold)
                } else {
                    if let reservoirText {
                        Image(systemName: "cross.vial.fill")
                            .foregroundStyle(PumpView.reservoirColor(reservoir))
                        Text(reservoirText)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    if let expiresAtDate {
                        Text("·").foregroundStyle(.secondary)
                        Text(PumpView.remainingTimeString(time: expiresAtDate.timeIntervalSince(timerDate)))
                            .font(.footnote).fontWeight(.semibold)
                            .foregroundStyle(
                                PumpView.timerColor(activatedAt: activatedAtDate, expiresAt: expiresAtDate, timerDate: timerDate)
                            )
                            .lineLimit(1)
                    } else if let first = battery.first, first.display == true {
                        Text("·").foregroundStyle(.secondary)
                        Image(systemName: "battery.100").font(.footnote)
                        Text("\(Formatter.integerFormatter.string(for: first.percent) ?? "–") %")
                            .font(.footnote).fontWeight(.semibold)
                    }
                    Spacer(minLength: 0)
                    if showsBadge {
                        Text("U\(insulinConcentration.rawValue)" + (insulinConcentrationSyncPending ? "!" : ""))
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(insulinConcentrationSyncPending ? Color.red : Color.insulin))
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// Shows whether dynamic ISF currently raises or lowers the ISF. oref divides the profile ISF by
/// the ratio: above 1 the ISF is lowered (more insulin per mg/dL), below 1 it is raised.
struct DynamicISFBadge: View {
    let ratio: Decimal

    /// Change of the ISF against the profile in percent (positive = raised).
    var changePercent: Int {
        let value = (1 / NSDecimalNumber(decimal: ratio).doubleValue - 1) * 100
        return Int(value.rounded())
    }

    private enum Direction { case raised, lowered, unchanged }

    private var direction: Direction {
        if changePercent > 0 { return .raised }
        if changePercent < 0 { return .lowered }
        return .unchanged
    }

    private var symbol: String {
        switch direction {
        case .raised: return "arrow.up"
        case .lowered: return "arrow.down"
        case .unchanged: return "equal"
        }
    }

    private var color: Color {
        switch direction {
        case .raised: return .teal
        case .lowered: return .orange
        case .unchanged: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Text("ISF")
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
            if direction != .unchanged {
                Text("\(abs(changePercent)) %")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch direction {
        case .raised:
            return String(
                format: String(localized: "Dynamic ISF raises the ISF by %d percent", comment: "Accessibility: dynamic ISF"),
                abs(changePercent)
            )
        case .lowered:
            return String(
                format: String(localized: "Dynamic ISF lowers the ISF by %d percent", comment: "Accessibility: dynamic ISF"),
                abs(changePercent)
            )
        case .unchanged:
            return String(localized: "Dynamic ISF leaves the ISF unchanged", comment: "Accessibility: dynamic ISF")
        }
    }
}
