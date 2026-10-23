import Foundation

/// Where the `X-Firebase-AppCheck` token of `lookup` and `claim` comes from
/// (remote protocol §5.4, §5.5; concept §10).
enum AppCheckSource: Sendable, Equatable {
    #if DEBUG
    /// The emulator's fixed value. A release build has no such path (#51).
    case debugToken(String)
    #endif
    /// App Attest, exchanged for tokens through App Check's REST API — there is
    /// no Firebase SDK on the phone (#33).
    case appAttest(AppAttestApp)

    /// The provider for one relay; the App Check calls share its API key and transport.
    func provider(for endpoint: RelayEndpoint, transport: any RelayTransport) -> any AppCheckProvider {
        switch self {
        #if DEBUG
        case .debugToken(let token):
            FixedAppCheck(token: token)
        #endif
        case .appAttest(let app):
            AppAttestAppCheck(app: app, client: RelayClient(endpoint: endpoint, transport: transport))
        }
    }
}

/// The Firebase app App Check knows the phone as.
struct AppAttestApp: Sendable, Equatable {
    /// The project ID, which App Check takes in place of the project number.
    let project: String
    /// `1:…:ios:…`, from the production configuration (#52).
    let appId: String
    var baseURL = URL(string: "https://firebaseappcheck.googleapis.com/v1")!

    /// `projects/{project}/apps/{appId}:{method}`.
    func url(_ method: String) -> URL {
        baseURL.appending(path: "projects/\(project)/apps/\(appId):\(method)")
    }
}

/// Hands out App Check tokens for the relay's calls that check them.
protocol AppCheckProvider: Sendable {
    /// `limitedUse` for a call that consumes its token (`claim`); otherwise one
    /// that may be reused while it lives (`lookup`).
    func token(limitedUse: Bool) async throws -> String
}

enum AppCheckError: Error, Equatable, Sendable {
    /// This device or build has no App Attest: a simulator, an old iPhone, a
    /// build without the entitlement.
    case unsupported
    /// Apple or App Check would not vouch for this app.
    case refused
}

#if DEBUG
struct FixedAppCheck: AppCheckProvider {
    let token: String

    func token(limitedUse: Bool) async throws -> String { token }
}
#endif
