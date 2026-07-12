import SwiftUI

/// Heatmap: GitHub-style daily grid of the last 12 weeks + hour-of-day
/// punch card of the last 7 days. Computed on demand.
struct HeatmapView: View {
    let state: AppState
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activity = state.activity(for: provider) {
                HStack {
                    Text("Daily · last 12 weeks")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(formatTokenCount(activity.totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                dailyGrid(activity.dailyGrid, color: provider.brandColor)
                Text("By hour · last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                hourGrid(activity.hourRows, color: provider.brandColor)
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

    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func dailyGrid(_ weeks: [[HeatmapCell?]], color: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Text(dayNames[i])
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .frame(height: 9)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<weeks.count, id: \.self) { w in
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { d in
                            if let cell = weeks[w][d] {
                                cellView(cell, color: color)
                            } else {
                                Color.clear.frame(width: 9, height: 9)
                            }
                        }
                    }
                }
            }
        }
    }

    private func hourGrid(_ rows: [HeatmapHourRow], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: 2) {
                    Text(row.dayLabel)
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { h in
                        cellView(row.cells[h], color: color)
                    }
                }
            }
            HStack(spacing: 2) {
                Color.clear.frame(width: 20, height: 1)
                Text("0")
                Spacer()
                Text("6")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("23")
            }
            .font(.system(size: 7))
            .foregroundStyle(.tertiary)
            .frame(width: 20 + 24 * 11 - 2)
        }
    }

    private func cellView(_ cell: HeatmapCell, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(cell.level == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(color.opacity(opacity(cell.level))))
            .frame(width: 9, height: 9)
            .help(cell.label)
    }

    private func opacity(_ level: Int) -> Double {
        [0, 0.3, 0.55, 0.78, 1.0][min(max(level, 0), 4)]
    }
}
