/// Whether this phone is paired with a Snotra desktop installation.
///
/// The remote is off by default (concept R7): until a pairing exists, the app
/// can neither read nor send anything.
enum PairingState: Equatable {
    case notPaired
    case paired

    var canSendMessages: Bool {
        self == .paired
    }
}
