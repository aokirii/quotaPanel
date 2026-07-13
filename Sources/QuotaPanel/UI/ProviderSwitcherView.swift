import SwiftUI

/// Provider strip at the top of the panel: icon + name + a mini bar that
/// fills to the 5-hour session window. Scrolls horizontally as providers grow.
struct ProviderSwitcherView: View {
    let state: AppState
    @Binding var selected: Provider

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.availableProviders) { provider in
                    ProviderChip(
                        provider: provider,
                        snapshot: state.snapshot(for: provider),
                        isSelected: provider == selected
                    )
                    .onTapGesture { selected = provider }
                }
            }
        }
    }
}

struct ProviderChip: View {
    let provider: Provider
    let snapshot: ProviderSnapshot
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ProviderIconView(provider: provider, size: 22, tint: provider.brandColor)
            Text(provider.displayName)
                .font(.caption2)
                .lineLimit(1)
            sessionBar
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(barHelp)
    }

    /// Bar filled to the 5-hour session window: 0% → empty, 15% → 15% filled
    private var sessionBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            if let percent = sessionPercent, percent > 0 {
                Capsule()
                    .fill(provider.brandColor)
                    .frame(width: max(2, 44 * min(percent, 100) / 100))
            }
        }
        .frame(width: 44, height: 3)
    }

    private var sessionPercent: Double? {
        guard case .ok = snapshot.status else { return nil }
        return snapshot.menuBarWindow?.clampedPercent
    }

    private var barHelp: String {
        guard let percent = sessionPercent else { return provider.displayName }
        return "\(provider.displayName) — session window \(formatPercent(percent))%"
    }
}
