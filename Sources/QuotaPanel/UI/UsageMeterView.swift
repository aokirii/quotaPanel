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
                    Text(Self.resetLabel(resetsAt))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Absolute reset time ("21:21", "tomorrow 21:21", "Mon 21:21", "Jul 20 21:21")
    /// instead of a verbose relative countdown. Locale-aware clock format.
    static func resetLabel(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return time }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
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
