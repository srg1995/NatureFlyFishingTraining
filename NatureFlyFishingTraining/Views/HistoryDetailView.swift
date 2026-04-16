import SwiftUI

struct HistoryDetailView: View {
    let session: WorkoutSession

    private var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "es_ES")
        return f.string(from: session.startDate)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {

                // Icono y fecha
                VStack(spacing: 2) {
                    Text("🎣")
                        .font(.title2)
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)

                Divider()

                // Modo y duración
                detailRow(icon: "dial.medium", label: "Modo",     value: session.modeLabel,          color: .teal)
                detailRow(icon: "timer",       label: "Duración", value: session.formattedDuration,   color: .white)

                Divider()

                // Peces T
                detailRow(icon: "fish.fill", label: "Peces T", value: "\(session.pecesT)", color: .red)

                // Peces M
                detailRow(icon: "fish.fill", label: "Peces M", value: "\(session.pecesM)", color: .blue)

                // Total
                detailRow(icon: "sum", label: "Total", value: "\(session.totalPeces)", color: .yellow)

                Divider()

                // Ganador entre T y M
                winnerBadge
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Detalle")
    }

    // MARK: - Helpers

    private func detailRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }

    private var winnerBadge: some View {
        Group {
            if session.pecesT > session.pecesM {
                badge(text: "🐟 T lidera", color: .red)
            } else if session.pecesM > session.pecesT {
                badge(text: "🐟 M lidera", color: .blue)
            } else if session.totalPeces > 0 {
                badge(text: "¡Empate!", color: .yellow)
            } else {
                badge(text: "Sin capturas", color: .gray)
            }
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack {
        HistoryDetailView(session: WorkoutSession(
            startDate: Date().addingTimeInterval(-3600),
            endDate:   Date(),
            duration:  3600,
            pecesT:    7,
            pecesM:    5,
            mode:      .timed
        ))
    }
}
