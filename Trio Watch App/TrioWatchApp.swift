import AppIntents

struct TrioWatchApp: AppIntent {
    static var title: LocalizedStringResource { "OpenTrio Watch App" }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
