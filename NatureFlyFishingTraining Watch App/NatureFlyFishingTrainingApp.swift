import SwiftUI

@main
struct NatureFlyFishingTraining_Watch_AppApp: App {

    @StateObject private var viewModel    = WorkoutViewModel()
    @StateObject private var history      = WorkoutHistoryStore.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(history)
                .environmentObject(connectivity)
                .task { await bootstrap() }
        }
    }

    @MainActor
    private func bootstrap() async {
        // Permisos HealthKit: imprescindibles para HR + calorías en tiempo real.
        try? await HealthKitService.shared.requestAuthorization()

        // Si el iPhone envía una sesión completa desde otro flujo, también la guardamos
        // en el historial local del Watch (iCloud KVS lo cubrirá también, pero esto
        // sirve como fallback si iCloud no está configurado).
        WatchConnectivityManager.shared.onSessionReceived = { session in
            Task { @MainActor in
                WorkoutHistoryStore.shared.add(session)
            }
        }

        // Tokens de Strava informativos (el Watch no sube, sólo muestra estado).
        WatchConnectivityManager.shared.onStravaTokensReceived = { access, refresh, expires in
            Task { @MainActor in
                StravaService.shared.storeTokens(
                    accessToken:  access,
                    refreshToken: refresh,
                    expiresAt:    expires
                )
            }
        }
    }
}
