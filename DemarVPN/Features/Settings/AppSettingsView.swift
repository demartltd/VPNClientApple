import SwiftUI

struct AppSettingsView: View {
    let isFree: Bool
    var onBuySubscription: (() -> Void)?

    @State private var logExpanded = false
    @State private var language = AppLanguage.shared
    @State private var showTunSettings = false
    #if os(macOS)
    @State private var showLanguagePicker = false
    #endif

    var body: some View {
        #if os(iOS)
        GeometryReader { geo in
            ScrollView {
                settingsBody(maxLogPanelHeight: Self.maxLogPanelHeight(in: geo))
            }
            .demarDetailNavigationTitle(String(localized: "App settings"))
        }
        .navigationDestination(isPresented: $showTunSettings) {
            TunSettingsView(isFree: isFree, onBuySubscription: onBuySubscription)
        }
        #else
        GeometryReader { geo in
            VStack(spacing: 0) {
                settingsBody(maxLogPanelHeight: Self.maxLogPanelHeight(in: geo))
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 16)
        .background(Color.demarSurface)
        .navigationTitle(String(localized: "App settings"))
        .navigationDestination(isPresented: $showTunSettings) {
            TunSettingsView(isFree: isFree, onBuySubscription: onBuySubscription)
        }
        .languageMenu(isPresented: $showLanguagePicker, currentCode: language.code) { code in
            language.select(code)
        }
        #endif
    }

    private func settingsBody(maxLogPanelHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            SettingsActionButton(
                systemImage: "globe",
                title: String(localized: "Change language"),
                subtitle: language.displayName,
                action: changeLanguage
            )

            SettingsActionButton(
                systemImage: "lock.shield",
                title: "Routing",
                subtitle: String(localized: "Exclude site groups from the tunnel"),
                showsChevron: true,
                action: { showTunSettings = true }
            )

            DiagnosticsLogCard(
                expanded: $logExpanded,
                maxLogPanelHeight: maxLogPanelHeight
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private func changeLanguage() {
        #if os(iOS)
        AppLanguage.openSystemLanguageSettings()
        #else
        showLanguagePicker = true
        #endif
    }

    private static func maxLogPanelHeight(in geo: GeometryProxy) -> CGFloat {
        let chrome: CGFloat = 340
        let available = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - chrome
        return max(120, available)
    }
}

private struct DiagnosticsLogCard: View {
    @Binding var expanded: Bool
    let maxLogPanelHeight: CGFloat
    @Bindable private var log = AppLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 16) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.demarPrimary)
                        .frame(width: 26, height: 26)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.demarPrimary.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Journal")
                            .font(.demarTitleMedium)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.demarOnSurface)
                        Text("App and VPN core messages")
                            .font(.demarBodySmall)
                            .foregroundStyle(Color.demarOnSurface.opacity(0.70))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    logPanel
                    logToolbar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.demarSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.28), value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityHint(
            expanded
                ? String(localized: "Tap to collapse the journal")
                : String(localized: "Tap to expand the journal")
        )
    }

    @ViewBuilder
    private var logPanel: some View {
        if log.isEmpty {
            Text("Empty for now")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            DiagnosticsJournalTextView(text: log.panelText)
                .frame(maxWidth: .infinity)
                .frame(height: maxLogPanelHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.demarOutlineVariant, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var logToolbar: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            Button {
                log.clear()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.demarLabelLarge)
            }

            ShareLink(item: log.exportFileURL()) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.demarLabelLarge)
            }
            .disabled(log.isEmpty)
        }
        .foregroundStyle(Color.demarPrimary)
        .opacity(log.isEmpty ? 0.45 : 1)
        .padding(.top, 2)
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.28)) {
            expanded.toggle()
        }
        PlatformServices.lightImpact()
    }
}
