import SwiftUI

/// ☰ karşılığı görünüm seçici: canlı panel, offline özet, ısı haritası
enum PanelMode: String, CaseIterable, Identifiable {
    case live = "Live"
    case history = "Summary"
    case heatmap = "Heatmap"

    var id: String { rawValue }
}

/// Tek panel: üstteki şeritten sağlayıcı seçilir, altında seçilenin detayı
struct MenuContentView: View {
    let state: AppState
    @State private var showSettings = false
    @State private var mode: PanelMode = .live

    /// Seçili sağlayıcı ayarlardan kapatıldıysa ilk açık olana düşer
    private var provider: Provider {
        state.availableProviders.contains(state.selectedProvider)
            ? state.selectedProvider
            : state.availableProviders[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !showSettings {
                ProviderSwitcherView(state: state, selected: Bindable(state).selectedProvider)
                Divider()
            }

            header

            if showSettings {
                SettingsView(settings: state.settings, auth: state.auth)
            } else if !state.settings.isEnabled(provider) {
                Text("\(provider.displayName) is disabled — enable it in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("View", selection: $mode) {
                    ForEach(PanelMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch mode {
                case .live: mainContent
                case .history: HistoryView(state: state, provider: provider)
                case .heatmap: HeatmapView(state: state, provider: provider)
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            if !state.availableProviders.contains(state.selectedProvider) {
                state.selectedProvider = state.availableProviders[0]
            }
        }
    }

    private var header: some View {
        HStack {
            Circle().fill(provider.brandColor).frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.headline)
            Spacer()
            if let last = state.lastRefresh {
                Text(last, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await state.refreshAll() }
            } label: {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(state.isRefreshing)
            .help("Refresh now")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ProviderSectionView(
            snapshot: state.snapshot(for: provider),
            contexts: state.contexts(for: provider),
            sessionParts: state.sessionParts(for: provider)
        )

        Divider()

        if provider == .claude {
            VStack(alignment: .leading, spacing: 2) {
                CostChartView(title: "Estimated cost (14 days)", stats: state.claudeDaily, showCost: true)
                HStack {
                    Text(String(format: "Today: $%.2f", state.claudeCostToday))
                    Spacer()
                    Text(String(format: "This month: $%.2f", state.claudeCostThisMonth))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                CostChartView(title: "Token usage (14 days)", stats: state.codexDaily, showCost: false)
                Text("Today: \(formatTokenCount(state.codexTokensToday)) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            } label: {
                Image(systemName: showSettings ? "chevron.left" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(showSettings ? "Back" : "Settings")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct ProviderSectionView: View {
    let snapshot: ProviderSnapshot
    var contexts: [ContextSnapshot] = []
    var sessionParts: TokenParts?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = snapshot.planName {
                Text(plan)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            switch snapshot.status {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ok:
                ForEach(snapshot.windows) { window in
                    // Bileşim yalnızca oturum penceresine uygulanır; haftalık
                    // pencerelerin bileşimi 5 saatlik taramadan türetilemez
                    UsageMeterView(
                        window: window,
                        parts: window.label.hasPrefix("Session") ? sessionParts : nil
                    )
                }
            case .authProblem(let message):
                statusRow(icon: "key.slash", tint: .orange, message: message)
            case .error(let message):
                statusRow(icon: "exclamationmark.triangle", tint: .red, message: message)
            }

            ForEach(contexts) { context in
                ContextBarView(context: context)
            }
        }
    }

    private func statusRow(icon: String, tint: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
