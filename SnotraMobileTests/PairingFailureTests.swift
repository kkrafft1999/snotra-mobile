import DeviceCheck
import Foundation
import Testing
@testable import SnotraMobile

/// Which error ends a pairing with which message, and what of it reaches the log (#63).
struct PairingFailureTests {
    @Test func appAttestFailingOnTheDeviceIsNotARefusalOfTheApp() {
        #expect(DeviceAppAttest.failure(of: .unknownSystemFailure) as? AppCheckError == .deviceFailure)
        #expect(DeviceAppAttest.failure(of: .invalidInput) as? AppCheckError == .deviceFailure)
        #expect(DeviceAppAttest.failure(of: .featureUnsupported) as? AppCheckError == .unsupported)
        #expect(DeviceAppAttest.failure(of: .invalidKey) is AppAttestKeyInvalid)
        #expect(DeviceAppAttest.failure(of: .serverUnavailable) as? RelayError == .unavailable)
    }

    @Test func appCheckErrorsNameTheirOwnCause() {
        #expect(PairingFlow.failure(of: AppCheckError.unsupported) == .deviceUnsupported)
        #expect(PairingFlow.failure(of: AppCheckError.refused) == .appNotAccepted)
        #expect(PairingFlow.failure(of: AppCheckError.deviceFailure) == .deviceFailure)
    }

    @Test(arguments: [RelayError.unreachable, .unavailable, .rateLimited])
    func noAnswerOrComeBackLaterIsUnreachable(_ error: RelayError) {
        #expect(PairingFlow.failure(of: error) == .unreachable)
    }

    @Test(arguments: [RelayError.unauthorized, .refused, .invalidRequest, .invalidResponse, .busy, .tooLarge])
    func anyOtherAnswerIsARefusalByTheRelay(_ error: RelayError) {
        #expect(PairingFlow.failure(of: error) == .relayRefused)
    }

    @Test func theLoggedPathLeavesIdsOut() {
        #expect(LogText.path(of: URL(string: "https://relay.snotra-ai.dev/pairings/0111/claim"))
            == "relay.snotra-ai.dev/pairings/…/claim")
        #expect(LogText.path(of: URL(string: "https://db.example/channels/AbC-12_x/meta.json?auth=secret"))
            == "db.example/channels/…/meta.json")
        #expect(LogText.path(of: URL(string: "https://appcheck.test/v1/projects/snotra-ai/apps/1:123:ios:abc:exchangeAppAttestAttestation"))
            == "appcheck.test/…/projects/…/apps/…:exchangeAppAttestAttestation")
    }

    @Test func aLoggedErrorNamesOnlyItsCaseOrItsCode() {
        #expect(LogText.error(RelayError.unauthorized) == "RelayError.unauthorized")
        #expect(LogText.error(AppCheckError.deviceFailure) == "AppCheckError.deviceFailure")
        #expect(LogText.error(URLError(.timedOut)) == "URLError -1001")
        #expect(LogText.error(CocoaError(.fileReadNoPermission)) == "NSCocoaErrorDomain 257")
    }
}
