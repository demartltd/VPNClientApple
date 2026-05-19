import SwiftUI

struct AppSettingsView: View {
    @State private var logExpanded = false

    var body: some View {
        ScrollView {
            DiagnosticsLogCard(expanded: $logExpanded)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
        .padding(.bottom, 16)
        .background(Color.demarSurface)
        .navigationTitle("Настройки приложения")
        .demarInlineNavigationTitle()
    }
}

private struct DiagnosticsLogCard: View {
    @Binding var expanded: Bool
    @Bindable private var log = AppLog.shared

    var body: some View {
        SectionCard(
            title: "Журнал",
            subtitle: "Сообщения приложения и ядра VPN",
            leading: {
                Image(systemName: "doc.text")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.demarPrimary)
            }
        ) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if log.lines.isEmpty {
                        Text("Пока пусто")
                            .font(.demarBodyMedium)
                            .foregroundStyle(Color.demarOnSurfaceVariant)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.demarOnSurface)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 260)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.demarOutlineVariant, lineWidth: 1)
                        )
                    }

                    HStack(spacing: 4) {
                        Button {
                            log.clear()
                        } label: {
                            Label("Очистить", systemImage: "trash")
                                .font(.demarLabelLarge)
                        }

                        Button {
                            PlatformServices.copyToPasteboard(log.joinedText)
                        } label: {
                            Label("Копировать", systemImage: "square.on.square")
                                .font(.demarLabelLarge)
                        }
                    }
                    .foregroundStyle(Color.demarPrimary)
                }
            } label: {
                Text(expanded ? "Свернуть" : "Развернуть")
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarPrimary)
            }
        }
    }
}
