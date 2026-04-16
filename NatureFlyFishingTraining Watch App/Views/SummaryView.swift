import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {

                // Header
                VStack(spacing: 2) {
                    Text("🏁")
                        .font(.title2)
                    Text("¡Completado!")
                        .font(.headline)
                        .foregroundStyle(.teal)
                }
                .padding(.top, 4)

                Divider()

                // Sesión
                if let session = viewModel.lastSession {
                    VStack(spacing: 6) {
                        SummaryRow(label: "⏱ Duración", value: session.formattedDuration)
                        SummaryRow(label: "🐟 Peces T",  value: "\(session.pecesT)", valueColor: .red)
                        SummaryRow(label: "🐟 Peces M",  value: "\(session.pecesM)", valueColor: .blue)
                        SummaryRow(label: "📊 Total",    value: "\(session.totalPeces)")
                    }
                }

                Divider()

                // Estado sincronización
                VStack(spacing: 6) {
                    SyncStatusRow(
                        icon: "heart.fill",
                        label: "Apple Fitness",
                        isSyncing: viewModel.isSyncing,
                        success: viewModel.healthKitSaved,
                        color: .red
                    )

                    SyncStatusRow(
                        icon: "arrow.up.circle.fill",
                        label: "Strava",
                        isSyncing: viewModel.isSyncing,
                        success: viewModel.stravaSaved,
                        color: .orange
                    )
                }

                if let error = viewModel.syncError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Acciones
                VStack(spacing: 6) {
                    Button("Nueva sesión", action: viewModel.resetWorkout)
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .font(.footnote)

                    NavigationLink(destination: HistoryView()) {
                        Label("Ver historial", systemImage: "clock.arrow.circlepath")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Resultado")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

private struct SummaryRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(valueColor)
        }
    }
}

private struct SyncStatusRow: View {
    let icon: String
    let label: String
    let isSyncing: Bool
    let success: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isSyncing && !success {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(success ? .green : .gray)
                    .font(.caption)
            }
        }
    }
}

#Preview {
    let vm = WorkoutViewModel()
    vm.lastSession = WorkoutSession(
        startDate: Date().addingTimeInterval(-3600),
        endDate:   Date(),
        duration:  3600,
        pecesT:    7,
        pecesM:    5,
        mode:      .timed
    )
    vm.healthKitSaved = true
    vm.stravaSaved    = false
    return NavigationStack { SummaryView() }
        .environmentObject(vm)
}
