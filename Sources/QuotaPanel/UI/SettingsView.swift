import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var settings: Settings
    @Bindable var auth: AuthManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    @ViewBuilder
    private func accountRow(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(provider.brandColor).frame(width: 6, height: 6)
                Text(provider.displayName)
                    .font(.callout)
                Spacer()
                if auth.hasStoredLogin(provider) {
                    Text("Signed in ✓")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Sign out") {
                        Task { await auth.logout(provider) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else if provider == .claude {
                    if auth.claudeSession == nil {
                        Button("Sign in") { auth.beginClaudeLogin() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                } else if auth.codexWaiting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sign in") {
                        Task { await auth.beginCodexLogin() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if provider == .claude, auth.claudeSession != nil {
                Text("Approve in the browser, then paste the code it shows:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("code#state", text: $auth.claudeCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    if auth.busy == .claude {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Verify") {
                            Task { await auth.completeClaudeLogin() }
                        }
                        .font(.caption)
                        .disabled(auth.claudeCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { auth.cancelClaudeLogin() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            if provider == .codex, auth.codexWaiting {
                Text("Complete the sign-in in your browser — waiting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = auth.errorMessage[provider] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Safe binding to an array element from ForEach: writes to a stale index
    /// right after a row is deleted are silently ignored
    private func thresholdBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                settings.alertThresholds.indices.contains(index) ? settings.alertThresholds[index] : 0
            },
            set: { value in
                guard settings.alertThresholds.indices.contains(index) else { return }
                settings.alertThresholds[index] = value
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Claude Code", isOn: $settings.claudeEnabled)
                Toggle("Codex", isOn: $settings.codexEnabled)
                Toggle("Show percent in menu bar", isOn: $settings.showPercentInMenuBar)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Stepper(value: $settings.refreshSeconds, in: 30...1800, step: 30) {
                    Text("Refresh interval: \(settings.refreshLabel)")
                }
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Alert thresholds (% used)")
                    .font(.callout.weight(.semibold))
                if settings.alertThresholds.isEmpty {
                    Text("No thresholds — notifications are off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.alertThresholds.indices, id: \.self) { index in
                    HStack {
                        Stepper(value: thresholdBinding(index), in: 5...99, step: 5) {
                            Text("Threshold: \(Int(settings.alertThresholds[index]))%")
                        }
                        Button {
                            settings.removeAlertThreshold(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this threshold")
                    }
                }
                Button {
                    settings.addAlertThreshold()
                } label: {
                    Label("Add threshold", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(settings.alertThresholds.count >= Settings.maxAlertThresholds)
                .help("Up to \(Settings.maxAlertThresholds) thresholds")
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts")
                    .font(.callout.weight(.semibold))
                accountRow(.claude)
                accountRow(.codex)
                Text("Sign-ins are stored only on this Mac (~/.quotapanel, readable only by you). CLI credentials are never modified; when there is no QuotaPanel sign-in, CLI credentials are used instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            if Notifier.isSupported {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("Launch at login and notifications only work from the .app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
