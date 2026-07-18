import SwiftUI

struct AppSettingsView: View {
    @State private var logExpanded = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                DiagnosticsLogCard(
                    expanded: $logExpanded,
                    maxLogPanelHeight: Self.maxLogPanelHeight(in: geo)
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 16)
        .background(Color.demarSurface)
        .navigationTitle("Настройки приложения")
        .demarInlineNavigationTitle()
    }

    /// Header, toolbar, card chrome, and nav bar — remainder goes to the log scroll area.
    private static func maxLogPanelHeight(in geo: GeometryProxy) -> CGFloat {
        let chrome: CGFloat = 212
        let available = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - chrome
        return max(120, available)
    }
}

private struct DiagnosticsLogCard: View {
    @Binding var expanded: Bool
    let maxLogPanelHeight: CGFloat
    @Bindable private var log = AppLog.shared

    var body: some View {
        SectionCard(
            title: "Журнал",
            subtitle: "Сообщения приложения и ядра VPN",
            bodyTopSpacing: expanded ? 12 : 0,
            onHeaderTap: toggleExpanded,
            leading: {
                Image(systemName: "doc.text")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.demarPrimary)
            },
            trailing: { expandChevron }
        ) {
            expandedBody
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(expanded ? "Нажмите, чтобы свернуть журнал" : "Нажмите, чтобы развернуть журнал")
    }

    @ViewBuilder
    private var expandedBody: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 10) {
                logPanel
                logToolbar
            }
        }
    }

    private var expandChevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.demarOnSurfaceVariant)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .animation(.snappy(duration: 0.28), value: expanded)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var logPanel: some View {
        if log.isEmpty {
            Text("Пока пусто")
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurfaceVariant)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            // panelText is rebuilt lazily; UITextView skips identical replacements.
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
                Label("Очистить", systemImage: "trash")
                    .font(.demarLabelLarge)
            }

            ShareLink(item: log.exportFileURL()) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
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
