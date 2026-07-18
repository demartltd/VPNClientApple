import SwiftUI

struct DocumentsMenuSheet: View {
    let onSelect: (LegalDocument) -> Void

    var body: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            Capsule()
                .fill(Color.demarOnSurface.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 20)
                .padding(.bottom, 8)
            #endif

            ForEach(LegalDocument.allCases) { doc in
                SettingsActionButton(
                    systemImage: doc.systemImage,
                    title: doc.title,
                    subtitle: doc.subtitle,
                    action: { onSelect(doc) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.demarSurface)
        #if os(iOS)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        #endif
    }
}
