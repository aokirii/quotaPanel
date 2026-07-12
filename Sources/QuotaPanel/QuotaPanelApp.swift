import SwiftUI

@main
struct QuotaPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        // Single menu bar item; providers are switched via the strip inside the panel
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            // The label is always visible in the menu bar, making this the one
            // reliable lifecycle point to start polling
            CombinedMenuBarLabel(state: state)
                .onAppear { state.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon when running outside a bundle (via swift run)
        NSApp.setActivationPolicy(.accessory)
    }
}
