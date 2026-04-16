import Foundation

struct WorkoutSession: Codable, Identifiable {
    let id:        UUID
    let startDate: Date
    let endDate:   Date
    let duration:  TimeInterval
    let pecesT:    Int
    let pecesM:    Int
    let mode:      WorkoutMode

    init(startDate: Date, endDate: Date, duration: TimeInterval,
         pecesT: Int, pecesM: Int, mode: WorkoutMode) {
        self.id        = UUID()
        self.startDate = startDate
        self.endDate   = endDate
        self.duration  = duration
        self.pecesT    = pecesT
        self.pecesM    = pecesM
        self.mode      = mode
    }

    var totalPeces: Int { pecesT + pecesM }

    var formattedDuration: String {
        let h = Int(duration) / 3600
        let m = Int(duration) / 60 % 60
        let s = Int(duration) % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%02dm %02ds", m, s)
    }

    var shortDuration: String {
        let h = Int(duration) / 3600
        let m = Int(duration) / 60 % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%02dm", m)
    }

    var modeLabel: String {
        switch mode {
        case .timed: return "⏱ Tiempo"
        case .free:  return "🆓 Libre"
        }
    }
}
