import Foundation
import HealthKit

class HealthKitService: NSObject, ObservableObject {

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var liveBuilder:    HKLiveWorkoutBuilder?

    // MARK: - Tipos requeridos

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        if let heart = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(heart)
        }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType()]
    }

    // MARK: - Permisos

    func requestPermissions(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, nil)
            return
        }
        healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    // MARK: - Inicio de sesión

    func startSession(startDate: Date) {
        let config = HKWorkoutConfiguration()
        config.activityType  = .other
        config.locationType  = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.delegate = self

            let builder = session.associatedWorkoutBuilder()
            builder.delegate   = self
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore:            healthStore,
                workoutConfiguration:   config
            )

            workoutSession = session
            liveBuilder    = builder

            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }

        } catch {
            print("[HealthKit] Error al iniciar sesión: \(error.localizedDescription)")
        }
    }

    // MARK: - Fin de sesión

    func endSession(session: WorkoutSession, completion: @escaping (Bool, Error?) -> Void) {
        workoutSession?.end()

        // 1. Añadir muestra de calorías activas estimadas
        addEnergySample(session: session) { [weak self] in
            guard let self else { return }

            // 2. Cerrar la recolección
            self.liveBuilder?.endCollection(withEnd: session.endDate) { success, error in
                guard success else {
                    DispatchQueue.main.async { completion(false, error) }
                    return
                }

                // 3. Añadir metadata con los datos de pesca
                let metadata = self.buildMetadata(session: session)
                self.liveBuilder?.addMetadata(metadata) { _, _ in

                    // 4. Finalizar y guardar el workout en HealthKit
                    self.liveBuilder?.finishWorkout { workout, error in
                        DispatchQueue.main.async {
                            if let workout {
                                print("[HealthKit] ✅ Workout guardado: \(workout.uuid)")
                            } else {
                                print("[HealthKit] ❌ Error: \(error?.localizedDescription ?? "desconocido")")
                            }
                            completion(workout != nil, error)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers privados

    private func addEnergySample(session: WorkoutSession, completion: @escaping () -> Void) {
        guard let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            completion()
            return
        }

        // Estimación: ~3.5 kcal/min para actividad ligera de pie (pesca)
        let minutes  = session.duration / 60
        let calories = max(1, minutes * 3.5)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: calories)
        let sample   = HKQuantitySample(
            type:     energyType,
            quantity: quantity,
            start:    session.startDate,
            end:      session.endDate
        )

        liveBuilder?.add([sample]) { _, _ in completion() }
    }

    private func buildMetadata(session: WorkoutSession) -> [String: Any] {
        [
            HKMetadataKeyWorkoutBrandName: "Nature Fly Fishing Competition",
            "Peces T":     session.pecesT,
            "Peces M":     session.pecesM,
            "Total Peces": session.totalPeces,
            "Modo":        session.mode.rawValue
        ]
    }
}

// MARK: - HKWorkoutSessionDelegate

extension HealthKitService: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        print("[HealthKit] Estado: \(fromState.rawValue) → \(toState.rawValue)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[HealthKit] Sesión fallida: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension HealthKitService: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {}
}
