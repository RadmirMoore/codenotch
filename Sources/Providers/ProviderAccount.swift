import Foundation

/// Whose readings these are.
///
/// Worth showing plainly, because Codenotch never signs in — it borrows a
/// credential the owning tool already holds, and there is nothing stopping that
/// credential belonging to a different account than the one you are sitting in
/// front of. It happened during development: a browser sign-in created a second,
/// empty Cursor account, and the notch spent an afternoon faithfully reporting
/// somebody else's zero. A visible email would have caught it in seconds.
struct ProviderAccount: Equatable {
    /// Email or display name, where the credential carries one.
    let label: String?
    /// The plan, named the way the provider names it.
    let plan: String?
    /// Which app's credential this borrows.
    let source: String
    /// The provider's own usage page, for checking this against the source.
    let manageURL: URL?

    /// One line for the settings row.
    var summary: String {
        [label, plan.map { $0.capitalized }, L10n.t("via \(source)")]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Where to go when a provider has no usable credential.
///
/// Codenotch cannot sign anyone in — it reads a credential the owning tool
/// holds — so the most it can honestly do is open that tool, or say what to do
/// when there is nothing to open.
enum SignInRoute: Equatable {
    /// The provider owns the session and can present its own sign-in window.
    /// The only case where Codenotch genuinely signs anyone in or out.
    case modal(name: String)
    /// Launch the app that owns the credential.
    case openApp(bundleID: String, name: String)
    /// Nothing to launch; Claude Code is a command, not an application.
    case guidance(String)
    /// A command-line tool signs in from the terminal: the button runs its
    /// login command in a new terminal window, which opens the browser.
    case command(String, name: String, install: URL? = nil)

    var actionTitle: String? {
        switch self {
        case .modal(let name):     return L10n.t("Sign in to \(name)")
        case .openApp(_, let name): return L10n.t("Open \(name)")
        case .guidance:            return nil
        case .command(_, let name, _): return L10n.t("Sign in to \(name)")
        }
    }

    var explanation: String {
        switch self {
        case .modal(let name):      return L10n.t("Sign in to \(name) to read this account.")
        case .openApp(_, let name):
            if name == "Antigravity" {
                return L10n.t("Ensure Antigravity IDE is running to read this account.")
            }
            return L10n.t("Sign in with \(name) to read this account.")
        case .guidance(let text):   return text
        case .command(let command, let name, _):
            return command.hasSuffix("login")
                ? L10n.t("Runs \(command) in your terminal; it opens the browser to sign in and saves the session this reads.")
                : L10n.t("Runs \(command) in your terminal; sign in there with /login and the notch reads the session.")
        }
    }

    /// How to change which account is being read.
    ///
    /// Always somewhere else: the credential belongs to the tool that issued
    /// it, so switching accounts is that tool's business and this can only say
    /// where to go.
    var switchHint: String {
        switch self {
        case .modal(let name):      return L10n.t("Sign out in the \(name) window to use another account.")
        case .openApp(_, let name): return L10n.t("Switch accounts in \(name); the notch follows.")
        case .guidance, .command:   return L10n.t("Switch accounts in the tool that owns it; the notch follows.")
        }
    }

    /// What switching a provider off does and does not reach, said plainly, so
    /// nobody switches off here expecting to be signed out of the tool as well.
    var signOutCaveat: String {
        switch self {
        case .modal(let name):
            return L10n.t("Signs out of \(name) — the session belongs to Codenotch.")
        case .openApp(_, let name):
            return L10n.t("You stay signed in to \(name) — end that session in \(name) itself.")
        case .guidance, .command:
            return L10n.t("You stay signed in to the tool that owns the account.")
        }
    }
}

extension UsageProvider {
    /// Providers that borrow no credential have no account to show.
    ///
    /// A default for a requirement *declared in the protocol* is fine — the
    /// requirement keeps dispatch dynamic, so an implementation still wins. It
    /// is declaring a method only in an extension that quietly breaks.
    func account() -> ProviderAccount? { nil }

    var signInRoute: SignInRoute {
        .guidance(L10n.t("Sign in with the tool that owns this account."))
    }

    /// Nothing of our own to discard, by default.
    func signOut() async {}

    /// No modal of our own to show, by default — `UsageStore.signIn` falls back
    /// to the route.
    func presentSignIn() {}

    /// Providers that hold nothing in memory have nothing to drop.
    func forgetCachedCredential() {}
}
