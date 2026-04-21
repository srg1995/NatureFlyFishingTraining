import Foundation
import Combine

/// Stub de `StravaService` para el Watch.
///
/// En esta arquitectura el Watch NO se autentica ni sube actividades a Strava —
/// esa responsabilidad vive exclusivamente en el iPhone. Este stub existe sólo
/// para (1) mantener la API que consume `WorkoutViewModel` y (2) reflejar el
/// estado "Strava conectado" propagado desde el iPhone vía `WatchConnectivityManager`.
@MainActor
final class StravaService: ObservableObject {

    static let shared = StravaService()

    @Published private(set) var isAuthenticated: Bool = false

    private init() {}

    /// Llamado por `WatchConnectivityManager` cuando el iPhone informa de una
    /// autenticación exitosa. No se persiste nada — es sólo estado de UI.
    func storeTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
        isAuthenticated = true
    }

    func clearTokens() {
        isAuthenticated = false
    }

    /// En Watch la subida a Strava se delega siempre al iPhone.
    /// Este método se mantiene por compatibilidad pero no realiza ninguna acción.
    func uploadActivity(session workout: WorkoutSession) async throws {
        // no-op — la subida la hace el iPhone tras recibir la sesión por WCSession.
    }
}
