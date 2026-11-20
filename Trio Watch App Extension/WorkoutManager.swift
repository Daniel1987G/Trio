import Foundation
import HealthKit

/// Runs a workout on the watch (HKWorkoutSession) so OpenTrio knows when exercise starts and ends.
/// The phone then starts the override chosen for the workout and, at the end, the one for
/// afterwards (idea from GlucOS, where the watch workout adjusts the dosing). The workout is
/// saved to Apple Health like one from the Workout app.
@Observable final class WorkoutManager: NSObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case ending
    }

    struct Activity: Identifiable, Hashable {
        let type: HKWorkoutActivityType
        let name: String
        let symbol: String
        var id: UInt { type.rawValue }
    }

    static let activities: [Activity] = [
        Activity(type: .walking, name: String(localized: "Walking"), symbol: "figure.walk"),
        Activity(type: .running, name: String(localized: "Running"), symbol: "figure.run"),
        Activity(type: .cycling, name: String(localized: "Cycling"), symbol: "figure.outdoor.cycle"),
        Activity(type: .hiking, name: String(localized: "Hiking"), symbol: "figure.hiking"),
        Activity(
            type: .traditionalStrengthTraining,
            name: String(localized: "Strength Training"),
            symbol: "figure.strengthtraining.traditional"
        ),
        Activity(type: .other, name: String(localized: "Other"), symbol: "figure.mixed.cardio")
    ]

    private(set) var phase: Phase = .idle
    private(set) var activity: Activity?
    private(set) var startDate: Date?
    private(set) var heartRate: Double?
    private(set) var activeEnergy: Double = 0
    var errorMessage: String?

    /// Called on the main queue when a workout has started or ended.
    @ObservationIgnored var onStarted: ((Activity) -> Void)?
    @ObservationIgnored var onEnded: (() -> Void)?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    var isRunning: Bool { phase == .running || phase == .ending }

    func start(_ activity: Activity) {
        guard phase == .idle else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = String(localized: "Apple Health is not available on this watch.")
            return
        }
        phase = .starting
        errorMessage = nil

        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType()
        ]
        store.requestAuthorization(toShare: share, read: read) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription)
                    return
                }
                self.beginSession(activity)
            }
        }
    }

    func end() {
        guard phase == .running, let session else { return }
        phase = .ending
        session.end()
    }

    private func beginSession(_ activity: Activity) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.type
        configuration.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard success else {
                        self.fail(error?.localizedDescription ?? String(localized: "The workout could not be started."))
                        return
                    }
                    self.activity = activity
                    self.startDate = start
                    self.heartRate = nil
                    self.activeEnergy = 0
                    self.phase = .running
                    self.onStarted?(activity)
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        session = nil
        builder = nil
        phase = .idle
    }

    private func finish(at date: Date) {
        guard let builder else {
            reset()
            return
        }
        builder.endCollection(withEnd: date) { [weak self] _, _ in
            builder.finishWorkout { _, _ in
                DispatchQueue.main.async {
                    self?.reset()
                    self?.onEnded?()
                }
            }
        }
    }

    private func reset() {
        session = nil
        builder = nil
        activity = nil
        startDate = nil
        heartRate = nil
        phase = .idle
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(
        _: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from _: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended else { return }
        DispatchQueue.main.async { self.finish(at: date) }
    }

    func workoutSession(_: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
            if self.phase == .running {
                self.phase = .ending
                self.session?.end()
            }
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        let energyType = HKQuantityType(.activeEnergyBurned)
        let heartRate = collectedTypes.contains(heartRateType) ?
            workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute())) : nil
        let energy = collectedTypes.contains(energyType) ?
            workoutBuilder.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) : nil
        DispatchQueue.main.async {
            if let heartRate { self.heartRate = heartRate }
            if let energy { self.activeEnergy = energy }
        }
    }
}
