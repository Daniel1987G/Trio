import SwiftUI

/// Start a workout, or show and end the running one. Starting and ending also switch the
/// overrides chosen for workouts in OpenTrio on the iPhone.
struct WorkoutView: View {
    let state: WatchState

    private var workout: WorkoutManager { state.workout }

    var body: some View {
        List {
            if workout.isRunning {
                runningSection
            } else {
                if let error = workout.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                ForEach(WorkoutManager.activities) { activity in
                    Button {
                        workout.start(activity)
                    } label: {
                        Label(activity.name, systemImage: activity.symbol)
                    }
                    .disabled(workout.phase != .idle)
                }
                Text("Starts the workout override set in OpenTrio on the iPhone; ending it starts the one for afterwards.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Workout")
    }

    @ViewBuilder private var runningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let activity = workout.activity {
                Label(activity.name, systemImage: activity.symbol)
                    .font(.headline)
            }
            if let start = workout.startDate {
                Text(start, style: .timer)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.loopGreen)
            }
            HStack(spacing: 10) {
                if let heartRate = workout.heartRate {
                    Label("\(Int(heartRate.rounded()))", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                }
                if workout.activeEnergy > 0 {
                    Text("\(Int(workout.activeEnergy.rounded())) kcal")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .listRowBackground(Color.clear)

        Button {
            workout.end()
        } label: {
            Label("End Workout", systemImage: "stop.fill")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.loopRed.clipShape(RoundedRectangle(cornerRadius: 8)))
        .disabled(workout.phase != .running)
    }
}
