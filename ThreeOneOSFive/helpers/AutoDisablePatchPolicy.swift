import Foundation

/// Centralized automatic patch restore policy.
/// Keeping defaults here prevents UI, persistence, and scheduling layers from drifting.
enum AutoDisablePatchPolicy {
    static let defaultEnabled = true
    static let defaultTimeoutSeconds: TimeInterval = 8

    static func deadline(from start: Date, timeoutSeconds: TimeInterval = defaultTimeoutSeconds) -> Date {
        start.addingTimeInterval(timeoutSeconds)
    }
}
