import AppKit
import Foundation
import Observation

/// Ayarlar'daki Hesaplar bölümünün durum makinesi: giriş akışlarını yürütür,
/// sonucu CredentialStore'a yazar ve panelin yenilenmesini tetikler.
@MainActor
@Observable
final class AuthManager {
    /// Claude girişi kod bekliyorsa aktif oturum
    var claudeSession: ClaudeAuth.Session?
    var claudeCodeInput = ""
    /// Codex girişi tarayıcı callback'ini bekliyor mu
    var codexWaiting = false
    var busy: Provider?
    var errorMessage: [Provider: String] = [:]

    /// Giriş/çıkış sonrası panelin verisini tazeler (AppState bağlar)
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

    // MARK: - Çıkış

    /// Yalnızca QuotaPanel'in kendi kimliğini siler; CLI'ların kimliklerine dokunmaz
    func logout(_ provider: Provider) async {
        CredentialStore.delete(provider)
        errorMessage[provider] = nil
        await onCredentialsChanged?()
    }
}
