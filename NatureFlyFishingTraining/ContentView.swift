import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.workoutState {
                case .idle:
                    SetupView()
                case .running, .paused:
                    WorkoutView()
                case .finished:
                    SummaryView()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.workoutState)
        }
    }
}
