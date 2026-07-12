import SwiftUI

/// The provider's brand icon. SVGs ship in the bundle from `Resources/`
/// (from CodexBar, MIT licensed) and render in template mode to match the
/// menu bar's light/dark appearance. Falls back to a lettered circle when
/// the resource is missing (e.g. bare binary).
struct ProviderIconView: View {
    let provider: Provider
    var size: CGFloat = 18
    /// nil → system foreground color (for the menu bar); a value → tinted with it
    var tint: Color?

    var body: some View {
        // MenuBarExtra labels don't honor SwiftUI frame downscaling, so the
        // NSImage is scaled to the target size at load time
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
            // Redraws the vector at the target size; stays crisp on retina since
            // scaling happens at draw time
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
