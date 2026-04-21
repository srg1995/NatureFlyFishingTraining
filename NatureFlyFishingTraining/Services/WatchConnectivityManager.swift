import Foundation
import Combine
import WatchConnectivity

// MARK: - Payloads

/// Estado en vivo del entrenamiento — se envía frecuentemente desde el Watch
/// mientras la sesión está en curso.
struct LiveWorkoutState: Codable, Equatable {
    let state:         String     // running / paused / idle / finished
    let mode:          String     // WorkoutMode.rawValue
    let pecesT:        Int
    let pecesM:        Int
    let elapsedTime:   TimeInterval
    let remainingTime: TimeInterval

    func asDictionary() throws -> [String: Any] {
        let payload = try JSONEncoder().encode(self)
        return ["kind": "liveState", "payload": payload]
    }

    init?(dictionary: [String: Any]) {
        guard (dictionary["kind"] as? String) == "liveState",
              let data = dictionary["payload"] as? Data,
              let decoded = try? JSONDecoder().decode(LiveWorkoutState.self, from: data)
        else { return nil }
        self = decoded
    }

    init(state: String, mode: String, pecesT: Int, pecesM: Int,
         elapsedTime: TimeInterval, remainingTime: TimeInterval) {
        self.state = state
        self.mode = mode
        self.pecesT = pecesT
        self.pecesM = pecesM
        self.elapsedTime = elapsedTime
        self.remainingTime = remainingTime
    }
}

// MARK: - WorkoutSession <-> WCSession payload

extension WorkoutSession {
    func asUserInfo() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return ["kind": "completedSession", "payload": data]
    }

    init?(userInfo: [String: Any]) {
        guard (userInfo["kind"] as? String) == "completedSession",
              let data = userInfo["payload"] as? Data,
              let decoded = try? JSONDecoder().decode(WorkoutSession.self, from: data)
        else { return nil }
        self = decoded
    }
}

// MARK: - Manager

/// Gestor único de sincronización iPhone ↔ Watch.
///
/// - `sendMessage`                → estado en vivo (solo si el peer está alcanzable).
/// - `updateApplicationContext`   → último estado conocido, idempotente, sobrevive a reinicios.
/// - `transferUserInfo`           → sesiones completadas (encoladas, entrega garantizada).
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {

    static let shared = WatchConnectivityManager()

    // MARK: - Estado publicado

    @Published private(set) var isReachable = false
    @Published private(set) var isPaired    = false
    @Published private(set) var liveState: LiveWorkoutState?
    @Published private(set) var lastReceivedSession: WorkoutSession?
    @Published private(set) var stravaConnectedOnPhone: Bool = false

    // MARK: - Callbacks inyectables (configurables desde el ViewModel / App)

    var onSessionReceived:     ((WorkoutSession) -> Void)?
    var onLiveStateReceived:   ((LiveWorkoutState) -> Void)?
    var onStravaTokensReceived: ((String, String, TimeInterval) -> Void)?

    // MARK: - Dedupe

    private let processedKey = "com.natureflyfish.wc.processedSessionIDs"

    private var processedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: processedKey) ?? []) }
        set {
            // Cap a 500 IDs para no crecer indefinidamente
            let trimmed = newValue.count > 500 ? Set(newValue.shuffled().prefix(500)) : newValue
            UserDefaults.standard.set(Array(trimmed), forKey: processedKey)
        }
    }

    private func markProcessed(_ id: UUID) {
        var ids = processedIDs
        ids.insert(id.uuidString)
        processedIDs = ids
    }

    private func hasProcessed(_ id: UUID) -> Bool {
        processedIDs.contains(id.uuidString)
    }

    // MARK: - Init

    override private init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - API pública

    /// Envía estado en vivo del entrenamiento (cada tick o cada cambio).
    func sendLiveState(_ state: LiveWorkoutState) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let dict = try? state.asDictionary() else { return }

        // Contexto persistente para el peer dormido
        try? session.updateApplicationContext(dict)

        // Mensaje en vivo si hay conexión
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { error in
                print("[WC] sendMessage error: \(error.localizedDescription)")
            }
        }
    }

    /// Envía una sesión completada al peer — entrega garantizada vía `transferUserInfo`.
    func sendCompletedSession(_ workout: WorkoutSession) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let dict = try? workout.asUserInfo() else { return }
        session.transferUserInfo(dict)
    }

    /// Solo iPhone → Watch. Propaga los tokens de Strava para que el Watch pueda
    /// mostrar el estado "conectado".
    func sendStravaTokens(access: String, refresh: String, expiresAt: TimeInterval) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let dict: [String: Any] = [
            "kind":      "stravaTokens",
            "access":    access,
            "refresh":   refresh,
            "expiresAt": expiresAt
        ]
        session.transferUserInfo(dict)
    }

    /// Solo iPhone → Watch. Notifica desconexión de Strava.
    func sendStravaDisconnected() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(["kind": "stravaDisconnected"])
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        #if os(iOS)
        let paired = session.isPaired
        #else
        let paired = true
        #endif
        Task { @MainActor in
            self.isReachable = reachable
            self.isPaired    = paired
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.ingestLive(message) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingestLive(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.ingestUserInfo(userInfo) }
    }

    // MARK: - Ingest

    @MainActor
    private func ingestLive(_ dict: [String: Any]) {
        guard let state = LiveWorkoutState(dictionary: dict) else { return }
        self.liveState = state
        onLiveStateReceived?(state)
    }

    @MainActor
    private func ingestUserInfo(_ dict: [String: Any]) {
        guard let kind = dict["kind"] as? String else { return }

        switch kind {
        case "completedSession":
            guard let workout = WorkoutSession(userInfo: dict) else { return }
            guard !hasProcessed(workout.id) else { return }
            markProcessed(workout.id)
            lastReceivedSession = workout
            onSessionReceived?(workout)

        case "stravaTokens":
            guard let access  = dict["access"]    as? String,
                  let refresh = dict["refresh"]   as? String,
                  let expires = dict["expiresAt"] as? TimeInterval
            else { return }
            stravaConnectedOnPhone = true
            onStravaTokensReceived?(access, refresh, expires)

        case "stravaDisconnected":
            stravaConnectedOnPhone = false

        default:
            break
        }
    }
}
