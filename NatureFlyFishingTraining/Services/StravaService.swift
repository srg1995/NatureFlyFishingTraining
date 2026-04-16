import Foundation

// MARK: - Models

private struct StravaTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
}

private struct StravaRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt    = "expires_at"
    }
}

enum StravaError: LocalizedError {
    case notAuthenticated
    case tokenRefreshFailed
    case uploadFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:    return "Strava no conectado. Autentica desde tu iPhone."
        case .tokenRefreshFailed:  return "No se pudo renovar el token de Strava."
        case .uploadFailed(let c): return "Error al subir a Strava (HTTP \(c))."
        case .invalidResponse:     return "Respuesta inválida de Strava."
        }
    }
}

// MARK: - Service

class StravaService {

    // MARK: Configuración — rellena con tus credenciales de Strava API
    private let clientID     = "YOUR_STRAVA_CLIENT_ID"
    private let clientSecret = "YOUR_STRAVA_CLIENT_SECRET"

    private let baseURL  = "https://www.strava.com/api/v3"
    private let tokenURL = "https://www.strava.com/oauth/token"

    private let tokensKey = "com.natureflyfish.strava.tokens"

    // MARK: - Token Storage

    private var storedTokens: StravaTokens? {
        get {
            guard let data = UserDefaults.standard.data(forKey: tokensKey) else { return nil }
            return try? JSONDecoder().decode(StravaTokens.self, from: data)
        }
        set {
            if let tokens = newValue,
               let data = try? JSONEncoder().encode(tokens) {
                UserDefaults.standard.set(data, forKey: tokensKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokensKey)
            }
        }
    }

    var isAuthenticated: Bool { storedTokens != nil }

    // Llamado desde WatchConnectivity cuando el iPhone envía tokens
    func storeTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
        storedTokens = StravaTokens(accessToken: accessToken,
                                    refreshToken: refreshToken,
                                    expiresAt: expiresAt)
    }

    func clearTokens() {
        storedTokens = nil
    }

    // MARK: - Upload Activity

    func uploadActivity(session: WorkoutSession) async throws {
        let token = try await validAccessToken()

        guard let url = URL(string: "\(baseURL)/activities") else { return }

        let formatter = ISO8601DateFormatter()
        let startStr = formatter.string(from: session.startDate)
        let notes = "🎣 Nature Fly Fishing Competition\nPeces T: \(session.pecesT)\nPeces M: \(session.pecesM)\nTotal: \(session.totalPeces)"

        let body: [String: Any] = [
            "name":              "Nature Fly Fishing Competition",
            "sport_type":        "Workout",
            "start_date_local":  startStr,
            "elapsed_time":      Int(session.duration),
            "description":       notes,
            "trainer":           0,
            "commute":           0
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw StravaError.invalidResponse
        }
        guard http.statusCode == 201 else {
            throw StravaError.uploadFailed(http.statusCode)
        }
    }

    // MARK: - Token Management

    private func validAccessToken() async throws -> String {
        guard let tokens = storedTokens else {
            throw StravaError.notAuthenticated
        }

        if tokens.expiresAt > Date().timeIntervalSince1970 + 60 {
            return tokens.accessToken
        }

        return try await refresh(using: tokens.refreshToken)
    }

    private func refresh(using refreshToken: String) async throws -> String {
        guard let url = URL(string: tokenURL) else { throw StravaError.tokenRefreshFailed }

        let body: [String: Any] = [
            "client_id":     clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let response = try? JSONDecoder().decode(StravaRefreshResponse.self, from: data) else {
            throw StravaError.tokenRefreshFailed
        }

        storedTokens = StravaTokens(accessToken:  response.accessToken,
                                    refreshToken: response.refreshToken,
                                    expiresAt:    response.expiresAt)
        return response.accessToken
    }
}
