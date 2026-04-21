import Foundation
import Combine
import HealthKit

/// Gestor HealthKit para iPhone.
///
/// En esta arquitectura el Watch es el dueño de las sesiones en vivo (`HKLiveWorkoutBuilder`).
/// El iPhone sólo graba un workout directamente si la sesión se completó sin Watch
/// disponible (usando `HKWorkoutBuilder` no-live con muestras estimadas).
@MainActor
final class HealthKitService: NSObject, ObservableObject {

    static let shared = HealthKitService()

    @Published private(set) var isAuthorized = false

    private let store = HKHealthStore()

    // MARK: - Tipos

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [.workoutType()]
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(e) }
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

    // MARK: - Guardado directo desde iPhone

    /// Guarda un `WorkoutSession` en HealthKit usando `HKWorkoutBuilder` no-live.
    /// Úsalo únicamente si NO hay Watch grabando la misma sesión (usa `existingWorkoutMatches`
    /// para asegurar idempotencia).
    @discardableResult
    func saveWorkoutFromPhone(_ workout: WorkoutSession) async throws -> UUID? {
        let config = HKWorkoutConfiguration()
        if #available(iOS 17.0, *) {
            config.activityType = .fishing
        } else {
            config.activityType = .other
        }
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store,
                                       configuration: config,
                                       device: .local())

        try await builder.beginCollection(at: workout.startDate)

        // Calorías activas estimadas: ~3.5 kcal/min para actividad ligera de pie.
        if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let kcal = max(1, workout.duration / 60 * 3.5)
            let sample = HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                start: workout.startDate,
                end: workout.endDate
            )
            try await builder.addSamples([sample])
        }

        try await builder.addMetadata([
            HKMetadataKeyWorkoutBrandName: "Nature Fly Fishing",
            "PecesT":     workout.pecesT,
            "PecesM":     workout.pecesM,
            "TotalPeces": workout.totalPeces,
            "Modo":       workout.mode.rawValue,
            "Origen":     "iPhone"
        ])

        try await builder.endCollection(at: workout.endDate)
        let saved = try await builder.finishWorkout()
        return saved?.uuid
    }

    /// Comprueba si ya existe un workout en HealthKit en la ventana temporal de la sesión
    /// (±30s sobre el inicio). Evita duplicados si el Watch ya lo grabó.
    func existingWorkoutMatches(_ workout: WorkoutSession) async -> Bool {
        let window: TimeInterval = 30
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate.addingTimeInterval(-window),
            end:       workout.startDate.addingTimeInterval(window),
            options: []
        )
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                cont.resume(returning: (samples?.isEmpty == false))
            }
            store.execute(query)
        }
    }

    // MARK: - Compatibilidad con ViewModel existente

    /// Se conserva la firma antigua como no-op en iPhone: la grabación HealthKit
    /// desde iPhone pasa a hacerse a través de `saveWorkoutFromPhone` tras completar.
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
}
