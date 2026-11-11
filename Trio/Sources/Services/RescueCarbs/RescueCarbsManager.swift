import Foundation
import Swinject

/// What the rescue carbs button did, for the confirmation shown to the user.
struct RescueCarbsResult: Equatable {
    let grams: Int
    enum TempTargetOutcome: Equatable {
        case started(target: Int, minutes: Int)
        /// A temp target at least as high was already running.
        case keptActive
        case disabled
        case failed(String)
    }

    let tempTarget: TempTargetOutcome
}

protocol RescueCarbsManager: AnyObject {
    /// Logs rescue carbs (never as a carb entry, so they stay out of COB) and starts the configured temp target.
    func logRescueCarbs() async -> RescueCarbsResult
    /// The latest rescue carbs within the last 2 hours.
    func recentEntry() -> RescueCarbEntry?
}

final class BaseRescueCarbsManager: RescueCarbsManager, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var settingsManager: SettingsManager!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func recentEntry() -> RescueCarbEntry? {
        RescueCarbs.recent(in: log(), now: Date())
    }

    private func log() -> [RescueCarbEntry] {
        storage.retrieve(OpenAPS.Monitor.rescueCarbs, as: [RescueCarbEntry].self) ?? []
    }

    func logRescueCarbs() async -> RescueCarbsResult {
        let grams = RescueCarbSettings.grams
        let now = Date()

        // 1. Record. Deliberately not a CarbEntryStored: those feed COB and the bolus calculator.
        storage.save(RescueCarbs.appending(RescueCarbEntry(date: now, grams: grams), to: log()), as: OpenAPS.Monitor.rescueCarbs)
        debug(.service, "Rescue carbs logged: \(grams) g")
        let nightscout = nightscoutManager
        Task.detached(priority: .low) {
            await nightscout?.uploadNoteTreatment(note: RescueCarbs.noteText(grams: grams))
        }

        // 2. Temp target, so the algorithm does not chase the rise with insulin.
        guard RescueCarbSettings.tempTargetEnabled else {
            return RescueCarbsResult(grams: grams, tempTarget: .disabled)
        }
        let target = RescueCarbSettings.tempTarget
        let minutes = RescueCarbSettings.duration

        let active = tempTargetsStorage.current()
        if RescueCarbs.keepsActiveTempTarget(activeTarget: active?.targetBottom, rescueTarget: Decimal(target)) {
            debug(.service, "Rescue carbs: kept the active temp target \(active?.targetBottom?.description ?? "")")
            return RescueCarbsResult(grams: grams, tempTarget: .keptActive)
        }

        // Stored disabled, then activated through the manager (ends what runs, stamps the start, runs oref),
        // like a temp target from Adjustments or remote control.
        let tempTarget = TempTarget(
            name: String(localized: "Rescue Carbs", comment: "Temp target name for rescue carbs"),
            createdAt: now,
            targetTop: Decimal(target),
            targetBottom: Decimal(target),
            duration: Decimal(minutes),
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: false,
            enabled: false,
            halfBasalTarget: settingsManager.preferences.halfBasalExerciseTarget
        )
        do {
            let objectID = try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget)
            try await adjustmentManager.activateTempTarget(.objectID(objectID), source: .app, waitForUpload: false)
            debug(.service, "Rescue carbs: temp target \(target) mg/dL for \(minutes) min started")
            return RescueCarbsResult(grams: grams, tempTarget: .started(target: target, minutes: minutes))
        } catch {
            debug(.service, "Rescue carbs: temp target failed: \(error)")
            return RescueCarbsResult(grams: grams, tempTarget: .failed(error.localizedDescription))
        }
    }
}
