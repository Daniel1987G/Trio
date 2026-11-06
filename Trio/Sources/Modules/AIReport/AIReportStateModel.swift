import CoreData
import Foundation
import SwiftUI
import Swinject
import UIKit

extension AIReport {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!
        @Injected() private var fileStorage: FileStorage!

        @Published var days: Int = AIReport.Config.defaultDays
        /// The local summary for the selected period; nil while it is being computed.
        @Published private(set) var report: TherapyReport?
        @Published private(set) var isPreparing = false
        /// Topics with a request in flight.
        @Published private(set) var analyzing: Set<TherapyReportTopic> = []
        /// The latest evaluation per topic.
        @Published private(set) var saved: [TherapyReportTopic: SavedTherapyReport] = [:]
        @Published var errorMessage: String?
        @Published private(set) var isConfigured = false
        @Published private(set) var providerName = ""
        /// Set when a PDF of the overall report is ready to share.
        @Published var sharePDFURL: URL?

        private var prepareTask: Task<Void, Never>?
        private var analyzeTasks: [TherapyReportTopic: Task<Void, Never>] = [:]

        private var store: MealPhotoSettingsStore { MealPhotoSettingsStore(keychain: keychain) }

        override func subscribe() {
            let stored = UserDefaults.standard.integer(forKey: AIReport.Config.daysKey)
            days = AIReport.Config.dayOptions.contains(stored) ? stored : AIReport.Config.defaultDays
            loadSaved()
            refreshProvider()
            prepare()
        }

        func refreshProvider() {
            isConfigured = store.isConfigured
            providerName = store.provider.displayName
        }

        func setDays(_ value: Int) {
            guard value != days else { return }
            days = value
            UserDefaults.standard.set(value, forKey: AIReport.Config.daysKey)
            prepare()
        }

        // MARK: - Saved evaluations

        private func loadSaved() {
            let list = fileStorage.retrieve(OpenAPS.Monitor.aiReports, as: [SavedTherapyReport].self) ?? []
            var result: [TherapyReportTopic: SavedTherapyReport] = [:]
            for item in list {
                result[item.topic ?? .overall] = item
            }
            // the single evaluation saved before there were topics
            if result[.overall] == nil, let old = fileStorage.retrieve(OpenAPS.Monitor.aiReport, as: SavedTherapyReport.self) {
                result[.overall] = old
            }
            saved = result
        }

        private func keep(_ result: SavedTherapyReport, for topic: TherapyReportTopic) {
            saved[topic] = result
            let list = TherapyReportTopic.allCases.compactMap { saved[$0] }
            fileStorage.save(list, as: OpenAPS.Monitor.aiReports)
        }

        // MARK: - Local summary

        /// Computes the local summary for the selected period (no network).
        func prepare() {
            prepareTask?.cancel()
            report = nil
            isPreparing = true
            let days = days
            let storage = fileStorage!
            let trioSettings = settingsManager.settings
            let preferences = settingsManager.preferences
            prepareTask = Task { [weak self] in
                let context = CoreDataStack.shared.newTaskContext()
                var input = await TherapyReportDataSource.loadInput(days: days, context: context)
                input.basalProfile = TherapyReportDataSource.basalProfile(storage: storage)
                let settings = TherapyReportDataSource.settings(
                    storage: storage,
                    trioSettings: trioSettings,
                    preferences: preferences
                )
                let report = TherapyReportBuilder.build(input, settings: settings)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.report = report
                    self?.isPreparing = false
                }
            }
        }

        // MARK: - AI evaluation

        /// Sends the data for `topic` to the AI provider and keeps the answer.
        func analyze(_ topic: TherapyReportTopic) {
            guard let report, !analyzing.contains(topic) else { return }
            let store = store
            let provider = store.provider
            guard let apiKey = store.apiKey(for: provider) else {
                errorMessage = MealPhotoAnalysisError.missingAPIKey.localizedDescription
                return
            }
            let model = store.model(for: provider)
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            let prompt = report.prompt(for: topic, languageCode: language)
            let days = report.periodDays
            analyzing.insert(topic)
            errorMessage = nil
            analyzeTasks[topic] = Task { [weak self] in
                do {
                    let text = try await AITextClient().complete(
                        prompt: prompt,
                        provider: provider,
                        model: model,
                        apiKey: apiKey
                    )
                    let result = SavedTherapyReport(
                        topic: topic,
                        date: Date(),
                        days: days,
                        provider: provider.displayName,
                        model: model,
                        text: text
                    )
                    await MainActor.run {
                        self?.keep(result, for: topic)
                        self?.analyzing.remove(topic)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                        self?.analyzing.remove(topic)
                    }
                }
            }
        }

        func cancelAnalysis(_ topic: TherapyReportTopic) {
            analyzeTasks[topic]?.cancel()
            analyzeTasks[topic] = nil
            analyzing.remove(topic)
        }

        // MARK: - Overall report (PDF)

        /// The printable report: key figures and every saved evaluation.
        func reportPDF() -> Data {
            TherapyReportDocument.pdf(
                html: TherapyReportDocument.html(report: report, saved: saved, createdAt: Date())
            )
        }

        func printReport() {
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = TherapyReportDocument.fileName(createdAt: Date())
            controller.printInfo = info
            controller.printingItem = reportPDF()
            controller.present(animated: true)
        }

        func prepareShare() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(TherapyReportDocument.fileName(createdAt: Date()))
                .appendingPathExtension("pdf")
            do {
                try reportPDF().write(to: url, options: .atomic)
                sharePDFURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
