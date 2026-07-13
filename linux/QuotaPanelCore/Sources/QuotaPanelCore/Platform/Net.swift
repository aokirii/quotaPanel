import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Portable HTTP. On Linux `URLSession` lives in FoundationNetworking; this
/// wrapper also avoids depending on `URLSession.data(for:)` being present by
/// bridging the closure-based `dataTask` into async/await. Providers call
/// `HTTP.data(for:)` instead of `URLSession.shared.data(for:)`.
enum HTTP {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
    }
}
