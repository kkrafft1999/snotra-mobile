import Foundation
import LocalAuthentication

/// Asks the person holding the phone to prove it is theirs before an answer
/// lets the agent act (concept R5, snotra#980: a confirmation with user presence).
protocol UserPresence: Sendable {
    /// False on a phone without a passcode: nothing can be confirmed there.
    var canConfirm: Bool { get }
    /// True once the owner confirmed; false when they cancelled or failed.
    func confirm(_ reason: String) async -> Bool
}

/// Face ID, Touch ID or the device passcode. A phone without a passcode
/// cannot confirm, so it cannot allow anything either.
struct DeviceOwnerPresence: UserPresence {
    var canConfirm: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
