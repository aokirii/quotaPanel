import SwiftUI

/// Sağlayıcının marka simgesi. SVG'ler pakete `Resources/` altından girer
/// (CodexBar'dan, MIT lisanslı); şablon (template) modda çizilir ki menü
/// çubuğunun açık/koyu görünümüne uysun. Kaynak bulunamazsa (ör. çıplak
/// binary'de) harfli daireye düşer.
struct ProviderIconView: View {
    let provider: Provider
    var size: CGFloat = 18
    /// nil → sistemin ön plan rengi (menü çubuğu için); değer → o renkle boyanır
    var tint: Color?

    var body: some View {
        // MenuBarExtra etiketi SwiftUI frame küçültmesini uygulamadığından
        // NSImage hedef boyuta yükleme anında ölçeklenir
        if let image = IconCache.image(for: provider, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
        } else {
            ZStack {
                Circle().fill(tint ?? provider.brandColor)
                Text(provider.shortLabel)
                    .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

@MainActor
private enum IconCache {
    private static var cache: [String: NSImage?] = [:]

    static func image(for provider: Provider, size: CGFloat) -> NSImage? {
        let key = "\(provider.rawValue)-\(Int(size))"
        if let cached = cache[key] { return cached }
        let url = Bundle.main.url(forResource: "ProviderIcon-\(provider.rawValue)", withExtension: "svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }.map { base in
            // Vektörü hedef boyutta yeniden çizer; retina'da çizim anında
            // ölçeklendiği için keskin kalır
            let sized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                base.draw(in: rect)
                return true
            }
            sized.isTemplate = true
            return sized
        }
        cache[key] = image
        return image
    }
}
