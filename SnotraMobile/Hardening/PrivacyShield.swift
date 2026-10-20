/// When the app's content has to be covered (#27, concept §6).
///
/// - While the screen is recorded, mirrored or shared, the content would leave
///   the phone.
/// - While the app is not active, iOS may take the snapshot it shows in the app
///   switcher, and Control Center or a system prompt sits on top of it.
enum PrivacyShield: Equatable {
    case captured
    case inactive

    /// The shield to show, or `nil` when the content may be seen. Capture wins,
    /// because it is the one the user has to be told about.
    static func required(isActive: Bool, isCaptured: Bool) -> PrivacyShield? {
        if isCaptured {
            return .captured
        }
        return isActive ? nil : .inactive
    }
}
