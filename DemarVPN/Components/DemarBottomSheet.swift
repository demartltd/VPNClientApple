import SwiftUI

extension View {
    /// iOS: system sheet. macOS: bottom overlay (tap outside / Esc dismisses).
    func demarBottomSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented, onDismiss: { onDismiss?() }, content: content)
        #else
        modifier(DemarBottomSheetMacOverlay(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
        #endif
    }

    /// Sheet chrome: handle + surface. Height fits content (no empty bottom gap).
    func demarSheetChrome(
        horizontalPadding: CGFloat = 24,
        bottomPadding: CGFloat = 8,
        showsHandle: Bool = true,
        systemDragIndicator: Bool = false
    ) -> some View {
        modifier(
            DemarSheetChromeModifier(
                horizontalPadding: horizontalPadding,
                bottomPadding: bottomPadding,
                showsHandle: showsHandle,
                systemDragIndicator: systemDragIndicator
            )
        )
    }

    /// Presentation-only (for NavigationStack sheets without chrome padding).
    func demarSheetPresentation(
        _ detents: Set<PresentationDetent>,
        systemDragIndicator: Bool = false
    ) -> some View {
        #if os(iOS)
        presentationDetents(detents)
            .presentationDragIndicator(systemDragIndicator ? .visible : .hidden)
            .presentationBackground(Color.demarSurface)
        #else
        self
        #endif
    }
}

private struct DemarSheetChromeModifier: ViewModifier {
    var horizontalPadding: CGFloat
    var bottomPadding: CGFloat
    var showsHandle: Bool
    var systemDragIndicator: Bool
    #if os(iOS)
    @State private var height: CGFloat = 160
    #endif

    func body(content: Content) -> some View {
        let chrome = VStack(spacing: 0) {
            #if os(iOS)
            if showsHandle {
                Capsule()
                    .fill(Color.demarOnSurfaceVariant.opacity(0.4))
                    .frame(width: 32, height: 4)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
            #endif
            content
        }
        .padding(.horizontal, horizontalPadding)
        #if os(macOS)
        .padding(.vertical, 16)
        #else
        .padding(.bottom, bottomPadding)
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.demarSurface)

        #if os(iOS)
        chrome
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, h in
                guard h > 1, abs(h - height) > 0.5 else { return }
                height = h
            }
            .demarSheetPresentation([.height(height)], systemDragIndicator: systemDragIndicator)
        #else
        chrome
        #endif
    }
}

#if os(macOS)
private struct DemarBottomSheetMacOverlay<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheet: () -> Sheet
    @FocusState private var overlayFocused: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }
                    sheet()
                        .fixedSize(horizontal: false, vertical: true)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                        .padding(16)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($overlayFocused)
                .onKeyPress(.escape) {
                    isPresented = false
                    return .handled
                }
                .onExitCommand { isPresented = false }
                .onAppear { overlayFocused = true }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
        .onChange(of: isPresented) { _, shown in
            if shown {
                overlayFocused = true
            } else {
                onDismiss?()
            }
        }
    }
}
#endif
