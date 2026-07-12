import SwiftUI

/// Token tipi segment renkleri (ai-token-tracker ile aynı)
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
        }
    }
}

/// Doluluğu `percent` olan, girdi/önbellek/çıktı segmentlerine bölünmüş çubuk.
/// `parts` nil ya da boşsa tek renkli dolgu çizilir.
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

/// "girdi %2 · önbellek %19 · çıktı %6" satırı — her pay `percent`'e ölçekli
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
