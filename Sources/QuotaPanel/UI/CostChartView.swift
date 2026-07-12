import SwiftUI
import Charts

/// Son 14 günün bar grafiği: Claude için USD, Codex için token
struct CostChartView: View {
    let title: String
    let stats: [DailyStat]
    /// true → costUSD çizilir; false → tokens çizilir
    let showCost: Bool

    private var recent: [DailyStat] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: Date()))!
        return stats.filter { $0.day >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if recent.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                Chart(recent) { stat in
                    BarMark(
                        x: .value("Day", stat.day, unit: .day),
                        y: .value(showCost ? "USD" : "Token", showCost ? stat.costUSD : Double(stat.tokens))
                    )
                    .foregroundStyle(.tint)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                            .font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(showCost ? String(format: "$%.0f", v) : compactTokens(Int(v)))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 72)
            }
        }
    }

    private func compactTokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}
