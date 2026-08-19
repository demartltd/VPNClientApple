import SwiftUI

enum CustomEgressProbesWindow {
    static let id = "custom-egress-probes"
    #if os(macOS)
    static let width: CGFloat = 420
    static let height: CGFloat = 480
    #endif
}

private enum CustomEgressProbesFieldStyle {
    static let horizontalPadding: CGFloat = 16
    static let fieldInset: CGFloat = 12
    static let controlHeight: CGFloat = 40

    static var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.demarSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
            )
    }
}

enum CustomEgressProbeStore {
    private static let key = "demar.customEgressProbeHosts"

    static var hosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @discardableResult
    static func addLines(_ raw: String) -> Int {
        var list = hosts
        var added = 0
        for line in raw.components(separatedBy: .newlines) {
            guard let host = PublicEgressDiagnostics.normalizeProbeHost(line) else { continue }
            guard !list.contains(host) else { continue }
            list.append(host)
            added += 1
        }
        if added > 0 { hosts = list }
        return added
    }

    @discardableResult
    static func update(_ old: String, raw: String) -> String? {
        guard let host = PublicEgressDiagnostics.normalizeProbeHost(raw),
              let i = hosts.firstIndex(of: old)
        else { return nil }
        var list = hosts
        if list.contains(host), host != old { return nil }
        list[i] = host
        hosts = list
        return host
    }

    static func remove(_ hostsToRemove: some Sequence<String>) {
        let drop = Set(hostsToRemove)
        hosts = hosts.filter { !drop.contains($0) }
    }
}

extension View {
    #if os(macOS)
    func customEgressProbesMacWindowFrame() -> some View {
        frame(width: CustomEgressProbesWindow.width, height: CustomEgressProbesWindow.height)
            .fixedSize()
            .modifier(CustomEgressProbesMacResizeLock())
    }
    #endif

    func demarConfirmAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        confirm: String = String(localized: "Yes"),
        cancel: String = String(localized: "No"),
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(confirm, role: .destructive, action: onConfirm)
            Button(cancel, role: .cancel) {}
        }
    }

    func renameAlert(host: Binding<String?>, draft: Binding<String>, onSave: @escaping () -> Void) -> some View {
        alert(
            String(localized: "Rename"),
            isPresented: Binding(
                get: { host.wrappedValue != nil },
                set: {
                    guard !$0 else { return }
                    host.wrappedValue = nil
                    draft.wrappedValue = ""
                }
            )
        ) {
            TextField("", text: draft)
            Button(String(localized: "Done")) {
                guard PublicEgressDiagnostics.normalizeProbeHost(draft.wrappedValue) != nil else { return }
                onSave()
                host.wrappedValue = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                host.wrappedValue = nil
                draft.wrappedValue = ""
            }
        }
    }
}

struct CustomEgressProbesPanel: View {
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    #if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    @State private var draft = ""
    @State private var hosts = CustomEgressProbeStore.hosts
    @State private var picked = Set<String>()
    @State private var confirmDelete = false
    @State private var renameHost: String?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        String(localized: "List is empty"),
                        systemImage: "list.bullet.rectangle",
                        description: Text("Host or IP")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(hosts, id: \.self) { hostChip($0) }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.demarSurface)
            .demarDetailNavigationTitle(String(localized: "Custom checks"))

            HStack(spacing: 8) {
                TextField(String(localized: "Host or IP"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.demarBodyMedium)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    .submitLabel(.done)
                    .padding(.horizontal, CustomEgressProbesFieldStyle.fieldInset)
                    .frame(height: CustomEgressProbesFieldStyle.controlHeight)
                    .background(CustomEgressProbesFieldStyle.background)
                    .onSubmit(commitDraft)
                    .onChange(of: draft) { _, value in
                        if value.contains(where: \.isNewline) { commitDraft() }
                    }
                deleteButton
            }
            .padding(16)
            .background(Color.demarSurface)
        }
        .background(Color.demarSurface.ignoresSafeArea())
        #if os(macOS)
        .navigationTitle(String(localized: "Custom checks"))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        #endif
        .onAppear(perform: resetTransientState)
        .onDisappear(perform: resetTransientState)
        .renameAlert(host: $renameHost, draft: $renameDraft) {
            guard let old = renameHost else { return }
            _ = CustomEgressProbeStore.update(old, raw: renameDraft)
            reload()
        }
        .demarConfirmAlert(String(localized: "Delete selected (\(picked.count))?"), isPresented: $confirmDelete) {
            CustomEgressProbeStore.remove(picked)
            picked = []
            reload()
        }
    }

    private func hostChip(_ host: String) -> some View {
        let selected = picked.contains(host)
        return Text(host)
            .font(.demarBodySmall)
            .foregroundStyle(Color.demarOnSurface)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chipBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                if selected { picked.remove(host) } else { picked.insert(host) }
            }
            .contextMenu {
                Button {
                    renameHost = host
                    renameDraft = host
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
            }
    }

    private func chipBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.demarPrimary.opacity(0.12) : Color.demarSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Color.demarPrimary.opacity(0.55) : Color.demarOutline.opacity(0.20),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
    }

    private var deleteButton: some View {
        let enabled = !picked.isEmpty
        return Button { confirmDelete = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Color.red : Color.demarOutline.opacity(0.45))
                .frame(
                    width: CustomEgressProbesFieldStyle.controlHeight,
                    height: CustomEgressProbesFieldStyle.controlHeight
                )
                .background(CustomEgressProbesFieldStyle.background)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(String(localized: "Delete selected"))
    }

    private func reload() { hosts = CustomEgressProbeStore.hosts }

    private func resetTransientState() {
        picked = []
        confirmDelete = false
        renameHost = nil
        renameDraft = ""
    }

    #if os(macOS)
    private func handleEscape() {
        if renameHost != nil {
            renameHost = nil
            renameDraft = ""
            return
        }
        if confirmDelete {
            confirmDelete = false
            return
        }
        dismissWindow(id: CustomEgressProbesWindow.id)
    }
    #endif

    private func commitDraft() {
        guard CustomEgressProbeStore.addLines(draft) > 0 else { return }
        draft = ""
        reload()
    }
}

#if os(macOS)
private struct CustomEgressProbesMacResizeLock: ViewModifier {
    func body(content: Content) -> some View {
        content.windowResizeBehavior(.disabled)
    }
}
#endif
