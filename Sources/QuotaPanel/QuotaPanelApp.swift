import SwiftUI

@main
struct QuotaPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        // Tek menü çubuğu öğesi; panel içindeki şeritten sağlayıcı seçilir
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            // Etiket menü çubuğunda her zaman görünür olduğundan polling'i
            // başlatmak için güvenilir tek yaşam döngüsü noktası burası
            CombinedMenuBarLabel(state: state)
                .onAppear { state.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bundle dışında (swift run ile) çalışırken Dock ikonu çıkmasın
        NSApp.setActivationPolicy(.accessory)
    }
}
