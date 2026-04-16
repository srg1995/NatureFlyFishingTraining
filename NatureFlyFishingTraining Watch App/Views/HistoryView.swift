import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = WorkoutHistoryStore.shared
    @State private var showDeleteAll = false

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Historial")
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🎣")
                .font(.title)
            Text("Sin sesiones")
                .font(.headline)
            Text("Completa tu primera competición")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - List

    private var sessionList: some View {
        List {
            // Stats header
            statsSection

            // Sessions
            ForEach(store.sessions) { session in
                NavigationLink(destination: HistoryDetailView(session: session)) {
                    SessionRowView(session: session)
                }
            }
            .onDelete(perform: store.delete)

            // Borrar todo
            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                Label("Borrar todo", systemImage: "trash")
                    .font(.caption)
            }
            .confirmationDialog("¿Borrar historial?", isPresented: $showDeleteAll) {
                Button("Borrar todo", role: .destructive, action: store.deleteAll)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(spacing: 6) {
            HStack {
                statBox(value: "\(store.totalSessions)", label: "Sesiones")
                statBox(value: "\(store.totalPeces)",    label: "Peces total")
            }
            HStack {
                statBox(value: String(format: "%.1f", store.averagePeces), label: "Media/sesión")
                if let best = store.bestSession {
                    statBox(value: "\(best.totalPeces)", label: "Récord 🏆")
                }
            }
        }
        .listRowBackground(Color.teal.opacity(0.15))
        .padding(.vertical, 4)
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.teal)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SessionRowView

struct SessionRowView: View {
    let session: WorkoutSession

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "dd MMM"
        f.locale = Locale(identifier: "es_ES")
        return f.string(from: session.startDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(dateText)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(session.shortDuration)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label("\(session.pecesT)", systemImage: "fish.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Label("\(session.pecesM)", systemImage: "fish.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                Spacer()
                Text("Total: \(session.totalPeces)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let store = WorkoutHistoryStore.shared
    store.add(WorkoutSession(startDate: Date().addingTimeInterval(-7200), endDate: Date().addingTimeInterval(-3600), duration: 3600, pecesT: 7, pecesM: 5, mode: .timed))
    store.add(WorkoutSession(startDate: Date().addingTimeInterval(-86400), endDate: Date().addingTimeInterval(-82800), duration: 3900, pecesT: 3, pecesM: 9, mode: .free))
    return NavigationStack { HistoryView() }
}
