import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var settings: Settings
    @Bindable var auth: AuthManager
    let notifier: Notifier
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

    private let providerColumns = [
        GridItem(.flexible(), spacing: 8, alignment: .leading),
        GridItem(.flexible(), spacing: 8, alignment: .leading),
    ]

    private func providerBinding(_ provider: Provider) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(provider) },
            set: { settings.setEnabled(provider, $0) }
        )
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

    /// Live notification-permission status plus a test button. Makes a silent
    /// macOS denial visible — otherwise thresholds appear "not to work" when
    /// really the OS is blocking delivery.
    @ViewBuilder
    private var notificationStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(notificationStatusColor).frame(width: 6, height: 6)
                Text(notificationStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if notifier.permission.isDelivering {
                    Button("Test") { notifier.sendTest() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if notifier.permission == .notDetermined {
                    Button("Enable") { notifier.requestAuthorization() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if notifier.permission == .denied {
                    Button("Open Settings") { notifier.openSystemSettings() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if notifier.permission == .denied {
                Text("macOS is blocking notifications for this app. Enable them in System Settings → Notifications → QuotaPanel. A signed release grants them normally.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationStatusText: String {
        switch notifier.permission {
        case .unknown: "Notifications: checking…"
        case .unsupported: "Notifications need the .app bundle"
        case .notDetermined: "Notifications: permission not granted yet"
        case .denied: "Notifications: blocked by macOS"
        case .authorized: "Notifications: on"
        case .provisional: "Notifications: quiet delivery"
        }
    }

    private var notificationStatusColor: Color {
        switch notifier.permission {
        case .authorized, .provisional: .green
        case .denied: .red
        case .notDetermined, .unsupported: .orange
        case .unknown: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                // Two columns keep the 20+ providers from making the panel
                // impossibly tall.
                LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 6) {
                    ForEach(Provider.allCases) { provider in
                        Toggle(provider.displayName, isOn: providerBinding(provider))
                            .lineLimit(1)
                    }
                }
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

                notificationStatus
                    .padding(.top, 2)
            }
            .font(.callout)
            .task { await notifier.refreshStatus() }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts")
                    .font(.callout.weight(.semibold))
                ForEach(Provider.allCases.filter(\.supportsInAppSignIn)) { provider in
                    accountRow(provider)
                }
                Text("Sign-ins are stored only on this Mac (~/.quotapanel, readable only by you). CLI credentials are never modified; when there is no QuotaPanel sign-in, CLI credentials are used instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                let cliProviders = Provider.allCases.filter { !$0.supportsInAppSignIn }
                if !cliProviders.isEmpty {
                    Divider()
                    Text("Detected from CLI/editor credentials")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(cliProviders) { provider in
                        HStack {
                            Circle().fill(provider.brandColor).frame(width: 6, height: 6)
                            Text(provider.displayName)
                                .font(.callout)
                            Spacer()
                            if provider.hasLocalCredentials {
                                Text("Detected ✓")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Not found")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
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
