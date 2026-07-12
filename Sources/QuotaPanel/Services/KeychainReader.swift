import Foundation
import Security

/// Claude Code'un OAuth kimlik bilgisini okur (salt-okunur, asla yazmaz).
///
/// Öncelik sırası:
/// 1. `/usr/bin/security` CLI — sabit kimlikli olduğu için kullanıcı bir kez
///    "Her Zaman İzin Ver" derse yeniden derlemelerde tekrar sormaz.
/// 2. Doğrudan Keychain API (SecItemCopyMatching).
/// 3. `~/.claude/.credentials.json` dosyası (Linux/eski kurulum düzeni).
enum KeychainReader {
    static let claudeService = "Claude Code-credentials"

    static func readClaudeCredentialsJSON() -> Data? {
        if let data = readViaSecurityCLI(service: claudeService), !data.isEmpty {
            return data
        }
        if let data = readViaAPI(service: claudeService), !data.isEmpty {
            return data
        }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: fileURL)
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
        // security -w çıktısının sonunda newline olur
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
