import SwiftUI

struct ServiceMenuView: View {
    @Bindable var appState: AppState
    var snackBar: SnackBarController

    @State private var deviceRows: [(String, String)]?
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var idfaBusy = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(
                    title: "О приложении",
                    leading: { icon("info.circle") }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        DemarKvRow(key: "Имя", value: "Demar VPN")
                        DemarKvRow(key: "Пакет", value: Bundle.main.bundleIdentifier ?? "—")
                        DemarKvRow(key: "Версия", value: appState.appVersionLabel)
                        DemarKvRow(key: "Платформа", value: AppPlatform.label)
                        DemarKvRow(
                            key: "Xray",
                            value: appState.xrayVersionToken.isEmpty ? "…" : appState.xrayVersionToken
                        )
                    }
                }

                SectionCard(
                    title: "Device",
                    leading: { icon("folder") }
                ) {
                    if let deviceRows {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(deviceRows.enumerated()), id: \.offset) { _, row in
                                DemarKvRow(key: row.0, value: row.1, keyWidth: 108)
                            }
                            #if os(iOS)
                            if IDFATracking.showPermissionButton {
                                IDFAPermissionButton(busy: idfaBusy) {
                                    Task { await requestIDFA() }
                                }
                                .padding(.top, 8)
                            }
                            #endif
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                SectionCard(
                    title: "Snack bar",
                    leading: { icon("bell.badge") }
                ) {
                    FlowChipRow(snackBar: snackBar)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.demarSurface)
        .navigationTitle("Служебное меню")
        .demarInlineNavigationTitle()
        .task { await reloadDevice() }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reloadDevice() } }
        }
        #endif
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(Color.demarPrimary)
    }

    private func reloadDevice() async {
        deviceRows = await DeviceIdentity.load()
    }

    #if os(iOS)
    private func requestIDFA() async {
        idfaBusy = true
        defer { idfaBusy = false }
        let ok = await IDFATracking.requestPermission()
        await reloadDevice()
        if ok { snackBar.showSuccess("IDFA разрешён") }
    }
    #endif
}

#if os(iOS)
private struct IDFAPermissionButton: View {
    var busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.demarPrimary)
                } else {
                    Text("Включить IDFA")
                        .font(.demarLabelLarge)
                        .fontWeight(.semibold)
                }
            }
            .foregroundStyle(Color.demarPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.demarPrimary.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.demarPrimary.opacity(0.28), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
#endif

private struct FlowChipRow: View {
    var snackBar: SnackBarController

    var body: some View {
        HStack(spacing: 8) {
            chip("Info", kind: .info)
            chip("OK", kind: .success)
            chip("Err", kind: .error)
            chip("Warn", kind: .warning)
        }
    }

    private func chip(_ label: String, kind: DemarSnackKind) -> some View {
        Button(label) { snackBar.show("Демо: \(label)", kind: kind) }
            .font(.demarLabelLarge)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.demarPrimary.opacity(0.10))
            )
            .foregroundStyle(Color.demarPrimary)
    }
}
