import Foundation
import Combine

// MARK: - ViewModel

@MainActor
final class WorkoutViewModel: ObservableObject {

    // MARK: - Published State

    @Published var workoutState: WorkoutState = .idle
    @Published var workoutMode: WorkoutMode   = .timed

    // Configuración del timer (modo timed) — minutos totales, de 10 en 10 hasta 120, defecto 60
    @Published var selectedDuration: Int = 60

    // Tiempo restante (modo timed) / transcurrido (modo libre)
    @Published var remainingTime: TimeInterval = 3600
    @Published var elapsedTime:   TimeInterval = 0

    // Contadores
    @Published var pecesT: Int = 0
    @Published var pecesM: Int = 0

    // Post-workout
    @Published var lastSession:    WorkoutSession?
    @Published var isSyncing:      Bool = false
    @Published var healthKitSaved: Bool = false
    @Published var stravaSaved:    Bool = false
    @Published var syncError:      String?

    // MARK: - Private

    private let healthKit = HealthKitService()
    private let strava    = StravaService()

    private var startDate:        Date?
    private var pauseDate:        Date?
    private var accumulatedPause: TimeInterval = 0
    private var timer:            Timer?

    private var totalDuration: TimeInterval {
        TimeInterval(selectedDuration * 60)
    }

    // MARK: - Computed

    /// Tiempo que se muestra en pantalla según el modo
    var formattedDisplay: String {
        switch workoutMode {
        case .timed: return formatted(remainingTime)
        case .free:  return formatted(elapsedTime)
        }
    }

    var stravaAuthenticated: Bool { strava.isAuthenticated }

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

            healthKit.requestPermissions { [weak self] success, _ in
                guard let self, success, let start = self.startDate else { return }
                self.healthKit.startSession(startDate: start)
            }
        }

        if workoutState == .paused, let pd = pauseDate {
            accumulatedPause += Date().timeIntervalSince(pd)
            pauseDate = nil
        }

        workoutState = .running
        scheduleTimer()
    }

    func pauseWorkout() {
        guard workoutState == .running else { return }
        timer?.invalidate()
        timer     = nil
        pauseDate = Date()
        workoutState = .paused
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
    }

    func finishManually() {
        completeWorkout()
    }

    // MARK: - Counters

    func incrementPecesT() { pecesT += 1; haptic() }
    func decrementPecesT() { if pecesT > 0 { pecesT -= 1; haptic() } }
    func incrementPecesM() { pecesM += 1; haptic() }
    func decrementPecesM() { if pecesM > 0 { pecesM -= 1; haptic() } }

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
            break // Sin fin automático — el usuario pulsa la bandera
        }
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

        WorkoutHistoryStore.shared.add(session)
        syncWorkout(session: session)
    }

    private func syncWorkout(session: WorkoutSession) {
        isSyncing = true

        healthKit.endSession(session: session) { [weak self] success, _ in
            Task { @MainActor [weak self] in self?.healthKitSaved = success }
        }

        Task {
            do {
                try await strava.uploadActivity(session: session)
                stravaSaved = true
            } catch {
                syncError = error.localizedDescription
            }
            isSyncing = false
        }
    }

    private func haptic() {
        // Haptic feedback only available on Watch
    }

    private func formatted(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600
        let m = total / 60 % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
