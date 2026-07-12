import SwiftUI

/// Offline summary: totals over the last 24 h / 7 days / 30 days, each with
/// its input/cache/output composition. Computed on demand.
struct HistoryView: View {
    let state: AppState
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = state.activity(for: provider) {
                ForEach(activity.history) { bucket in
                    bucketRow(bucket)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Computing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await state.loadActivity() }
    }

    private func bucketRow(_ bucket: HistoryBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(bucket.label)
                    .font(.callout)
                Spacer()
                Text("\(formatTokenCount(bucket.parts.total)) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if bucket.parts.total > 0 {
                PartsCaptionView(parts: bucket.parts, percent: 100)
                SegmentedBarView(percent: 100, parts: bucket.parts)
            } else {
                Text("No usage in this period")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
