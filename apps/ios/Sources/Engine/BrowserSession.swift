import Foundation
import WebKit

/// The two web contexts the app runs, and the guarantee that they never mix.
///
/// `unauthed` keeps the original §7.1 promise — a non-persistent store that
/// shares nothing with Safari, the Facebook app, or the signed-in context, and
/// forgets everything when it goes away.
///
/// `authed` is the deliberate exception: a session has to survive relaunches or
/// the user signs in on every cold start. That means Facebook gets a stable
/// identity across launches for signed-in users, which is inherent to having a
/// session at all rather than something the design can avoid.
///
/// They are separate `WKWebsiteDataStore`s, so nothing crosses between them:
/// not cookies, not local storage, not caches. That isolation is the feature.
/// It keeps anonymous requests genuinely anonymous, keeps "logged out" testable
/// while a session exists, and leaves room for the likely future split where
/// anonymous users are served from the mobile stack and signed-in users from
/// desktop.
///
/// See `docs/decision-desktop-primary.md`.
enum BrowserSession: String, CaseIterable, Codable, Sendable {
    case authed
    case unauthed

    /// A persistent store for the signed-in context, a fresh one otherwise.
    ///
    /// `WKWebsiteDataStore.default()` is process-wide, so every `authed`
    /// webview shares one cookie jar — which is what lets a session obtained in
    /// a visible login webview be used by the engines afterwards. Each
    /// `unauthed` call returns a *new* non-persistent store, so two anonymous
    /// contexts cannot see each other either.
    var dataStore: WKWebsiteDataStore {
        switch self {
        case .authed: return .default()
        case .unauthed: return .nonPersistent()
        }
    }

    var isPersistent: Bool { self == .authed }
}

/// Which Facebook surface a webview is pretending to be.
///
/// The server keys purely off the UA string, and the two surfaces expose
/// genuinely different data — see `docs/surface-strategy.md`.
enum Surface: String, Codable, Sendable {
    /// Filters, sorting, listing ids, and the embedded GraphQL payload.
    case desktop
    /// WebLite. Paginates indefinitely; no filters, no payload, no ids.
    case mobile

    var userAgent: String {
        switch self {
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.7 Safari/605.1.15"
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"
        }
    }
}

extension WKWebViewConfiguration {
    /// Builds a configuration pinned to one session and one surface.
    static func make(session: BrowserSession) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = session.dataStore
        config.allowsInlineMediaPlayback = true
        config.suppressesIncrementalRendering = false
        return config
    }
}

/// Reads and clears the signed-in session.
///
/// Deliberately has no way to *create* one: signing in happens in a visible
/// webview against Facebook's own login page, so the app never sees, collects,
/// or stores a password. This type only observes the result.
@MainActor
enum SessionState {
    /// Facebook sets `c_user` (the account id) and `xs` (the session) on a
    /// successful login. Both present is the cheapest reliable signal, and it
    /// needs no request of our own.
    static func isSignedIn() async -> Bool {
        let cookies = await BrowserSession.authed.dataStore.httpCookieStore.allCookies()
        let facebook = cookies.filter { $0.domain.contains("facebook.com") }
        return facebook.contains { $0.name == "c_user" }
            && facebook.contains { $0.name == "xs" }
    }

    /// Signs out by discarding the persistent store's contents.
    ///
    /// Everything the signed-in context ever stored lives here, so this is the
    /// whole of "log out" — there is no server call to make, and the unauthed
    /// context is untouched because it is a different store.
    static func signOut() async {
        let store = BrowserSession.authed.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
