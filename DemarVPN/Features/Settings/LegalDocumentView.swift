import MarkdownUI
import SwiftUI

struct LegalDocumentView: View {
    let document: LegalDocument

    @State private var markdown: String?

    var body: some View {
        Group {
            if let markdown {
                ScrollView {
                    Markdown(markdown)
                        .markdownTheme(.demar)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .demarDetailNavigationTitle(document.title)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .demarDetailNavigationTitle(document.title)
            }
        }
        .background(Color.demarSurface)
        .task {
            markdown = try? await document.fetchMarkdown()
        }
    }
}

private extension Theme {
    static let demar = Theme()
        .text {
            ForegroundColor(.demarOnSurface)
            FontSize(15)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(.demarOnSurface)
            BackgroundColor(.demarSurfaceContainerHighest)
        }
        .link {
            ForegroundColor(.demarPrimary)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 16, bottom: 10)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.6))
                    ForegroundColor(.demarOnSurface)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.3))
                    ForegroundColor(.demarOnSurface)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 12)
        }
        .codeBlock { configuration in
            configuration.label
                .padding(12)
                .background(Color.demarSurfaceContainerHighest)
                .markdownMargin(top: 0, bottom: 12)
        }
        .table { configuration in
            configuration.label
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.demarSurface, Color.demarSurfaceContainerHighest)
                )
                .markdownMargin(top: 0, bottom: 12)
        }
}
