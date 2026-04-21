import Foundation
import Combine
import SwiftUI

/// Historial de sesiones sincronizado entre iPhone y Watch vía iCloud Key-Value Storage.
///
/// Política:
/// - iCloud KVS propaga cambios automáticamente entre dispositivos del mismo Apple ID.
/// - Sin iCloud configurado: persiste sólo en `UserDefaults` (App Group) — la app sigue funcionando.
/// - Dedupe por `WorkoutSession.id` → `add` es idempotente.
@MainActor
final class WorkoutHistoryStore: ObservableObject {

    static let shared = WorkoutHistoryStore()

    static let appGroupId = "group.com.natureflyfish"

    @Published private(set) var sessions: [WorkoutSession] = []

    // MARK: - Private

    private let kvs = NSUbiquitousKeyValueStore.default

    private let cloudKey = "com.natureflyfish.history.v1"
    private let localKey = "com.natureflyfish.history.v1"
    private let maxEntries = 500

    private var defaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupId) ?? .standard
    }

    // MARK: - Init

    private init() {
        load()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        kvs.synchronize()
    }

    // MARK: - API pública

    /// Añade una sesión — ignora si el `id` ya está presente (idempotente).
    func add(_ session: WorkoutSession) {
        guard !sessions.contains(where: { $0.id == session.id }) else { return }
        var merged = sessions
        merged.append(session)
        commit(merged)
    }

    /// Fusiona un lote preservando los existentes (gana el local si hay conflicto por id).
    func merge(_ incoming: [WorkoutSession]) {
        var byID: [UUID: WorkoutSession] = [:]
        for s in sessions { byID[s.id] = s }
        for s in incoming where byID[s.id] == nil { byID[s.id] = s }
        commit(Array(byID.values))
    }

    func delete(at offsets: IndexSet) {
        var copy = sessions
        copy.remove(atOffsets: offsets)
        commit(copy)
    }

    func delete(_ session: WorkoutSession) {
        commit(sessions.filter { $0.id != session.id })
    }

    func deleteAll() {
        commit([])
    }

    // MARK: - Stats

    var totalSessions: Int { sessions.count }

    var bestSession: WorkoutSession? {
        sessions.max(by: { $0.totalPeces < $1.totalPeces })
    }

    var totalPeces: Int {
        sessions.reduce(0) { $0 + $1.totalPeces }
    }

    var averagePeces: Double {
        guard !sessions.isEmpty else { return 0 }
        return Double(totalPeces) / Double(sessions.count)
    }

    // MARK: - Persistence

    private func commit(_ newValue: [WorkoutSession]) {
        var sorted = newValue.sorted { $0.startDate > $1.startDate }
        if sorted.count > maxEntries {
            sorted = Array(sorted.prefix(maxEntries))
        }
        sessions = sorted

        guard let data = try? JSONEncoder().encode(sorted) else { return }

        // Local (siempre)
        defaults.set(data, forKey: localKey)

        // iCloud KVS (si cabe en el límite de 1 MB por valor)
        if data.count < 900_000 {
            kvs.set(data, forKey: cloudKey)
            kvs.synchronize()
        }
    }

    private func load() {
        // 1) Prioridad a iCloud en frío (útil al reinstalar o cambiar de dispositivo)
        if let cloudData = kvs.data(forKey: cloudKey),
           let decoded = try? JSONDecoder().decode([WorkoutSession].self, from: cloudData) {
            sessions = decoded.sorted { $0.startDate > $1.startDate }
            defaults.set(cloudData, forKey: localKey)
            return
        }
        // 2) Fallback local
        if let localData = defaults.data(forKey: localKey),
           let decoded = try? JSONDecoder().decode([WorkoutSession].self, from: localData) {
            sessions = decoded.sorted { $0.startDate > $1.startDate }
        }
    }

    @objc private func kvsDidChange(_ notification: Notification) {
        Task { @MainActor in
            guard let data = kvs.data(forKey: cloudKey),
                  let incoming = try? JSONDecoder().decode([WorkoutSession].self, from: data)
            else { return }
            // Política defensiva: sólo sobrescribimos si el remoto no está vacío,
            // para evitar que un reset accidental en otro dispositivo borre el historial.
            guard !incoming.isEmpty else { return }
            sessions = incoming.sorted { $0.startDate > $1.startDate }
            if let encoded = try? JSONEncoder().encode(sessions) {
                defaults.set(encoded, forKey: localKey)
            }
        }
    }
}
