import Combine
import Foundation
import SwiftUI
import Swinject

struct TagCloudView: View {
    var tags: [String]
    var shouldParseToMmolL: Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // a flow layout: each row is as tall as its tallest tag, so a tag that wraps onto two
        // lines no longer overlaps the next row
        TagFlowLayout(spacing: 0) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                self.drawTag(for: tag, isMmolL: shouldParseToMmolL)
                    .padding([.horizontal, .vertical], 3)
            }
        }
    }

    private func drawTag(for textTag: String, isMmolL: Bool) -> some View {
        var colorOfTag: Color {
            switch textTag {
            case textTag where textTag.contains("SMB Delivery Ratio:"):
                return .uam
            case textTag where textTag.contains("Bolus"),
                 textTag where textTag.contains("Swift Oref"): // FIXME: remove this before feat/dev-oref-swift is merged to dev
                return .green
            case textTag where textTag.contains("TDD:"),
                 textTag where textTag.contains("tdd_factor"),
                 textTag where textTag.contains("Sigmoid function"),
                 textTag where textTag.contains("Logarithmic formula"),
                 textTag where textTag.contains("AF:"),
                 textTag where textTag.contains("Autosens/Dynamic Limit:"),
                 textTag where textTag.contains("Dynamic ISF/CR"),
                 textTag where textTag.contains("Basal ratio"),
                 textTag where textTag.contains("SMB Ratio"):
                return .zt
            case textTag where textTag.contains("Middleware:"):
                return .red
            // autoISF tags
            case textTag where textTag.contains("AIMI B30"),
                 textTag where textTag.contains("SMB disabled"):
                return .orange
            case textTag where textTag.hasPrefix("autoISF"),
                 textTag where textTag.contains("-ISF Ratio"),
                 textTag where textTag.contains("final Ratio"),
                 textTag where textTag.contains("eff.iobTH"),
                 textTag where textTag.contains("SMB Del.Ratio"),
                 textTag where textTag.contains("Parabolic Fit"),
                 textTag where textTag.contains("Ratio from TT"):
                return .uam
            case textTag where textTag.contains("SMB Ratio"):
                return .orange
            case textTag where textTag.contains("Smoothing: On"):
                return .gray
            default:
                return .insulin
            }
        }

        let formattedTextTag = formatGlucoseTags(textTag, isMmolL: isMmolL)

        return ZStack {
            Text(formattedTextTag)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .font(.subheadline)
                .fontWeight(.semibold)
                .background(colorOfTag.opacity(colorScheme == .dark ? 0.15 : 0.25))
                .foregroundColor(colorOfTag)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(colorOfTag.opacity(0.4), lineWidth: 2)
                )
        }
    }

    /**
     Converts glucose-related values in the given `tag` string to mmol/L, including ranges (e.g., `ISF: 54→54`), comparisons (e.g., `maxDelta 37 > 20% of BG 95`), and both positive and negative values (e.g., `Dev: -36`).

     - Parameters:
       - tag: The string containing glucose-related values to be converted.
       - isMmolL: A Boolean flag indicating whether to convert values to mmol/L.

     - Returns:
       A string with glucose values converted to mmol/L.

     - Glucose tags handled: `ISF:`, `Target:`, `minPredBG`, `minGuardBG`, `IOBpredBG`, `COBpredBG`, `UAMpredBG`, `Dev:`, `maxDelta`, `BGI`.
     */

    // TODO: Consolidate all mmol parsing methods (in TagCloudView, NightscoutManager and HomeRootView) to one central func
    private func formatGlucoseTags(_ tag: String, isMmolL: Bool) -> String {
        let patterns = [
            "(?:ISF|Target):\\s*-?\\d+\\.?\\d*(?:→-?\\d+\\.?\\d*)+",
            "Dev:\\s*-?\\d+\\.?\\d*",
            "BGI:\\s*-?\\d+\\.?\\d*",
            "Target:\\s*-?\\d+\\.?\\d*",
            "(?:minPredBG|minGuardBG|IOBpredBG|COBpredBG|UAMpredBG)\\s*-?\\d+\\.?\\d*",
            // autoISF: average glucose of the duration window, parabola extremum
            "Avg:\\s*-?\\d+\\.?\\d*",
            "(?:Max|Min) of\\s*-?\\d+\\.?\\d*"
        ]
        let pattern = patterns.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern)

        // Convert only if isMmolL == true; otherwise return original mg/dL string
        func convertToMmolL(_ value: String) -> String {
            if let glucoseValue = Double(value.replacingOccurrences(of: "[^\\d.-]", with: "", options: .regularExpression)) {
                let mmolValue = Decimal(glucoseValue).asMmolL // your mg/dL → mmol/L routine
                return isMmolL ? mmolValue.description : value
            }
            return value
        }

        let matches = regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag))
        var updatedTag = tag

        // Process each match in reverse order
        for match in matches.reversed() {
            guard let range = Range(match.range, in: tag) else { continue }
            let glucoseValueString = String(tag[range])

            if glucoseValueString.contains("→") {
                // -- Handle ISF: X→Y… or Target: X→Y→Z…
                let parts = glucoseValueString.components(separatedBy: ":")
                guard parts.count == 2 else { continue }
                let targetOrISF = parts[0].trimmingCharacters(in: .whitespaces)
                let values = parts[1]
                    .components(separatedBy: "→")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let convertedValues = values.map { convertToMmolL($0) }
                let joined = convertedValues.joined(separator: "→")
                let rebuilt = "\(targetOrISF): \(joined)"
                updatedTag.replaceSubrange(range, with: rebuilt)

            } else if glucoseValueString.starts(with: "Dev:") {
                // -- Handle Dev
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "Dev: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else if glucoseValueString.starts(with: "BGI:") {
                // -- Handle BGI
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "BGI: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else if glucoseValueString.starts(with: "Avg:") ||
                glucoseValueString.starts(with: "Max of") ||
                glucoseValueString.starts(with: "Min of")
            {
                // -- autoISF glucose values: keep the label, convert the number
                let parts = glucoseValueString.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let value = parts.last else { continue }
                let label = parts.dropLast().joined(separator: " ")
                updatedTag.replaceSubrange(range, with: "\(label) \(convertToMmolL(value))")

            } else if glucoseValueString.starts(with: "Target:") {
                // -- Handle Target
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "Target: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else {
                // -- Handle everything else (e.g., "minPredBG 39" etc.)
                let parts = glucoseValueString.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    let metric = parts[0]
                    let value = parts[1]
                    let formattedValue = convertToMmolL(value)
                    let formattedString = "\(metric): \(formattedValue)"
                    updatedTag.replaceSubrange(range, with: formattedString)
                }
            }
        }

        return updatedTag
    }
}

/// Places its subviews left to right and starts a new row when the next one does not fit.
/// A subview wider than the row gets the full width and wraps its text.
struct TagFlowLayout: Layout {
    var spacing: CGFloat = 0

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var height: CGFloat = 0
    }

    private func makeRows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.sizes.append(size)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = makeRows(for: subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        var usedWidth: CGFloat = 0
        for row in rows {
            let rowWidth = row.sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(row.sizes.count - 1, 0))
            usedWidth = max(usedWidth, rowWidth)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in makeRows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}

struct TestTagCloudView: View {
    var body: some View {
        VStack {
            Text("Header").font(.largeTitle)
            TagCloudView(
                tags: ["Ninetendo", "XBox", "PlayStation", "PlayStation 2", "PlayStation 3", "PlayStation 4"],
                shouldParseToMmolL: false
            )
            Text("Some other text")
            Divider()
            Text("Some other cloud")
            TagCloudView(
                tags: ["Apple", "Google", "Amazon", "Microsoft", "Oracle", "Facebook"],
                shouldParseToMmolL: false
            )
        }
    }
}
