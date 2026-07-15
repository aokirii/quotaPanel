import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// refresh_token flow for Google credentials stored by a QuotaPanel front-end's
/// in-app sign-in (Gemini and Antigravity both authenticate against Google's
/// OAuth endpoint, each with its own client from oauth-clients.json).
enum GoogleToken {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Returns renewed credentials, keeping the old refresh token and id_token
    /// when Google omits them from the response. nil when the client is not
    /// configured or the refresh fails.
    static func refresh(_ credentials: StoredCredentials, client: OAuthClients.Client) async -> StoredCredentials? {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty,
              !client.id.isEmpty, !client.secret.isEmpty
        else { return nil }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id=\(client.id)",
            "client_secret=\(client.secret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&").data(using: .utf8)

        guard let (data, response) = try? await HTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }

        var renewed = credentials
        renewed.accessToken = token
        if let fresh = json["refresh_token"] as? String, !fresh.isEmpty { renewed.refreshToken = fresh }
        if let idToken = json["id_token"] as? String, !idToken.isEmpty { renewed.idToken = idToken }
        if let seconds = json["expires_in"] as? Double { renewed.expiresAt = Date(timeIntervalSinceNow: seconds) }
        return renewed
    }
}
