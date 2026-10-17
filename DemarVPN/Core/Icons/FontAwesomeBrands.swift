import CoreText
import SwiftUI

/// Font Awesome 6 Brands — parity with Flutter `font_awesome_flutter` (incl. Bluesky).
enum FontAwesomeBrands {
    static let fontName = "FontAwesome6Brands-Regular"

    /// Order matches Android `SettingsLinksStrip`.
    static let links: [(glyph: String, url: URL)] = [
        ("\u{e61b}", URL(string: "https://x.com/DemarLtd")!),
        ("\u{e671}", URL(string: "https://bsky.app/profile/demarltd.bsky.social/")!),
        ("\u{e618}", URL(string: "https://www.threads.com/@demarltd")!),
        ("\u{f2c6}", URL(string: "https://t.me/demarproxy")!),
    ]

    static func register() {
        guard let url = Bundle.main.url(forResource: "fa-brands-400", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

struct BrandIconView: View {
    var glyph: String
    var size: CGFloat = 26

    var body: some View {
        Text(glyph)
            .font(.custom(FontAwesomeBrands.fontName, size: size))
            .frame(width: size, height: size)
            .foregroundStyle(Color.demarPrimary)
    }
}
