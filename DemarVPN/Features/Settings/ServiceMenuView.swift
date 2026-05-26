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

                ServiceEgressDiagnosticsCard(appState: appState)

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

/// Длительность одного оборота иконки «Обновить», сек (как `kSettingsServiceMenuTiming` во Flutter).
private let kServiceMenuRefreshSpinDuration: TimeInterval = 2.5

private struct ServiceEgressDiagnosticsCard: View {
    @Bindable var appState: AppState
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var geoBusy = true
    @State private var inFlight = false
    @State private var refreshSpinAngle: Double = 0
    @State private var geo: PublicEgressInfo?
    @State private var probes = PublicEgressDiagnostics.probeHosts.map { _ in
        EgressHostProbe(tcpMs: 0, httpsMs: 0)
    }
    @State private var probesReady = Set<Int>()
    @State private var userHosts = CustomEgressProbeStore.hosts
    @State private var userProbes: [EgressHostProbe] = []
    @State private var userProbesReady = Set<Int>()
    @State private var showCustomList = false
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        SectionCard(
            title: "Интернет",
            leading: { icon("cloud") },
            trailing: { headerActions }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                DemarKvRow(key: "IP", value: ipCell)
                DemarKvRow(key: "Страна", value: countryCell)
                if !userHosts.isEmpty {
                    ForEach(Array(userHosts.enumerated()), id: \.offset) { index, host in
                        DemarKvRow(
                            key: host,
                            value: userProbesReady.contains(index)
                                ? PublicEgressDiagnostics.egressHostProbeLabel(userProbes[index])
                                : "…"
                        )
                    }
                }
                ForEach(Array(PublicEgressDiagnostics.probeHosts.enumerated()), id: \.offset) { index, host in
                    DemarKvRow(
                        key: host,
                        value: probesReady.contains(index)
                            ? PublicEgressDiagnostics.egressHostProbeLabel(probes[index])
                            : "…"
                    )
                }
            }
        }
        .task { await load() }
        .onChange(of: appState.vpnState) { _, _ in Task { await load() } }
        .customEgressProbesSheet(isPresented: $showCustomList)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            syncUserHosts()
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        #endif
    }

    private var headerActions: some View {
        HStack(spacing: 14) {
            Button(action: openCustomList) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Color.demarPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Свои проверки")
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button { Task { await load() } } label: {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(Color.demarPrimary)
                .rotationEffect(.degrees(refreshSpinAngle))
        }
        .buttonStyle(.plain)
        .disabled(inFlight)
        .accessibilityLabel("Обновить")
    }

    private var ipCell: String {
        if geoBusy { return "…" }
        let ip = geo?.ip ?? PublicEgressDiagnostics.fallback.ip
        return PublicEgressDiagnostics.censorPublicIPv4ForDisplay(ip)
    }

    private var countryCell: String {
        if geoBusy { return "…" }
        return geo?.country ?? PublicEgressDiagnostics.fallback.country
    }

    private func openCustomList() {
        #if os(macOS)
        openWindow(id: CustomEgressProbesWindow.id)
        #else
        showCustomList = true
        #endif
    }

    private func syncUserHosts() {
        userHosts = CustomEgressProbeStore.hosts
        userProbes = userHosts.map { _ in EgressHostProbe(tcpMs: 0, httpsMs: 0) }
        userProbesReady = []
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(Color.demarPrimary)
    }

    private func load() async {
        guard !inFlight else { return }
        inFlight = true
        geoBusy = true
        geo = nil
        probesReady = []
        userProbesReady = []
        userHosts = CustomEgressProbeStore.hosts
        userProbes = userHosts.map { _ in EgressHostProbe(tcpMs: 0, httpsMs: 0) }
        probes = PublicEgressDiagnostics.probeHosts.map { _ in EgressHostProbe(tcpMs: 0, httpsMs: 0) }
        async let spin: Void = runRefreshSpin()
        async let geoLoad: Void = fetchGeo()
        async let probesLoad: Void = fetchHostProbes()
        async let userLoad: Void = fetchUserProbes()
        _ = await (spin, geoLoad, probesLoad, userLoad)
        inFlight = false
    }

    private func runRefreshSpin() async {
        let duration = kServiceMenuRefreshSpinDuration
        await MainActor.run {
            refreshSpinAngle = 0
            withAnimation(.linear(duration: duration)) { refreshSpinAngle = 360 }
        }
        try? await Task.sleep(for: .seconds(duration))
    }

    private func fetchGeo() async {
        let result = await PublicEgressDiagnostics.fetchPublicEgressGeo()
        await MainActor.run {
            geo = result
            geoBusy = false
        }
    }

    private func fetchHostProbes() async {
        let hostProbes = await PublicEgressDiagnostics.probeAllHosts { index, probe in
            Task { @MainActor in
                probes[index] = probe
                probesReady.insert(index)
            }
        }
        await MainActor.run {
            probes = hostProbes
        }
    }

    private func fetchUserProbes() async {
        let hosts = await MainActor.run { CustomEgressProbeStore.hosts }
        guard !hosts.isEmpty else { return }
        let results = await PublicEgressDiagnostics.probeHosts(hosts) { index, probe in
            Task { @MainActor in
                userProbes[index] = probe
                userProbesReady.insert(index)
            }
        }
        await MainActor.run { userProbes = results }
    }
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
