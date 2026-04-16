import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {

    static let shared = WatchConnectivityManager()

    @Published var session: WCSession?
    @Published var lastReceivedData: [String: Any]? {
        didSet {
            if let data = lastReceivedData {
                handleReceivedData(data)
            }
        }
    }

    private var workoutViewModel: WorkoutViewModel?

    override private init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
    }

    // MARK: - Send Data to iPhone

    func sendWorkoutState(
        state: WorkoutState,
        mode: WorkoutMode,
        pecesT: Int,
        pecesM: Int,
        elapsedTime: TimeInterval
    ) {
        let data: [String: Any] = [
            "action": "updateWorkout",
            "state": String(describing: state),
            "mode": mode.rawValue,
            "pecesT": pecesT,
            "pecesM": pecesM,
            "elapsedTime": elapsedTime
        ]
        sendData(data)
    }

    func sendCompletedSession(_ session: WorkoutSession) {
        let data: [String: Any] = [
            "action": "sessionCompleted",
            "sessionData": try? JSONEncoder().encode(session)
        ]
        sendData(data)
    }

    private func sendData(_ data: [String: Any]) {
        guard let session = session, session.isReachable else { return }
        session.sendMessage(data, replyHandler: nil) { error in
            print("[WatchConnectivity] Error al enviar: \(error.localizedDescription)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("[WatchConnectivity] Sesión activada: \(activationState.rawValue)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("[WatchConnectivity] Sesión inactiva")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("[WatchConnectivity] Sesión desactivada")
        setupSession()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            self.lastReceivedData = message
        }
    }

    // MARK: - Handle Received Data

    private func handleReceivedData(_ data: [String: Any]) {
        guard let action = data["action"] as? String else { return }

        switch action {
        case "updateWorkout":
            handleUpdateWorkout(data)
        case "sessionCompleted":
            handleSessionCompleted(data)
        default:
            break
        }
    }

    private func handleUpdateWorkout(_ data: [String: Any]) {
        // Update local state if needed
        print("[WatchConnectivity] Workout actualizado desde iPhone")
    }

    private func handleSessionCompleted(_ data: [String: Any]) {
        // Sync completed session
        print("[WatchConnectivity] Sesión completada recibida desde iPhone")
    }
}
