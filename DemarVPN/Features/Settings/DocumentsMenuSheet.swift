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
        #if os(macOS)
        .padding(.top, 16)
        #endif
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color.demarSurface)
        #if os(iOS)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        #endif
    }
}

extension View {
    /// iOS: system sheet. macOS: overlay — tap outside dismisses (system sheet is modal).
    func documentsMenu(
        isPresented: Binding<Bool>,
        onSelect: @escaping (LegalDocument) -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            DocumentsMenuSheet { doc in
                onSelect(doc)
                isPresented.wrappedValue = false
            }
        }
        #else
        modifier(DocumentsMenuMacOverlay(isPresented: isPresented, onSelect: onSelect, onDismiss: onDismiss))
        #endif
    }
}

#if os(macOS)
private struct DocumentsMenuMacOverlay: ViewModifier {
    @Binding var isPresented: Bool
    let onSelect: (LegalDocument) -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }

                    DocumentsMenuSheet { doc in
                        onSelect(doc)
                        isPresented = false
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                    .padding(16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
        .onChange(of: isPresented) { _, shown in
            guard !shown else { return }
            onDismiss()
        }
    }
}
#endif
