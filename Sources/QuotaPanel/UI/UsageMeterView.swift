import SwiftUI

/// One rate-limit window: label, progress bar, percent, and reset countdown.
/// With `parts` the bar is split into input/cache/output segments.
struct UsageMeterView: View {
    let window: RateWindow
    var parts: TokenParts?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.callout)
                Spacer()
                Text("\(formatPercent(window.clampedPercent))%")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            if let parts, parts.total > 0 {
                PartsCaptionView(parts: parts, percent: window.clampedPercent)
                SegmentedBarView(percent: window.clampedPercent, parts: parts)
            } else {
                ProgressView(value: window.clampedPercent, total: 100)
                    .tint(color)
            }
            if let resetsAt = window.resetsAt, resetsAt > Date() {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                    Text("Resets:")
                        .font(.caption)
                    Text(resetsAt, style: .relative)
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch window.clampedPercent {
        case ..<50: .green
        case ..<80: .yellow
        case ..<95: .orange
        default: .red
        }
    }
}
