import Foundation
import CryptoKit
import Network

// MARK: - PKCE

enum PKCE {
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthError: LocalizedError {
    case badCode
    case stateMismatch
    case exchangeFailed(String)
    case timeout
    case portBusy
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .badCode: "Could not parse the code — paste it exactly as shown"
        case .stateMismatch: "Security check (state) mismatch — restart the sign-in"
        case .exchangeFailed(let detail): "Token exchange failed: \(detail)"
        case .timeout: "Sign-in timed out — try again"
        case .portBusy: "Port 1455 is in use (another codex sign-in may be running) — close it and retry"
        case .accessDenied: "Sign-in was denied"
        }
    }
}

// MARK: - Claude (Anthropic OAuth, paste-a-code PKCE flow)

/// Sign-in via Claude Code's public OAuth client. After approval the browser
/// page shows a code ("code#state") that the user pastes into the panel.
enum ClaudeAuth {
    static let clientID = "REDACTED-CLAUDE-CLIENT-ID"
    private static let authorizeURL = "https://claude.ai/oauth/authorize"
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let scopes = "org:create_api_key user:profile user:inference"

    struct Session: Sendable {
        let url: URL
        let verifier: String
        let state: String
    }

    static func beginLogin() -> Session {
        let verifier = PKCE.generateVerifier()
        let state = PKCE.randomState()
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Session(url: components.url!, verifier: verifier, state: state)
    }

    /// Exchanges the pasted "code" or "code#state" input for tokens
    static func exchange(codeInput: String, session: Session) async throws -> StoredCredentials {
        let trimmed = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthError.badCode }
        let pieces = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = pieces[0]
        let state = pieces.count > 1 ? pieces[1] : session.state
        guard state == session.state else { throw OAuthError.stateMismatch }

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": session.verifier,
        ]
        return try await requestToken(body: body)
    }

    static func refresh(_ credentials: StoredCredentials) async -> StoredCredentials? {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else { return nil }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        guard var renewed = try? await requestToken(body: body) else { return nil }
        if renewed.refreshToken == nil { renewed.refreshToken = refreshToken }
        renewed.plan = renewed.plan ?? credentials.plan
        return renewed
    }

    private static func requestToken(body: [String: String]) async throws -> StoredCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? "HTTP \(status)"
            throw OAuthError.exchangeFailed(detail)
        }

        var expires: Date?
        if let seconds = json["expires_in"] as? Double {
            expires = Date(timeIntervalSinceNow: seconds)
        }
        let account = json["account"] as? [String: Any]
        return StoredCredentials(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            idToken: nil,
            accountId: account?["uuid"] as? String,
            expiresAt: expires,
            plan: (json["subscription_type"] as? String) ?? (account?["subscription_type"] as? String)
        )
    }
}

// MARK: - Codex (OpenAI OAuth, localhost-callback PKCE flow)

/// Sign-in via the codex CLI's public OAuth client: the browser opens and,
/// after approval, auth.openai.com redirects to `localhost:1455/auth/callback`;
/// the in-app mini server catches the code and exchanges it for tokens.
enum CodexAuth {
    static let clientID = "app_REDACTED"
    private static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let callbackPort: UInt16 = 1455
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scopes = "openid profile email offline_access"

    struct Session: Sendable {
        let url: URL
        let verifier: String
        let state: String
    }

    static func beginLogin() -> Session {
        let verifier = PKCE.generateVerifier()
        let state = PKCE.randomState()
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
        ]
        return Session(url: components.url!, verifier: verifier, state: state)
    }

    /// Waits for the callback and exchanges the code (the browser must already
    /// be opened at `beginLogin().url`)
    static func completeLogin(session: Session, timeoutSeconds: Double = 300) async throws -> StoredCredentials {
        let code = try await CallbackServer.waitForCode(
            expectedState: session.state,
            port: callbackPort,
            timeoutSeconds: timeoutSeconds
        )

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": session.verifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? "HTTP \(status)"
            throw OAuthError.exchangeFailed(detail)
        }

        let idToken = json["id_token"] as? String
        var expires: Date?
        if let seconds = json["expires_in"] as? Double {
            expires = Date(timeIntervalSinceNow: seconds)
        }
        return StoredCredentials(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            idToken: idToken,
            accountId: idToken.flatMap(chatgptAccountId),
            expiresAt: expires,
            plan: idToken.flatMap(planFromIDToken)
        )
    }

    /// ChatGPT account ID from the id_token JWT — needed for the usage
    /// request's `ChatGPT-Account-Id` header
    static func chatgptAccountId(_ idToken: String) -> String? {
        (jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    static func planFromIDToken(_ idToken: String) -> String? {
        (jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Callback server

/// Mini HTTP server that binds to loopback only and waits for a single
/// OAuth callback. Shuts itself down after responding.
enum CallbackServer {
    static func waitForCode(expectedState: String, port: UInt16, timeoutSeconds: Double) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw OAuthError.portBusy
        }

        let box = ResultBox(listener: listener)
        return try await withCheckedThrowingContinuation { continuation in
            box.continuation = continuation

            listener.stateUpdateHandler = { state in
                if case .failed = state { box.finish(.failure(OAuthError.portBusy)) }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }
                    let result = Self.parseCallback(request: request, expectedState: expectedState)
                    let html: String
                    switch result {
                    case .success:
                        html = "<html><body style='font-family:sans-serif'><h3>Sign-in complete ✓</h3><p>You can close this window and return to QuotaPanel.</p></body></html>"
                    case .failure:
                        html = "<html><body style='font-family:sans-serif'><h3>Sign-in failed</h3><p>Try again from QuotaPanel.</p></body></html>"
                    case nil:
                        // non-callback request (e.g. favicon) — close it and keep waiting
                        connection.cancel()
                        return
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        if let result { box.finish(result) }
                    })
                }
            }
            listener.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                box.finish(.failure(OAuthError.timeout))
            }
        }
    }

    /// Extracts the callback result from an HTTP request; nil if not the callback path
    static func parseCallback(request: String, expectedState: String) -> Result<String, Error>? {
        guard let requestLine = request.split(separator: "\r\n").first,
              requestLine.hasPrefix("GET ")
        else { return .failure(OAuthError.badCode) }
        let target = requestLine.split(separator: " ")
        guard target.count >= 2 else { return .failure(OAuthError.badCode) }
        let path = String(target[1])
        guard path.hasPrefix("/auth/callback") else { return nil }
        guard let components = URLComponents(string: path) else { return .failure(OAuthError.badCode) }
        let query = components.queryItems ?? []
        if query.contains(where: { $0.name == "error" }) {
            return .failure(OAuthError.accessDenied)
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(OAuthError.badCode)
        }
        guard query.first(where: { $0.name == "state" })?.value == expectedState else {
            return .failure(OAuthError.stateMismatch)
        }
        return .success(code)
    }

    /// Resumes the continuation exactly once and cancels the listener
    private final class ResultBox: @unchecked Sendable {
        var continuation: CheckedContinuation<String, Error>?
        private let listener: NWListener
        private let lock = NSLock()
        private var finished = false

        init(listener: NWListener) {
            self.listener = listener
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished, let continuation else { return }
            finished = true
            listener.cancel()
            continuation.resume(with: result)
        }
    }
}
