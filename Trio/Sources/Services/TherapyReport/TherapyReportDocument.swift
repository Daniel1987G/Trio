import Foundation
import UIKit

/// The printable overall report: key figures, tables by hour, the hypo list and every saved AI
/// evaluation, as HTML and as an A4 PDF.
enum TherapyReportDocument {
    static func fileName(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "OpenTrio-" + String(localized: "Report", comment: "PDF file name part") + "-" + formatter.string(from: createdAt)
    }

    // MARK: - HTML

    static func html(
        report: TherapyReport?,
        saved: [TherapyReportTopic: SavedTherapyReport],
        createdAt: Date
    ) -> String {
        var body = ""
        body += "<h1>" + escape(String(localized: "OpenTrio Therapy Report", comment: "PDF title")) + "</h1>"
        var meta = String(localized: "Created \(createdAt.formatted(date: .long, time: .shortened))", comment: "PDF")
        if let report {
            meta += " · " + String(localized: "Period: last \(report.periodDays) days", comment: "PDF")
        }
        body += "<p class=\"meta\">" + escape(meta) + "</p>"

        if let report {
            body += keyFigures(report)
            body += hourTable(report)
            body += hypoTable(report)
        }

        let evaluations = TherapyReportTopic.allCases.compactMap { topic in saved[topic].map { (topic, $0) } }
        if evaluations.isEmpty {
            body += "<p>" +
                escape(String(localized: "No AI evaluation has been made yet.", comment: "PDF")) + "</p>"
        }
        for (topic, evaluation) in evaluations {
            body += "<div class=\"topic\">"
            body += "<h2>" + escape(String(localized: "AI Evaluation: \(topic.title)", comment: "PDF heading")) + "</h2>"
            body += "<p class=\"meta\">" + escape(
                String(
                    localized: "\(evaluation.date.formatted(date: .abbreviated, time: .shortened)) · \(evaluation.days) days · \(evaluation.provider) (\(evaluation.model))",
                    comment: "PDF: date, period, provider and model of an evaluation"
                )
            ) + "</p>"
            body += markdownToHTML(evaluation.text)
            body += "</div>"
        }

        body += "<p class=\"note\">" + escape(String(
            localized: "Key figures calculated by OpenTrio on the iPhone. AI evaluations can be wrong; discuss changes with your diabetes team and change only one setting at a time.",
            comment: "PDF footer"
        )) + "</p>"

        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 10pt; color: #111; }
        h1 { font-size: 18pt; margin: 0 0 4pt; }
        h2 { font-size: 13pt; margin: 16pt 0 4pt; border-bottom: 1px solid #999; padding-bottom: 2pt; }
        h3 { font-size: 11pt; margin: 10pt 0 2pt; }
        h4 { font-size: 10pt; margin: 8pt 0 2pt; }
        p { margin: 3pt 0; }
        ul, ol { margin: 2pt 0 2pt 16pt; padding: 0; }
        table { border-collapse: collapse; width: 100%; margin: 4pt 0; font-size: 8.5pt; }
        th, td { border: 1px solid #bbb; padding: 2pt 4pt; text-align: right; }
        th:first-child, td:first-child { text-align: left; }
        th { background: #eee; }
        .meta { color: #555; font-size: 9pt; }
        .note { color: #555; font-size: 8.5pt; margin-top: 14pt; }
        .topic { page-break-inside: auto; }
        </style></head><body>\(body)</body></html>
        """
    }

    private static func keyFigures(_ report: TherapyReport) -> String {
        let glucose = report.glucose
        let rows: [(String, String)] = [
            (String(localized: "Time in Range 70–180"), percent(glucose.inRangePercent)),
            (String(localized: "Tight Range 70–140", comment: "PDF"), percent(glucose.tightRangePercent)),
            (
                String(localized: "Below 70 / Below 54"),
                "\(percent(glucose.lowPercent + glucose.veryLowPercent)) / \(percent(glucose.veryLowPercent))"
            ),
            (
                String(localized: "Above 180 / Above 250"),
                "\(percent(glucose.highPercent + glucose.veryHighPercent)) / \(percent(glucose.veryHighPercent))"
            ),
            (
                String(localized: "Mean · GMI · CV"),
                "\(number(glucose.meanMgdl)) mg/dL · \(percent(glucose.gmiPercent)) · \(percent(glucose.cvPercent))"
            ),
            (
                String(localized: "Hypoglycemia"),
                String(
                    localized: "\(report.hypoCount) episodes, \(report.severeHypoCount) below 54",
                    comment: "AI report hypo count"
                )
            ),
            (
                String(localized: "Loop"),
                String(
                    localized: "\(percent(report.loop.successPercent)) successful · \(number(report.loop.runsPerDay)) runs/day",
                    comment: "AI report loop figures"
                )
            ),
            (
                String(localized: "Total Daily Dose"),
                String(
                    localized: "\(number(report.insulin.tddMean)) U · basal \(percent(report.insulin.basalPercent)) · SMB \(number(report.insulin.smbPerDay)) U/day",
                    comment: "AI report insulin figures"
                )
            ),
            (String(localized: "CGM Coverage"), percent(glucose.coveragePercent))
        ]
        var html = "<h2>" + escape(String(localized: "Key Figures")) + "</h2><table>"
        for (title, value) in rows {
            html += "<tr><td>\(escape(title))</td><td>\(escape(value))</td></tr>"
        }
        return html + "</table>"
    }

    private static func hourTable(_ report: TherapyReport) -> String {
        guard !report.glucoseByHour.isEmpty else { return "" }
        let basal = Dictionary(report.basalByHour.map { ($0.hour, $0) }, uniquingKeysWith: { first, _ in first })
        var html = "<h2>" + escape(String(localized: "By Time of Day", comment: "PDF heading")) + "</h2><table><tr>"
        let headers = [
            String(localized: "Hour", comment: "PDF table"),
            String(localized: "Median", comment: "PDF table"),
            String(localized: "10–90 %", comment: "PDF table"),
            String(localized: "< 70", comment: "PDF table"),
            String(localized: "> 180", comment: "PDF table"),
            String(localized: "Basal Profile", comment: "PDF table"),
            String(localized: "Basal Delivered", comment: "PDF table"),
            String(localized: "Ratio", comment: "PDF table")
        ]
        html += headers.map { "<th>\(escape($0))</th>" }.joined() + "</tr>"
        for hour in report.glucoseByHour {
            let rate = basal[hour.hour]
            let cells = [
                String(format: "%02d", hour.hour),
                "\(hour.medianMgdl)",
                "\(hour.p10Mgdl)–\(hour.p90Mgdl)",
                percent(hour.lowPercent),
                percent(hour.highPercent),
                rate.map { number($0.profileRate, digits: 2) } ?? "–",
                rate.map { number($0.deliveredRate, digits: 2) } ?? "–",
                rate.map { number($0.ratio, digits: 2) } ?? "–"
            ]
            html += "<tr>" + cells.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }
        return html + "</table>"
    }

    private static func hypoTable(_ report: TherapyReport) -> String {
        guard !report.hypos.isEmpty else { return "" }
        var html = "<h2>" + escape(String(localized: "Hypoglycemia", comment: "PDF heading")) + "</h2><table><tr>"
        let headers = [
            String(localized: "Day", comment: "PDF table"),
            String(localized: "Time", comment: "PDF table"),
            String(localized: "Minutes", comment: "PDF table"),
            String(localized: "Lowest", comment: "PDF table"),
            String(localized: "Bolus 2 h before", comment: "PDF table"),
            String(localized: "SMB 2 h before", comment: "PDF table"),
            String(localized: "Carbs 3 h before", comment: "PDF table"),
            String(localized: "Adjustment", comment: "PDF table")
        ]
        html += headers.map { "<th>\(escape($0))</th>" }.joined() + "</tr>"
        for hypo in report.hypos {
            let cells = [
                "\(hypo.day)",
                hypo.startTime,
                "\(hypo.minutes)",
                "\(hypo.nadirMgdl)",
                number(hypo.manualBolusUnitsPrev2h, digits: 2),
                number(hypo.smbUnitsPrev2h, digits: 2),
                number(hypo.carbsPrev3h),
                hypo.activeAdjustment ?? "–"
            ]
            html += "<tr>" + cells.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }
        return html + "</table>"
    }

    // MARK: - Markdown

    /// Headings, bullet and numbered lists, paragraphs, and inline bold, italic and code.
    static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        var openList: String?

        func closeList() {
            if let list = openList {
                html += "</\(list)>"
                openList = nil
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeList()
                continue
            }
            if line.hasPrefix("#") {
                closeList()
                let level = min(4, max(3, line.prefix { $0 == "#" }.count + 1))
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(inline(title))</h\(level)>"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if openList != "ul" {
                    closeList()
                    html += "<ul>"
                    openList = "ul"
                }
                html += "<li>\(inline(String(line.dropFirst(2))))</li>"
            } else if let dot = line.firstIndex(of: "."), Int(line[..<dot]) != nil,
                      line[line.index(after: dot)...].hasPrefix(" ")
            {
                if openList != "ol" {
                    closeList()
                    html += "<ol>"
                    openList = "ol"
                }
                html += "<li>\(inline(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))</li>"
            } else if line.hasPrefix("---") {
                closeList()
                html += "<hr>"
            } else {
                closeList()
                html += "<p>\(inline(line))</p>"
            }
        }
        closeList()
        return html
    }

    /// Inline Markdown on escaped text: **bold**, *italic*, `code`.
    static func inline(_ text: String) -> String {
        var result = escape(text)
        result = replace(result, pattern: "\\*\\*(.+?)\\*\\*", template: "<b>$1</b>")
        result = replace(result, pattern: "__(.+?)__", template: "<b>$1</b>")
        result = replace(result, pattern: "(?<![*\\w])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![*\\w])", template: "<i>$1</i>")
        result = replace(result, pattern: "`(.+?)`", template: "<code>$1</code>")
        return result
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func number(_ value: Decimal, digits: Int = 1) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }

    private static func percent(_ value: Decimal) -> String {
        number(value) + " %"
    }

    // MARK: - PDF

    /// A4 PDF of `html`. Uses UIKit printing, so call it on the main thread.
    static func pdf(html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 40, dy: 44)), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0 ..< renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
