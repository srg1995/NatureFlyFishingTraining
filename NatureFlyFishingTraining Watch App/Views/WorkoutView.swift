import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel
    @State private var selectedPage = 0

    var body: some View {
        TabView(selection: $selectedPage) {
            TimerPageView()
                .tag(0)
            CountersPageView()
                .tag(1)
        }
        .tabViewStyle(.page)
    }
}
