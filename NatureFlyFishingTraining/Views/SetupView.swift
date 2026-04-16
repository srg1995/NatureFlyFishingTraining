import SwiftUI

struct SetupView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel
    @ObservedObject private var store = WorkoutHistoryStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Divider()

                // Selector de modo
                HStack(spacing: 0) {
                    ForEach(WorkoutMode.allCases, id: \.self) { mode in
                        let selected = viewModel.workoutMode == mode
                        Button {
                            viewModel.workoutMode = mode
                        } label: {
                            Text(mode == .timed ? "⏱ Tiempo" : "🆓 Libre")
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(selected ? .teal : .gray)
                    }
                }

                // Configuración de duración (solo en modo timed)
                if viewModel.workoutMode == .timed {
                    VStack(spacing: 2) {
                        Text("Duración")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Minutos", selection: $viewModel.selectedDuration) {
                            ForEach(stride(from: 10, through: 120, by: 10).map { $0 }, id: \.self) { min in
                                Text("\(min) min").tag(min)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 80)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    // Descripción modo libre
                    VStack(spacing: 2) {
                        Image(systemName: "infinity")
                            .font(.title3)
                            .foregroundStyle(.teal)
                        Text("Sin límite de tiempo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Start button
                Button(action: viewModel.startWorkout) {
                    Label("Iniciar", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(
                    viewModel.workoutMode == .timed &&
                    viewModel.selectedDuration == 0
                )
                .animation(.easeInOut, value: viewModel.workoutMode)

                // Historial
                NavigationLink(destination: HistoryView()) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.orange)
                        Text("Historial")
                            .font(.footnote)
                        Spacer()
                        if store.totalSessions > 0 {
                            Text("\(store.totalSessions)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                // Strava status
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.stravaAuthenticated ? Color.orange : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(viewModel.stravaAuthenticated ? "Strava conectado" : "Strava no conectado")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .animation(.easeInOut(duration: 0.25), value: viewModel.workoutMode)
        }
    }
}

#Preview {
    NavigationStack {
        SetupView()
    }
    .environmentObject(WorkoutViewModel())
}
