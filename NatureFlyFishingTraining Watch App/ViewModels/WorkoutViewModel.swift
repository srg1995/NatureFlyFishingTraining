import Foundation
import Combine
import WatchKit

// MARK: - ViewModel (Watch)

@MainActor
final class WorkoutViewModel: ObservableObject {

    // MARK: - Published State

    @Published var workoutState: WorkoutState = .idle
    @Published var workoutMode:  WorkoutMode  = .timed

    @Published var selectedDuration: Int = 60

    @Published var remainingTime: TimeInterval = 3600
    @Published var elapsedTime:   TimeInterval = 0

    @Published var pecesT: Int = 0
    @Published var pecesM: Int = 0

    @Published var lastSession:    WorkoutSession?
    @Published var isSyncing:      Bool = false
    @Published var healthKitSaved: Bool = false
    @Published var stravaSaved:    Bool = false
    @Published var syncError:      String?

    // MARK: - Private

    private let healthKit     = HealthKitService.shared
    private let strava        = StravaService.shared
    private let connectivity  = WatchConnectivityManager.shared

    private var startDate:        Date?
    private var pauseDate:        Date?
    private var accumulatedPause: TimeInterval = 0
    private var timer:            Timer?

    private var totalDuration: TimeInterval {
        TimeInterval(selectedDuration * 60)
    }

    // MARK: - Computed

    var formattedDisplay: String {
        switch workoutMode {
        case .timed: return formatted(remainingTime)
        case .free:  return formatted(elapsedTime)
        }
    }

    /// En el Watch refleja si el iPhone ha autenticado Strava.
    var stravaAuthenticated: Bool {
        strava.isAuthenticated || connectivity.stravaConnectedOnPhone
    }

    // MARK: - Mode

    func setMode(_ mode: WorkoutMode) {
        guard workoutState == .idle else { return }
        workoutMode = mode
        remainingTime = totalDuration
    }

    // MARK: - Timer Controls

    func startWorkout() {
        guard workoutState == .idle || workoutState == .paused else { return }

        if workoutState == .idle {
            remainingTime    = totalDuration
            elapsedTime      = 0
            startDate        = Date()
            accumulatedPause = 0
            pecesT           = 0
            pecesM           = 0
            syncError        = nil
            healthKitSaved   = false
            stravaSaved      = false

            // Permisos + sesión HealthKit en vivo
            Task {
                try? await healthKit.requestAuthorization()
                if let start = self.startDate {
                    healthKit.startSession(startDate: start)
                }
            }
        }

        if workoutState == .paused, let pd = pauseDate {
            accumulatedPause += Date().timeIntervalSince(pd)
            pauseDate = nil
            healthKit.resume()
        }

        workoutState = .running
        WKInterfaceDevice.current().play(.start)
        scheduleTimer()
        broadcastLiveState()
    }

    func pauseWorkout() {
        guard workoutState == .running else { return }
        timer?.invalidate()
        timer     = nil
        pauseDate = Date()
        workoutState = .paused
        healthKit.pause()
        WKInterfaceDevice.current().play(.stop)
        broadcastLiveState()
    }

    func resetWorkout() {
        timer?.invalidate()
        timer            = nil
        workoutState     = .idle
        remainingTime    = totalDuration
        elapsedTime      = 0
        startDate        = nil
        pauseDate        = nil
        accumulatedPause = 0
        pecesT           = 0
        pecesM           = 0
        syncError        = nil
        broadcastLiveState()
    }

    func finishManually() {
        completeWorkout()
    }

    // MARK: - Counters

    func incrementPecesT() { pecesT += 1; haptic(); broadcastLiveState() }
    func decrementPecesT() { if pecesT > 0 { pecesT -= 1; haptic(); broadcastLiveState() } }
    func incrementPecesM() { pecesM += 1; haptic(); broadcastLiveState() }
    func decrementPecesM() { if pecesM > 0 { pecesM -= 1; haptic(); broadcastLiveState() } }

    // MARK: - Private

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard let start = startDate else { return }

        let elapsed  = Date().timeIntervalSince(start) - accumulatedPause
        elapsedTime  = elapsed

        switch workoutMode {
        case .timed:
            remainingTime = max(0, totalDuration - elapsed)
            if remainingTime <= 0 {
                timer?.invalidate()
                timer = nil
                completeWorkout()
            }
        case .free:
            break
        }

        broadcastLiveState()
    }

    private func completeWorkout() {
        let endDate = Date()
        let start   = startDate ?? endDate.addingTimeInterval(-elapsedTime)
        let elapsed = endDate.timeIntervalSince(start) - accumulatedPause

        let duration: TimeInterval = workoutMode == .timed
            ? min(elapsed, totalDuration)
            : elapsed

        let session = WorkoutSession(
            startDate: start,
            endDate:   endDate,
            duration:  duration,
            pecesT:    pecesT,
            pecesM:    pecesM,
            mode:      workoutMode
        )

        lastSession  = session
        workoutState = .finished
        WKInterfaceDevice.current().play(.success)

        WorkoutHistoryStore.shared.add(session)

        // Cerrar HealthKit (fuente única de grabación) y propagar al iPhone.
        Task {
            isSyncing = true

            do {
                _ = try await healthKit.endSession(for: session)
                healthKitSaved = true
            } catch {
                healthKitSaved = false
                syncError = error.localizedDescription
            }

            // Envío garantizado al iPhone — él sube a Strava.
            connectivity.sendCompletedSession(session)

            isSyncing = false
        }
    }

    private func broadcastLiveState() {
        let stateStr: String = {
            switch workoutState {
            case .idle:     return "idle"
            case .running:  return "running"
            case .paused:   return "paused"
            case .finished: return "finished"
            }
        }()
        connectivity.sendLiveState(
            LiveWorkoutState(
                state:         stateStr,
                mode:          workoutMode.rawValue,
                pecesT:        pecesT,
                pecesM:        pecesM,
                elapsedTime:   elapsedTime,
                remainingTime: remainingTime
            )
        )
    }

    private func haptic() {
        WKInterfaceDevice.current().play(.click)
    }

    private func formatted(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600
        let m = total / 60 % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
