import SwiftUI

/// Label of the single menu bar item: the brand icon (+ percent + mini bar)
/// of the provider currently open in the panel. Follows strip selection.
struct CombinedMenuBarLabel: View {
    let state: AppState

    var body: some View {
        let provider = state.availableProviders.contains(state.selectedProvider)
            ? state.selectedProvider
            : state.availableProviders[0]
        ProviderMenuBarLabel(state: state, provider: provider)
    }
}

/// One provider's menu bar unit: brand icon, optional percent, and a mini
/// usage bar of the 5-hour session window (or the fullest window as a fallback)
struct ProviderMenuBarLabel: View {
    let state: AppState
    let provider: Provider

    var body: some View {
        let snapshot = state.snapshot(for: provider)
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                ProviderIconView(provider: provider, size: 13, tint: nil)
                if state.settings.showPercentInMenuBar {
                    Text(statusText(snapshot))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
            usageBar(snapshot)
        }
    }

    private func statusText(_ snapshot: ProviderSnapshot) -> String {
        switch snapshot.status {
        case .ok:
            guard let window = snapshot.menuBarWindow else { return "–" }
            return "\(formatPercent(window.clampedPercent))%"
        case .loading: return "…"
        case .authProblem, .error: return "!"
        }
    }

    @ViewBuilder
    private func usageBar(_ snapshot: ProviderSnapshot) -> some View {
        let percent: Double? = {
            guard case .ok = snapshot.status else { return nil }
            return snapshot.menuBarWindow?.clampedPercent
        }()
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            if let percent {
                Capsule()
                    .fill(barColor(percent))
                    .frame(width: max(2, 22 * percent / 100))
            }
        }
        .frame(width: 22, height: 3)
    }

    private func barColor(_ percent: Double) -> Color {
        switch percent {
        case ..<50: .green
        case ..<80: .yellow
        case ..<95: .orange
        default: .red
        }
    }
}
