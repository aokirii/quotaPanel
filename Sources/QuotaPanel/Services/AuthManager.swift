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
    /// Whether the Codex sign-in is waiting for the browser callback
    var codexWaiting = false
    var busy: Provider?
    var errorMessage: [Provider: String] = [:]

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

    // MARK: - Codex

    func beginCodexLogin() async {
        errorMessage[.codex] = nil
        let session = CodexAuth.beginLogin()
        codexWaiting = true
        busy = .codex
        defer {
            codexWaiting = false
            busy = nil
        }
        NSWorkspace.shared.open(session.url)
        do {
            let credentials = try await CodexAuth.completeLogin(session: session)
            CredentialStore.save(credentials, for: .codex)
            await onCredentialsChanged?()
        } catch {
            errorMessage[.codex] = error.localizedDescription
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
