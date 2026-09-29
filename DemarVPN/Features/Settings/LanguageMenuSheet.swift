import SwiftUI

#if os(macOS)
struct LanguageMenuSheet: View {
    let currentCode: String
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(AppLanguage.supported, id: \.self) { code in
                Button {
                    onSelect(code)
                } label: {
                    Text(AppLanguage.flag(for: code))
                        .font(.system(size: 34))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(code == currentCode ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    code == currentCode ? Color.accentColor : Color.clear,
                                    lineWidth: 2
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(AppLanguage.displayName(for: code))
                .accessibilityLabel(AppLanguage.displayName(for: code))
            }
        }
        .demarSheetChrome(horizontalPadding: 16, bottomPadding: 8)
    }
}

extension View {
    func languageMenu(
        isPresented: Binding<Bool>,
        currentCode: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        demarBottomSheet(isPresented: isPresented) {
            LanguageMenuSheet(currentCode: currentCode, onSelect: onSelect)
        }
    }
}
#endif
