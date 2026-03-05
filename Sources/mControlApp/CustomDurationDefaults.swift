import Foundation

enum CustomDurationDefaults {
    static let minimumMinutes = 1
    static let maximumMinutes = 10_080
    static let fallbackMinutes = 60

    static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, minimumMinutes), maximumMinutes)
    }
}
