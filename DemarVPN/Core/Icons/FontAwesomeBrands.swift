import CoreText
import SwiftUI

/// Font Awesome 6 Brands — parity with Flutter `font_awesome_flutter` (incl. Bluesky).
enum FontAwesomeBrands {
    static let fontName = "FontAwesome6Brands-Regular"

    /// Order matches Flutter `SettingsLinksStrip`.
    static let links: [(glyph: String, url: URL)] = [
        ("\u{e61b}", URL(string: "https://x.com/demargames")!),
        ("\u{e671}", URL(string: "https://bsky.app/profile/demargames.bsky.social")!),
        ("\u{f16d}", URL(string: "https://www.instagram.com/demargames/")!),
        ("\u{f09a}", URL(string: "https://www.facebook.com/demargames")!),
        ("\u{f1a1}", URL(string: "https://reddit.com/r/demargames")!),
        ("\u{f2c6}", URL(string: "https://t.me/demargames")!),
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
