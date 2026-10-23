import Foundation

/// Where the relay lives: its endpoints (remote protocol §5), the Realtime
/// Database it streams from (§12) and the Identity Toolkit that turns its
/// custom tokens into ID tokens (§5.1).
struct RelayEndpoint: Sendable, Equatable {
    /// The name the pairing code's QR payload gives the relay (§4).
    let host: String
    /// The endpoints' base, ending in `/v1`.
    let relayURL: URL
    /// The database; the emulator's carries `?ns=<instance>`, and node paths go before that query.
    let databaseURL: URL
    let identityToolkitURL: URL
    /// The project's web API key — it names the project to the Identity Toolkit.
    let apiKey: String
    /// Where the `X-Firebase-AppCheck` token of `lookup` and `claim` comes from.
    let appCheck: AppCheckSource

    #if DEBUG
    /// The Firebase emulator of snotra-promotion (`docs/relay.md`, *Local
    /// preview*) on this Mac. The simulator reaches it at 127.0.0.1, which App
    /// Transport Security leaves alone as an IP address.
    static let emulator = RelayEndpoint(
        host: "127.0.0.1:5001",
        relayURL: URL(string: "http://127.0.0.1:5001/snotra-ai/europe-west1/relay/v1")!,
        databaseURL: URL(string: "http://127.0.0.1:9000/?ns=snotra-ai-relay")!,
        identityToolkitURL: URL(string: "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1")!,
        apiKey: "emulator-api-key",
        appCheck: .debugToken("emulator-app-check"))
    #endif

    /// The production relay of the Firebase project `snotra-ai` (snotra#1193).
    /// Its addresses are public; the API key and the iOS app's Firebase app ID
    /// (`1:<project number>:ios:<hash>`) come in at build time and stay out of
    /// the repository, as the desktop's key does (snotra#1211).
    static func production(apiKey: String, firebaseAppId: String) -> RelayEndpoint {
        RelayEndpoint(
            host: "relay.snotra-ai.dev",
            relayURL: URL(string: "https://relay.snotra-ai.dev/v1")!,
            databaseURL: URL(string: "https://snotra-ai-relay.europe-west1.firebasedatabase.app/")!,
            identityToolkitURL: URL(string: "https://identitytoolkit.googleapis.com/v1")!,
            apiKey: apiKey,
            appCheck: .appAttest(AppAttestApp(project: "snotra-ai", appId: firebaseAppId)))
    }

    /// The relays this build ships with (§4): a QR code that names any other host
    /// is refused, and a typed key goes to the first. Debug builds know the
    /// emulator, release builds production and nothing else.
    static var builtIn: [RelayEndpoint] {
        #if DEBUG
        [.emulator]
        #else
        // `ProductionRelayConfiguration` lives in `ProductionRelay.local.swift`,
        // which git ignores and `scripts/testflight.sh` writes. A release build
        // without it does not compile — it would know no relay at all.
        [.production(apiKey: ProductionRelayConfiguration.apiKey,
                     firebaseAppId: ProductionRelayConfiguration.firebaseAppId)]
        #endif
    }

    /// `/channels/{channelId}/{node}.json?auth=<ID token>`, the database's own query kept.
    func databaseNodeURL(channelId: Data, node: String, idToken: String, silent: Bool = false) -> URL {
        var components = URLComponents(url: databaseURL, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(base)/channels/\(channelId.base64URLEncodedString)/\(node).json"
        var items = (components.queryItems ?? []).filter { $0.name != "auth" && $0.name != "print" }
        items.append(URLQueryItem(name: "auth", value: idToken))
        if silent { items.append(URLQueryItem(name: "print", value: "silent")) }
        components.queryItems = items
        return components.url!
    }

    /// `…/v1/accounts:{method}?key=<API key>`, a call of the Identity Toolkit.
    func accountsURL(_ method: String) -> URL {
        identityToolkitURL.appending(path: "accounts:\(method)")
            .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
    }

    /// `…/apps/{app ID}:{method}`, a call of App Check's REST API such as
    /// `exchangeAppAttestAttestation`; `nil` where the relay takes a fixed token.
    func appCheckURL(_ method: String) -> URL? {
        guard case .appAttest(let app) = appCheck else { return nil }
        return app.url(method)
    }
}
