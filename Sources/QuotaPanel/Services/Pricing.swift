import Foundation

/// Model price table (USD / million tokens).
/// Source: current platform.claude.com prices (July 2026).
/// When prices change, this is the only file to update.
enum Pricing {
    struct ModelPrice: Sendable {
        let input: Double
        let output: Double
        var cacheWrite5m: Double { input * 1.25 }
        var cacheWrite1h: Double { input * 2.0 }
        var cacheRead: Double { input * 0.1 }
    }

    /// Price by model name; nil for unknown models (excluded from cost)
    static func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        if m.contains("<synthetic>") { return nil }
        if m.contains("fable") || m.contains("mythos") { return ModelPrice(input: 10, output: 50) }
        if m.contains("opus") { return ModelPrice(input: 5, output: 25) }
        if m.contains("sonnet") { return ModelPrice(input: 3, output: 15) }
        if m.contains("haiku") { return ModelPrice(input: 1, output: 5) }
        return nil
    }

    /// Estimated cost (USD) of one message's token usage
    static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        cacheRead: Int
    ) -> Double {
        guard let p = price(for: model) else { return 0 }
        let mtok = 1_000_000.0
        return Double(inputTokens) / mtok * p.input
            + Double(outputTokens) / mtok * p.output
            + Double(cacheWrite5m) / mtok * p.cacheWrite5m
            + Double(cacheWrite1h) / mtok * p.cacheWrite1h
            + Double(cacheRead) / mtok * p.cacheRead
    }
}
