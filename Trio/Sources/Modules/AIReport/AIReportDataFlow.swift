enum AIReport {
    enum Config {
        static let daysKey = "aiReport.days"
        static let dayOptions = [3, 7, 14, 30]
        static let defaultDays = 14
    }
}

protocol AIReportProvider: Provider {}
