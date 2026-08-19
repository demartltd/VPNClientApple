import SwiftUI

struct DocumentsMenuSheet: View {
    let onSelect: (LegalDocument) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(LegalDocument.allCases) { doc in
                SettingsActionButton(
                    systemImage: doc.systemImage,
                    title: doc.title,
                    subtitle: doc.subtitle,
                    action: { onSelect(doc) }
                )
            }
        }
        .demarSheetChrome(horizontalPadding: 16, bottomPadding: 8)
    }
}

extension View {
    func documentsMenu(
        isPresented: Binding<Bool>,
        onSelect: @escaping (LegalDocument) -> Void
    ) -> some View {
        demarBottomSheet(isPresented: isPresented) {
            DocumentsMenuSheet { doc in
                isPresented.wrappedValue = false
                onSelect(doc)
            }
        }
    }
}
