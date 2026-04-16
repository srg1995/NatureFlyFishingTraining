import SwiftUI

struct CountersPageView: View {
    @EnvironmentObject var viewModel: WorkoutViewModel
    private var isRunning: Bool { viewModel.workoutState == .running }
    private var isFree:    Bool { viewModel.workoutMode  == .free }

    var body: some View {
        VStack(spacing: 10) {
            Text(viewModel.formattedDisplay)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundStyle(timerColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)


            // Peces T
            CounterRow(
                label: "🐟 T",
                value: viewModel.pecesT,
                onIncrement: viewModel.incrementPecesT,
                onDecrement: viewModel.decrementPecesT,
                color: .red
            )

            Divider()

            // Peces M
            CounterRow(
                label: "🐟 M",
                value: viewModel.pecesM,
                onIncrement: viewModel.incrementPecesM,
                onDecrement: viewModel.decrementPecesM,
                color: .blue
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
    private var timerColor: Color {
        guard viewModel.workoutMode == .timed else { return .teal }
        let total = Double(viewModel.selectedDuration * 60)
        let ratio = viewModel.remainingTime / max(1, total)
        switch ratio {
        case 0.5...:    return .green
        case 0.2..<0.5: return .yellow
        default:         return .red
        }
    }
}

// MARK: - CounterRow

private struct CounterRow: View {
    let label: String
    let value: Int
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            // Label
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, alignment: .leading)
                .padding(.leading, 4)

            Spacer()

            // Minus
            Button(action: onDecrement) {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .tint(value > 0 ? color : .gray)
            .disabled(value == 0)

            // Count
            Text("\(value)")
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(minWidth: 40)
                .multilineTextAlignment(.center)

            // Plus
            Button(action: onIncrement) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .tint(color)

            Spacer(minLength: 4)
        }
    }
}



#Preview {
    let vm = WorkoutViewModel()
    vm.pecesT = 4
    vm.pecesM = 7
    return CountersPageView()
        .environmentObject(vm)
}


#Preview("En curso") {
    let vm = WorkoutViewModel()
    vm.workoutMode = .timed
    return TimerPageView()
        .environmentObject(vm)
}

#Preview("Modo libre") {
    let vm = WorkoutViewModel()
    vm.workoutMode = .free
    return TimerPageView()
        .environmentObject(vm)
}
