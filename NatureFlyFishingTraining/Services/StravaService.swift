import Foundation
import Combine
import AuthenticationServices
import Security
import UIKit

// MARK: - Errores

enum StravaError: LocalizedError {
    case notAuthenticated
    case tokenRefreshFailed
    case uploadFailed(Int, String?)
    case invalidResponse
    case authCancelled
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:           return "Strava no está conectado."
        case .tokenRefreshFailed:         return "No se pudo renovar el token de Strava."
        case .uploadFailed(let c, let m): return "Error al subir a Strava (HTTP \(c)): \(m ?? "")"
        case .invalidResponse:            return "Respuesta inválida de Strava."
        case .authCancelled:              return "Autenticación cancelada."
        case .missingConfiguration:       return "Configura STRAVA_CLIENT_ID y STRAVA_CLIENT_SECRET en Info.plist."
        }
    }
}

// MARK: - Modelos internos

private struct StravaTokens: Codable {
    let accessToken:  String
    let refreshToken: String
    let expiresAt:    TimeInterval
}

private struct StravaTokenResponse: Codable {
    let accessToken:  String
    let refreshToken: String
    let expiresAt:    TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt    = "expires_at"
    }
}

// MARK: - Servicio

/// Cliente de Strava: OAuth mobile + Keychain + cola de reintentos en disco.
/// Sólo se ejecuta en iPhone. El Watch delega vía `WatchConnectivityManager`.
@MainActor
final class StravaService: NSObject, ObservableObject {

    static let shared = StravaService()

    // MARK: - Configuración
    //
    // Añade a Info.plist (o vía xcconfig):
    //   <key>STRAVA_CLIENT_ID</key>     <string>$(STRAVA_CLIENT_ID)</string>
    //   <key>STRAVA_CLIENT_SECRET</key> <string>$(STRAVA_CLIENT_SECRET)</string>
    // Y configura el URL scheme "natureflyfish" en el target de iOS.

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "STRAVA_CLIENT_ID") as? String) ?? ""
    }
    private var clientSecret: String {
        (Bundle.main.object(forInfoDictionaryKey: "STRAVA_CLIENT_SECRET") as? String) ?? ""
    }

    private let callbackScheme = "natureflyfish"
    private let redirectURI    = "natureflyfish://strava/callback"

    private let authURL  = "https://www.strava.com/oauth/mobile/authorize"
    private let tokenURL = "https://www.strava.com/oauth/token"
    private let apiURL   = "https://www.strava.com/api/v3"

    // MARK: - Estado

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var pendingUploadsCount: Int = 0

    // MARK: - Dependencias

    private let keychain     = KeychainStore(service: "com.natureflyfish.strava")
    private let pendingQueue = PendingUploadQueue(filename: "strava_pending.json")
    private var authSession: ASWebAuthenticationSession?

    // MARK: - Init

    override private init() {
        super.init()
        isAuthenticated = (try? loadTokens()) != nil
        refreshPendingCount()
    }

    // MARK: - OAuth

    func connect() async throws {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw StravaError.missingConfiguration
        }

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id",       value: clientID),
            URLQueryItem(name: "redirect_uri",    value: redirectURI),
            URLQueryItem(name: "response_type",   value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope",           value: "read,activity:write")
        ]
        guard let url = components.url else { throw StravaError.invalidResponse }

        let code: String = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: StravaError.authCancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                          .queryItems?
                          .first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(throwing: StravaError.invalidResponse)
                    return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }

        try await exchangeCode(code)
        isAuthenticated = true

        // Notificar al Watch que ya hay conexión a Strava
        if let tokens = try? loadTokensRaw() {
            WatchConnectivityManager.shared.sendStravaTokens(
                access:    tokens.accessToken,
                refresh:   tokens.refreshToken,
                expiresAt: tokens.expiresAt
            )
        }

        // Procesar pendientes
        Task { await flushPending() }
    }

    func disconnect() {
        keychain.delete(key: "tokens")
        isAuthenticated = false
        WatchConnectivityManager.shared.sendStravaDisconnected()
    }

    // MARK: - Subida

    /// Sube una sesión a Strava. Si no hay red o token, la encola para reintento posterior.
    func uploadActivity(session workout: WorkoutSession) async throws {
        do {
            let token = try await validAccessToken()
            try await performUpload(workout: workout, accessToken: token)
        } catch StravaError.notAuthenticated {
            pendingQueue.enqueue(workout)
            refreshPendingCount()
            throw StravaError.notAuthenticated
        } catch {
            pendingQueue.enqueue(workout)
            refreshPendingCount()
            throw error
        }
    }

    /// Reintenta las subidas encoladas. Para ante el primer fallo y lo vuelve a intentar
    /// la próxima vez (foreground, nueva sesión).
    func flushPending() async {
        guard isAuthenticated else { return }
        for workout in pendingQueue.all() {
            do {
                let token = try await validAccessToken()
                try await performUpload(workout: workout, accessToken: token)
                pendingQueue.remove(id: workout.id)
                refreshPendingCount()
            } catch {
                break
            }
        }
    }

    // MARK: - Request

    private func performUpload(workout: WorkoutSession, accessToken: String) async throws {
        guard let url = URL(string: "\(apiURL)/activities") else {
            throw StravaError.invalidResponse
        }

        let iso = ISO8601DateFormatter()
        let description = """
        🎣 Nature Fly Fishing
        Peces T: \(workout.pecesT)
        Peces M: \(workout.pecesM)
        Total:   \(workout.totalPeces)
        Modo:    \(workout.mode.rawValue)
        """

        let body: [String: Any] = [
            "name":             "Nature Fly Fishing",
            "sport_type":       "Workout",
            "start_date_local": iso.string(from: workout.startDate),
            "elapsed_time":     Int(workout.duration),
            "description":      description,
            "trainer":          0,
            "commute":          0
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StravaError.invalidResponse }

        guard http.statusCode == 201 else {
            let msg = String(data: data, encoding: .utf8)
            throw StravaError.uploadFailed(http.statusCode, msg)
        }
    }

    // MARK: - Tokens

    private func validAccessToken() async throws -> String {
        let tokens = try loadTokens()
        if tokens.expiresAt > Date().timeIntervalSince1970 + 60 {
            return tokens.accessToken
        }
        return try await refresh(using: tokens.refreshToken)
    }

    private func exchangeCode(_ code: String) async throws {
        guard let url = URL(string: tokenURL) else { throw StravaError.invalidResponse }
        let body: [String: Any] = [
            "client_id":     clientID,
            "client_secret": clientSecret,
            "code":          code,
            "grant_type":    "authorization_code"
        ]
        let response = try await tokenRequest(url: url, body: body)
        try saveTokens(StravaTokens(accessToken:  response.accessToken,
                                    refreshToken: response.refreshToken,
                                    expiresAt:    response.expiresAt))
    }

    private func refresh(using refreshToken: String) async throws -> String {
        guard let url = URL(string: tokenURL) else { throw StravaError.tokenRefreshFailed }
        let body: [String: Any] = [
            "client_id":     clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token"
        ]
        do {
            let response = try await tokenRequest(url: url, body: body)
            try saveTokens(StravaTokens(accessToken:  response.accessToken,
                                        refreshToken: response.refreshToken,
                                        expiresAt:    response.expiresAt))
            return response.accessToken
        } catch {
            throw StravaError.tokenRefreshFailed
        }
    }

    private func tokenRequest(url: URL, body: [String: Any]) async throws -> StravaTokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(StravaTokenResponse.self, from: data)
    }

    // MARK: - Keychain

    private func loadTokens() throws -> StravaTokens {
        guard let tokens = try? loadTokensRaw() else { throw StravaError.notAuthenticated }
        return tokens
    }

    private func loadTokensRaw() throws -> StravaTokens {
        guard let data = keychain.read(key: "tokens"),
              let tokens = try? JSONDecoder().decode(StravaTokens.self, from: data)
        else { throw StravaError.notAuthenticated }
        return tokens
    }

    private func saveTokens(_ tokens: StravaTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        keychain.write(key: "tokens", data: data)
    }

    // MARK: - Compat con el API original

    /// Permite almacenar tokens recibidos por WatchConnectivity (conservado por compatibilidad).
    func storeTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
        try? saveTokens(StravaTokens(accessToken:  accessToken,
                                     refreshToken: refreshToken,
                                     expiresAt:    expiresAt))
        isAuthenticated = true
    }

    func clearTokens() { disconnect() }

    // MARK: - Helpers

    private func refreshPendingCount() {
        pendingUploadsCount = pendingQueue.all().count
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension StravaService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                return window
            }
            return ASPresentationAnchor()
        }
    }
}

// MARK: - Keychain helper

struct KeychainStore {
    let service: String

    func write(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData      as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Cola de reintentos persistida

final class PendingUploadQueue {

    private let url: URL
    private let queue = DispatchQueue(label: "com.natureflyfish.pending")

    init(filename: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)
    }

    func enqueue(_ session: WorkoutSession) {
        queue.sync {
            var current = loadUnsafe()
            guard !current.contains(where: { $0.id == session.id }) else { return }
            current.append(session)
            saveUnsafe(current)
        }
    }

    func remove(id: UUID) {
        queue.sync {
            var current = loadUnsafe()
            current.removeAll { $0.id == id }
            saveUnsafe(current)
        }
    }

    func all() -> [WorkoutSession] {
        queue.sync { loadUnsafe() }
    }

    private func loadUnsafe() -> [WorkoutSession] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([WorkoutSession].self, from: data)
        else { return [] }
        return list
    }

    private func saveUnsafe(_ sessions: [WorkoutSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
