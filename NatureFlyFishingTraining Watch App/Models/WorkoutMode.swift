import Foundation

enum WorkoutState {
    case idle, running, paused, finished
}

enum WorkoutMode: String, Codable, CaseIterable {
    case timed = "Tiempo"
    case free  = "Libre"
}
