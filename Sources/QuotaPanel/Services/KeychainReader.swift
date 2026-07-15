import Foundation
import Security

/// Reads Claude Code's OAuth credentials (read-only, never writes).
///
/// Priority order:
/// 1. The `/usr/bin/security` CLI — it has a stable code identity, so one
///    "Always Allow" survives rebuilds without re-prompting.
/// 2. The Keychain API directly (SecItemCopyMatching).
/// 3. The credentials file — `$CLAUDE_CONFIG_DIR/.credentials.json` if that env
///    var is set, otherwise `~/.claude/.credentials.json` (Linux/legacy layout).
enum KeychainReader {
    static let claudeService = "Claude Code-credentials"

    static func readClaudeCredentialsJSON() -> Data? {
        if let data = readViaSecurityCLI(service: claudeService), !data.isEmpty {
            return data
        }
        if let data = readViaAPI(service: claudeService), !data.isEmpty {
            return data
        }
        // Honor CLAUDE_CONFIG_DIR (Claude Code lets users relocate its config
        // dir); fall back to the default ~/.claude layout.
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let configDir = (env?.isEmpty == false)
            ? URL(fileURLWithPath: env!)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return try? Data(contentsOf: configDir.appendingPathComponent(".credentials.json"))
    }

    private static func readViaSecurityCLI(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // security -w output ends with a newline
        if let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        }
        return data
    }

    private static func readViaAPI(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}
