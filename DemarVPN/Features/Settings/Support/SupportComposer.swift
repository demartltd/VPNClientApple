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
                        // Keep focus while sending — disabling the field dismisses the keyboard.
                        .disabled(!enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .supportFloatChrome(
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                    interactive: false
                )

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

