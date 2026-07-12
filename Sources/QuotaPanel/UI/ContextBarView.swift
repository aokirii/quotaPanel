import SwiftUI

/// Tek açık oturumun bağlam penceresi kartı: etiket + yüzde, segmentli çubuk,
/// token sayısı ve model
struct ContextBarView: View {
    let context: ContextSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(context.project.isEmpty ? "CONTEXT" : "CONTEXT · \(context.project)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(formatPercent(context.percent))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            PartsCaptionView(parts: context.parts, percent: context.percent)
            SegmentedBarView(percent: context.percent, parts: context.parts)
            HStack {
                Text("\(formatTokenCount(context.used)) / \(formatTokenCount(context.limit)) tokens")
                Spacer()
                if !context.model.isEmpty {
                    Text(context.model).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var color: Color {
        switch context.percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }
}
