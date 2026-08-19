import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SupportComposerBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var focusID: Int
    let editTarget: SupportMessage?
    let sending: Bool
    let attaching: Bool
    let pendingNames: [String]
    let enabled: Bool
    let statusHint: String?
    var onCancelEdit: () -> Void
    var onRemovePending: (Int) -> Void
    var onAttach: () -> Void
    var onSend: () -> Void
    #if os(macOS)
    @State private var macEditorHeight: CGFloat = 32
    private let macEditorMaxHeight: CGFloat = 110
    #endif

    private var interactive: Bool { enabled && !sending }
    private var canSend: Bool {
        if !enabled || sending { return false }
        if editTarget != nil { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingNames.isEmpty
    }

    private var placeholder: String {
        statusHint ?? String(localized: "Message")
    }

    var body: some View {
        VStack(spacing: 8) {
            if editTarget != nil && enabled {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.demarPrimary)
                        .frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Editing")
                            .font(.demarBodySmall.weight(.semibold))
                            .foregroundStyle(Color.demarPrimary)
                        Text(editTarget?.text ?? "")
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: onCancelEdit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .supportFloatChrome(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
                .padding(.horizontal, 12)
            }

            if !pendingNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingNames.enumerated()), id: \.offset) { i, name in
                            HStack(spacing: 4) {
                                Text(name).lineLimit(1)
                                Button {
                                    onRemovePending(i)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .disabled(!interactive || editTarget != nil)
                            }
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurface)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .supportFloatChrome(in: Capsule(), interactive: false)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                composerCircleButton(
                    systemImage: "paperclip",
                    disabled: !interactive || editTarget != nil,
                    busy: attaching,
                    action: onAttach
                )

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.demarBodyMedium)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    #if os(macOS)
                    MacSupportComposerTextView(
                        text: $text,
                        isEnabled: enabled,
                        isFocused: focused,
                        height: $macEditorHeight,
                        maxHeight: macEditorMaxHeight,
                        onSend: {
                            guard canSend else { return }
                            onSend()
                        }
                    )
                    .frame(height: max(32, macEditorHeight))
                        .disabled(!enabled)
                    #else
                    TextField("", text: $text, axis: .vertical)
                        .font(.demarBodyMedium)
                        .foregroundStyle(enabled ? Color.demarOnSurface : Color.demarOnSurfaceVariant)
                        .tint(.white)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .focused(focused)
                        .id(focusID)
                        #if os(macOS)
                        // macOS chat UX: Enter sends, Shift+Enter inserts a new line.
                        .onKeyPress(keys: [.return]) { keyPress in
                            if keyPress.modifiers.contains(.shift) { return .ignored }
                            guard canSend else { return .handled }
                            onSend()
                            return .handled
                        }
                        #endif
                        // Keep focus while sending — disabling the field dismisses the keyboard.
                        .disabled(!enabled)
                    #endif
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .supportFloatChrome(
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                    interactive: false
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                composerCircleButton(
                    systemImage: editTarget == nil ? "paperplane.fill" : "checkmark",
                    disabled: !(canSend || sending),
                    busy: sending,
                    action: { if canSend { onSend() } }
                )
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
    }

    private func composerCircleButton(
        systemImage: String,
        disabled: Bool,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(disabled ? Color.demarOnSurfaceVariant.opacity(0.45) : Color.demarOnSurface)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .supportFloatChrome(in: Circle(), interactive: true)
        .disabled(disabled && !busy)
        .allowsHitTesting(!(disabled && !busy))
    }
}

extension View {
    /// System-matching Liquid Glass (regular, not clear). Fallback: light material.
    /// `interactive` is for buttons only — on a TextField it eats the first tap.
    @ViewBuilder
    func supportFloatChrome<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.background {
                    shape.fill(.clear)
                        .glassEffect(.regular, in: shape)
                        .allowsHitTesting(false)
                }
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.demarOnSurface.opacity(0.14), lineWidth: 0.6))
        }
    }
}

#if os(iOS)
struct SupportDismissKeyboardOnPop: UIViewControllerRepresentable {
    var onBlur: () -> Void

    func makeUIViewController(context: Context) -> Detector {
        Detector(onBlur: onBlur)
    }

    func updateUIViewController(_ vc: Detector, context: Context) {
        vc.onBlur = onBlur
    }

    final class Detector: UIViewController {
        var onBlur: () -> Void
        private weak var observed: UIGestureRecognizer?

        init(onBlur: @escaping () -> Void) {
            self.onBlur = onBlur
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard observed == nil else { return }
            var vc: UIViewController? = self
            while let current = vc {
                if let gesture = current.navigationController?.interactivePopGestureRecognizer {
                    gesture.addTarget(self, action: #selector(handle))
                    observed = gesture
                    break
                }
                vc = current.parent
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            observed?.removeTarget(self, action: #selector(handle))
            observed = nil
            super.viewDidDisappear(animated)
        }

        @objc private func handle(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .began else { return }
            onBlur()
        }
    }
}
#endif

#if os(macOS)
private struct MacSupportComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    var isFocused: FocusState<Bool>.Binding
    @Binding var height: CGFloat
    let maxHeight: CGFloat
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, maxHeight: maxHeight, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = NSColor(Color.demarOnSurface)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 14, height: 9)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.recalculateHeight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onSend = onSend
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.textColor = NSColor(isEnabled ? Color.demarOnSurface : Color.demarOnSurfaceVariant)
        if isFocused.wrappedValue, scroll.window?.firstResponder !== textView {
            scroll.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        let maxHeight: CGFloat
        var onSend: () -> Void
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(text: Binding<String>, height: Binding<CGFloat>, maxHeight: CGFloat, onSend: @escaping () -> Void) {
            _text = text
            _height = height
            self.maxHeight = maxHeight
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                onSend()
                return true
            }
            return false
        }

        func recalculateHeight() {
            guard let textView, let scrollView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
            let padded = used + textView.textContainerInset.height * 2 + 2
            let next = min(max(34, ceil(padded)), maxHeight)
            if abs(height - next) > 0.5 {
                DispatchQueue.main.async { self.height = next }
            }
            scrollView.hasVerticalScroller = padded > maxHeight
        }
    }
}
#endif

