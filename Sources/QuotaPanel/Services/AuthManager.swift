import AppKit
import Foundation
import Observation

/// State machine for the Accounts section in Settings: runs the sign-in
/// flows, writes results to CredentialStore, and triggers a panel refresh.
@MainActor
@Observable
final class AuthManager {
    /// Active session while the Claude sign-in is waiting for a code
    var claudeSession: ClaudeAuth.Session?
    var claudeCodeInput = ""
    /// Providers whose sign-in is waiting on the browser (callback or device approval)
    var waiting: Set<Provider> = []
    /// The device code shown while the Copilot sign-in waits for approval
    var copilotUserCode: String?
    var busy: Provider?
    var errorMessage: [Provider: String] = [:]

    /// In-flight browser sign-ins, kept so the user can cancel one (e.g. after
    /// closing the browser tab) instead of waiting out the callback timeout.
    private var loginTasks: [Provider: Task<Void, Never>] = [:]

    /// Refreshes panel data after sign-in/out (wired up by AppState)
    var onCredentialsChanged: (() async -> Void)?

    func hasStoredLogin(_ provider: Provider) -> Bool {
        CredentialStore.load(provider) != nil
    }

    // MARK: - Claude

    func beginClaudeLogin() {
        errorMessage[.claude] = nil
        claudeCodeInput = ""
        let session = ClaudeAuth.beginLogin()
        claudeSession = session
        NSWorkspace.shared.open(session.url)
    }

    func completeClaudeLogin() async {
        guard let session = claudeSession else { return }
        busy = .claude
        defer { busy = nil }
        do {
            let credentials = try await ClaudeAuth.exchange(codeInput: claudeCodeInput, session: session)
            CredentialStore.save(credentials, for: .claude)
            claudeSession = nil
            claudeCodeInput = ""
            await onCredentialsChanged?()
        } catch {
            errorMessage[.claude] = error.localizedDescription
        }
    }

    func cancelClaudeLogin() {
        claudeSession = nil
        claudeCodeInput = ""
        errorMessage[.claude] = nil
    }

    // MARK: - Browser flows (Codex, Gemini, Antigravity, Copilot)

    /// Starts (or restarts) the browser sign-in for `provider`, keeping the
    /// task handle so `cancelBrowserLogin` can abort it.
    func startBrowserLogin(_ provider: Provider) {
        loginTasks[provider]?.cancel()
        loginTasks[provider] = Task { await beginBrowserLogin(provider) }
    }

    /// Aborts an in-flight browser sign-in and clears its waiting state — tears
    /// down the loopback listener / stops the device-code poll so the row goes
    /// straight back to "Sign in" and the callback port frees up for a retry.
    func cancelBrowserLogin(_ provider: Provider) {
        loginTasks[provider]?.cancel()
        loginTasks[provider] = nil
        waiting.remove(provider)
        copilotUserCode = nil
        busy = nil
        errorMessage[provider] = nil
    }

    /// Runs the browser-based sign-in for `provider`: Codex via its localhost
    /// callback, Gemini/Antigravity via the Google loopback flow, Copilot via
    /// the GitHub device flow.
    func beginBrowserLogin(_ provider: Provider) async {
        errorMessage[provider] = nil
        waiting.insert(provider)
        busy = provider
        defer {
            waiting.remove(provider)
            busy = nil
            loginTasks[provider] = nil
        }
        do {
            let credentials: StoredCredentials
            switch provider {
            case .codex:
                let session = CodexAuth.beginLogin()
                NSWorkspace.shared.open(session.url)
                credentials = try await CodexAuth.completeLogin(session: session)
            case .gemini, .antigravity:
                let client = provider == .gemini ? OAuthClients.gemini : OAuthClients.antigravity
                guard !client.id.isEmpty, !client.secret.isEmpty else {
                    throw OAuthError.missingClient(provider.displayName)
                }
                let session = GoogleAuth.beginLogin(client: client)
                NSWorkspace.shared.open(session.url)
                credentials = try await GoogleAuth.completeLogin(session: session)
            case .copilot:
                let clientID = OAuthClients.copilot.id
                guard !clientID.isEmpty else {
                    throw OAuthError.missingClient(provider.displayName)
                }
                let session = try await GitHubDeviceAuth.beginLogin(clientID: clientID)
                copilotUserCode = session.userCode
                defer { copilotUserCode = nil }
                NSWorkspace.shared.open(session.verificationURL)
                credentials = try await GitHubDeviceAuth.completeLogin(session: session, clientID: clientID)
            default:
                return
            }
            CredentialStore.save(credentials, for: provider)
            await onCredentialsChanged?()
        } catch is CancellationError {
            // User cancelled (or closed the browser and hit Cancel) — no error.
        } catch {
            // A cancel can also surface as the callback server's own error;
            // don't flash a message when we're already tearing down.
            if !Task.isCancelled {
                errorMessage[provider] = error.localizedDescription
            }
        }
    }

    // MARK: - Sign out

    /// Deletes only QuotaPanel's own credentials; CLI credentials are untouched
    func logout(_ provider: Provider) async {
        CredentialStore.delete(provider)
        errorMessage[provider] = nil
        await onCredentialsChanged?()
    }
}
