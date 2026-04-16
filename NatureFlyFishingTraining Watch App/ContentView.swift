import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel

    var body: some View {
        Group {
            switch viewModel.workoutState {
            case .idle:
                NavigationStack {
                    SetupView()
                }
            case .running, .paused:
                WorkoutView()
            case .finished:
                NavigationStack {
                    SummaryView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.workoutState)
    }
}
