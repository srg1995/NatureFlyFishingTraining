import Foundation
import Combine
import HealthKit

/// Gestor HealthKit en el Watch: usa `HKLiveWorkoutBuilder` para capturar HR
/// y calorías activas en tiempo real. Tipo de actividad `.fishing` (watchOS 10+).
@MainActor
final class HealthKitService: NSObject, ObservableObject {

    static let shared = HealthKitService()

    @Published private(set) var isAuthorized    = false
    @Published private(set) var isSessionActive = false
    @Published private(set) var currentHeartRate: Double = 0
    @Published private(set) var currentCalories:  Double = 0

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    // MARK: - Tipos

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [.workoutType()]
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(e) }
        if let h = HKQuantityType.quantityType(forIdentifier: .heartRate)          { types.insert(h) }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [.workoutType()]
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(e) }
        if let h = HKQuantityType.quantityType(forIdentifier: .heartRate)          { types.insert(h) }
        return types
    }

    // MARK: - Permisos

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        isAuthorized = true
    }

    // Compatibilidad con el API original (callback).
    func requestPermissions(completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                try await requestAuthorization()
                completion(true, nil)
            } catch {
                completion(false, error)
            }
        }
    }

    // MARK: - Sesión en vivo

    func startSession(startDate: Date) {
        guard session == nil else { return }

        let config = HKWorkoutConfiguration()
        if #available(watchOS 10.0, *) {
            config.activityType = .fishing
        } else {
            config.activityType = .other
        }
        config.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                        workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            isSessionActive = true
        } catch {
            print("[HK] Error al iniciar sesión: \(error.localizedDescription)")
        }
    }

    func pause()  { session?.pause() }
    func resume() { session?.resume() }

    // MARK: - Cierre de sesión (API moderno — async)

    @discardableResult
    func endSession(for workout: WorkoutSession) async throws -> UUID? {
        guard let session, let builder else { return nil }

        session.end()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: workout.endDate) { success, error in
                if success { cont.resume() }
                else { cont.resume(throwing: error ?? HKError(.errorHealthDataUnavailable)) }
            }
        }

        let metadata: [String: Any] = [
            HKMetadataKeyWorkoutBrandName: "Nature Fly Fishing",
            "PecesT":     workout.pecesT,
            "PecesM":     workout.pecesM,
            "TotalPeces": workout.totalPeces,
            "Modo":       workout.mode.rawValue
        ]

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }

        let saved: HKWorkout? = try await withCheckedThrowingContinuation { cont in
            builder.finishWorkout { workout, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: workout) }
            }
        }

        self.session = nil
        self.builder = nil
        isSessionActive = false

        return saved?.uuid
    }

    // MARK: - Compatibilidad con el API original (callback)

    func endSession(session workout: WorkoutSession, completion: @escaping (Bool, Error?) -> Void) {
        Task {
            do {
                _ = try await endSession(for: workout)
                completion(true, nil)
            } catch {
                completion(false, error)
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension HealthKitService: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        print("[HK] session failed: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension HealthKitService: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm: Double? = {
            guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
                  collectedTypes.contains(hrType),
                  let stats = workoutBuilder.statistics(for: hrType) else { return nil }
            return stats.mostRecentQuantity()?
                .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }()

        let kcal: Double? = {
            guard let eType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                  collectedTypes.contains(eType),
                  let stats = workoutBuilder.statistics(for: eType) else { return nil }
            return stats.sumQuantity()?.doubleValue(for: .kilocalorie())
        }()

        Task { @MainActor in
            if let bpm  { self.currentHeartRate = bpm }
            if let kcal { self.currentCalories  = kcal }
        }
    }
}
