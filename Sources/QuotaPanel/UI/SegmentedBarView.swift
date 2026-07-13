import SwiftUI

/// Token-type segment colors (same as ai-token-tracker)
enum PartColors {
    static let input = Color(red: 0.91, green: 0.52, blue: 0.23)   // #e8843a
    static let cache = Color(red: 0.24, green: 0.65, blue: 0.44)   // #3ea76f
    static let output = Color(red: 0.90, green: 0.81, blue: 0.31)  // #e6cf4f
}

extension Provider {
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)    // #d97757
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)     // #10a37f
        case .cursor: Color(red: 0.45, green: 0.47, blue: 0.55)    // neutral slate
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)    // #4285f4
        case .copilot: Color(red: 0.51, green: 0.31, blue: 0.87)   // #8250df
        case .droid: Color(red: 0.80, green: 0.35, blue: 0.20)     // factory ember
        case .windsurf: Color(red: 0.20, green: 0.91, blue: 0.73)  // #34e8bb
        case .zed: Color(red: 0.03, green: 0.31, blue: 1.00)       // #084eff
        case .warp: Color(red: 0.58, green: 0.55, blue: 0.71)      // #938bb4
        case .amp: Color(red: 0.86, green: 0.15, blue: 0.15)       // #dc2626
        case .augment: Color(red: 0.39, green: 0.40, blue: 0.95)   // #6366f1
        case .kilo: Color(red: 0.95, green: 0.44, blue: 0.15)      // #f27027
        case .kiro: Color(red: 1.00, green: 0.60, blue: 0.00)      // #ff9900
        case .opencode: Color(red: 0.23, green: 0.51, blue: 0.96)  // #3b82f6
        case .opencodego: Color(red: 0.23, green: 0.51, blue: 0.96) // #3b82f6
        case .antigravity: Color(red: 0.38, green: 0.73, blue: 0.49) // #60ba7e
        case .devin: Color(red: 0.27, green: 0.71, blue: 0.70)     // #46b482
        case .jetbrains: Color(red: 1.00, green: 0.20, blue: 0.60) // #ff3399
        case .qoder: Color(red: 0.06, green: 0.73, blue: 0.51)     // #10b981
        case .commandcode: Color(red: 0.42, green: 0.45, blue: 0.50) // near-black, lightened for the dot
        case .crossmodel: Color(red: 0.49, green: 0.23, blue: 0.93) // #7c3aed
        case .manus: Color(red: 0.20, green: 0.20, blue: 0.18)     // #34322d
        case .codebuff: Color(red: 0.27, green: 1.00, blue: 0.00)  // #44ff00
        }
    }
}

/// Bar filled to `percent`, split into input/cache/output segments.
/// Draws a solid fill when `parts` is nil or empty.
struct SegmentedBarView: View {
    let percent: Double
    let parts: TokenParts?
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let fill = geo.size.width * min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let parts, parts.total > 0 {
                    let f = parts.fractions
                    HStack(spacing: 0) {
                        Rectangle().fill(PartColors.input).frame(width: fill * f.input)
                        Rectangle().fill(PartColors.cache).frame(width: fill * f.cache)
                        Rectangle().fill(PartColors.output).frame(width: fill * f.output)
                    }
                    .clipShape(Capsule())
                } else {
                    Capsule().fill(tint).frame(width: fill)
                }
            }
        }
        .frame(height: 6)
    }
}

/// "input 2% · cache 19% · output 6%" row — each share scaled to `percent`
struct PartsCaptionView: View {
    let parts: TokenParts
    let percent: Double

    var body: some View {
        let f = parts.fractions
        HStack(spacing: 4) {
            legend("input", f.input, PartColors.input)
            Text("·").foregroundStyle(.quaternary)
            legend("cache", f.cache, PartColors.cache)
            Text("·").foregroundStyle(.quaternary)
            legend("output", f.output, PartColors.output)
        }
        .font(.caption2)
    }

    private func legend(_ name: String, _ fraction: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(name) \(formatPercent(fraction * percent))%")
                .foregroundStyle(.secondary)
        }
    }
}
