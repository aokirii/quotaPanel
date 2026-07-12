import SwiftUI

/// Panelin üstündeki sağlayıcı şeridi: ikon + ad + altında 5 saatlik oturum
/// penceresi kadar dolan mini bar. Sağlayıcı sayısı arttıkça yana kaydırılır.
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

    /// 5 saatlik oturum penceresi kadar dolan bar: %0 → boş, %15 → %15 dolu
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
        let session = snapshot.windows.first { $0.label.hasPrefix("Session") } ?? snapshot.worstWindow
        return session?.clampedPercent
    }

    private var barHelp: String {
        guard let percent = sessionPercent else { return provider.displayName }
        return "\(provider.displayName) — session window \(formatPercent(percent))%"
    }
}
