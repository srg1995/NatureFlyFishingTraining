import SwiftUI

@main
struct NatureFlyFishingTrainingApp: App {

    @StateObject private var viewModel    = WorkoutViewModel()
    @StateObject private var history      = WorkoutHistoryStore.shared
    @StateObject private var strava       = StravaService.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(history)
                .environmentObject(strava)
                .environmentObject(connectivity)
                .task { await bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await StravaService.shared.flushPending() }
                    }
                }
        }
    }

    // MARK: - Bootstrap

    @MainActor
    private func bootstrap() async {
        // 1. Permisos de HealthKit (silencioso si ya concedidos).
        try? await HealthKitService.shared.requestAuthorization()

        // 2. Cableado: cuando llega una sesión desde el Watch, la gestiona el ViewModel.
        WatchConnectivityManager.shared.onSessionReceived = { [weak viewModel] session in
            Task { @MainActor in
                viewModel?.ingestRemoteCompletedSession(session)
            }
        }

        // 3. Reflejar estado en vivo del Watch en la UI del iPhone.
        WatchConnectivityManager.shared.onLiveStateReceived = { [weak viewModel] state in
            Task { @MainActor in
                viewModel?.mirrorLiveState(state)
            }
        }

        // 4. Reintentar subidas pendientes a Strava al arrancar.
        await StravaService.shared.flushPending()
    }
}
