import Foundation
import Combine

// MARK: - ViewModel (iPhone)

@MainActor
final class WorkoutViewModel: ObservableObject {

    // MARK: - Published State

    @Published var workoutState: WorkoutState = .idle
    @Published var workoutMode:  WorkoutMode  = .timed

    // Configuración del timer (modo timed) — minutos totales, múltiplos de 10 hasta 120, defecto 60
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

    // Reflejo de sesión activa en el Watch (cuando el iPhone es espectador)
    @Published var isMirroringWatch: Bool = false

    // MARK: - Private

    private let healthKit = HealthKitService.shared
    private let strava    = StravaService.shared

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
            isMirroringWatch = false

            Task { try? await healthKit.requestAuthorization() }
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
        isMirroringWatch = false
    }

    func finishManually() {
        completeWorkout()
    }

    // MARK: - Counters

    func incrementPecesT() { pecesT += 1; haptic() }
    func decrementPecesT() { if pecesT > 0 { pecesT -= 1; haptic() } }
    func incrementPecesM() { pecesM += 1; haptic() }
    func decrementPecesM() { if pecesM > 0 { pecesM -= 1; haptic() } }

    // MARK: - Mirror desde Watch

    /// Refleja en el iPhone el estado de un entrenamiento que se está ejecutando en el Watch.
    /// Se ignora si el iPhone ya es el dueño de una sesión activa.
    func mirrorLiveState(_ state: LiveWorkoutState) {
        guard workoutState != .running else { return }
        pecesT        = state.pecesT
        pecesM        = state.pecesM
        elapsedTime   = state.elapsedTime
        remainingTime = state.remainingTime
        if let mode = WorkoutMode(rawValue: state.mode) { workoutMode = mode }
        isMirroringWatch = (state.state == "running" || state.state == "paused")
    }

    /// Llamado cuando el iPhone recibe una sesión completada desde el Watch.
    func ingestRemoteCompletedSession(_ session: WorkoutSession) {
        lastSession      = session
        isMirroringWatch = false
        WorkoutHistoryStore.shared.add(session)

        Task {
            isSyncing = true

            // HealthKit: sólo si el Watch no grabó ya el workout en la misma ventana.
            let exists = await healthKit.existingWorkoutMatches(session)
            if !exists {
                do {
                    _ = try await healthKit.saveWorkoutFromPhone(session)
                    healthKitSaved = true
                } catch {
                    healthKitSaved = false
                    syncError = error.localizedDescription
                }
            } else {
                healthKitSaved = true
            }

            // Strava: si falla se encola para reintento.
            do {
                try await strava.uploadActivity(session: session)
                stravaSaved = true
            } catch {
                stravaSaved = false
                syncError = error.localizedDescription
            }

            isSyncing = false
        }
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard let start = startDate else { return }

        let elapsed = Date().timeIntervalSince(start) - accumulatedPause
        elapsedTime = elapsed

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

        Task {
            // HealthKit desde iPhone sólo si nadie más lo grabó.
            let exists = await healthKit.existingWorkoutMatches(session)
            if !exists {
                do {
                    _ = try await healthKit.saveWorkoutFromPhone(session)
                    healthKitSaved = true
                } catch {
                    healthKitSaved = false
                    syncError = error.localizedDescription
                }
            } else {
                healthKitSaved = true
            }

            do {
                try await strava.uploadActivity(session: session)
                stravaSaved = true
            } catch {
                stravaSaved = false
                syncError = error.localizedDescription
            }

            isSyncing = false
        }
    }

    private func haptic() {
        // iPhone: sin haptic específico para el conteo.
    }

    private func formatted(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600
        let m = total / 60 % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
