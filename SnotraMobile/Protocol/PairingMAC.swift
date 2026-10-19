import CryptoKit
import Foundation

/// `MAC_P` and `MAC_D` (§6): from the code alone, each side proves it holds the
/// other side's real keys.
enum PairingMAC {
    /// `T = lp(channelId) ‖ KB_D ‖ KB_P`.
    static func transcript(channelId: Data, desktopKeys: KeyBundle, phoneKeys: KeyBundle) -> Data {
        ProtocolBytes.lp(channelId) + desktopKeys.bytes + phoneKeys.bytes
    }

    /// `MAC_P`, which the phone sends with its claim.
    static func phone(code: PairingCode, transcript: Data) -> Data {
        mac(label: "snotra/v1 mac phone", code: code, transcript: transcript)
    }

    /// `MAC_D`, which the desktop writes on confirm.
    static func desktop(code: PairingCode, transcript: Data) -> Data {
        mac(label: "snotra/v1 mac desktop", code: code, transcript: transcript)
    }

    /// Checks the desktop's `MAC_D` in constant time. A wrong one means the keys in
    /// the channel are not the desktop's: the phone deletes the channel.
    static func isValidDesktopMAC(_ macD: Data, code: PairingCode, transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            macD,
            authenticating: ProtocolBytes.lp("snotra/v1 mac desktop") + transcript,
            using: code.macKey
        )
    }

    private static func mac(label: String, code: PairingCode, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: ProtocolBytes.lp(label) + transcript, using: code.macKey))
    }
}
