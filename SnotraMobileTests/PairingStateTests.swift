import Testing
@testable import SnotraMobile

struct PairingStateTests {
    @Test func anUnpairedPhoneCannotSend() {
        #expect(PairingState.notPaired.canSendMessages == false)
    }

    @Test func aPairedPhoneCanSend() {
        #expect(PairingState.paired.canSendMessages)
    }
}
