import SwiftUI

struct TunSettingsView: View {
    let isFree: Bool
    var onBuySubscription: (() -> Void)?

    @State private var rulesEnabled = TunSettingsStore.currentSettings.rulesEnabled
    @State private var adBlockOverride = TunSettingsStore.currentSettings.adBlockEnabled
    @State private var catalog = TunSettingsStore.currentCatalog
    @State private var overrides = TunSettingsStore.currentSettings.siteGroupOverrides
    @State private var expanded = Set<String>()

    private var rulesOn: Bool { isFree || rulesEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsActionButton(
                    systemImage: "hand.raised",
                    title: String(localized: "Ad block"),
                    subtitle: String(localized: "Block ads via DNS"),
                    action: nil,
                    trailing: {
                        paidSwitch(Binding(
                            get: { isFree ? false : (adBlockOverride ?? true) },
                            set: { value in
                                guard !isFree else { return }
                                adBlockOverride = value
                                TunSettingsStore.setAdBlockEnabled(value)
                            }
                        ))
                    }
                )

                SettingsActionButton(
                    systemImage: "lock.shield",
                    title: String(localized: "TUN rules"),
                    subtitle: String(localized: "Exclude selected site groups from the VPN tunnel"),
                    action: nil,
                    trailing: { paidSwitch(paidBinding($rulesEnabled, free: true, TunSettingsStore.setRulesEnabled)) }
                )
                .padding(.top, 12)

                if isFree {
                    Button {
                        onBuySubscription?()
                    } label: {
                        Text(String(localized: "Buy subscription"))
                            .font(.demarTitleMedium)
                            .foregroundStyle(Color.demarOnPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.demarPrimary)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                }

                if catalog.siteGroups.isEmpty {
                    Text(String(localized: "No site groups yet. Pull to refresh servers while signed in."))
                        .font(.demarBodyMedium)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .padding(.top, 24)
                } else {
                    Text(String(localized: "Preset groups"))
                        .font(.demarTitleMedium)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.demarOnSurface)
                        .padding(.top, 24)

                    VStack(spacing: 12) {
                        ForEach(catalog.siteGroups) { group in
                            siteGroupBlock(group)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .demarScrollScreen()
        #if os(iOS)
        .demarDetailNavigationTitle(String(localized: "TUN settings"))
        #else
        .navigationTitle(String(localized: "TUN settings"))
        #endif
        .task { await reload() }
        .onChange(of: isFree) { _, free in
            guard free else { return }
            rulesEnabled = true
            adBlockOverride = nil
            overrides = [:]
        }
    }

    private func paidBinding(
        _ value: Binding<Bool>,
        free freeValue: Bool,
        _ persist: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { isFree ? freeValue : value.wrappedValue },
            set: { new in
                guard !isFree else { return }
                value.wrappedValue = new
                persist(new)
            }
        )
    }

    private func paidSwitch(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color.demarPrimary)
            .disabled(isFree)
    }

    @ViewBuilder
    private func siteGroupBlock(_ group: TunSiteGroup) -> some View {
        let on = overrides[group.id] ?? group.enabledByDefault
        let open = expanded.contains(group.id)

        VStack(alignment: .leading, spacing: 4) {
            SettingsActionButton(
                systemImage: "globe",
                title: "\(group.name) (\(group.sites.count))",
                subtitle: String(localized: "Excluded from the VPN tunnel"),
                action: { toggleExpanded(group.id) },
                trailing: {
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { value in
                            guard !isFree, rulesOn else { return }
                            if value == group.enabledByDefault {
                                overrides.removeValue(forKey: group.id)
                            } else {
                                overrides[group.id] = value
                            }
                            TunSettingsStore.setSiteGroupEnabled(
                                group.id,
                                enabled: value,
                                defaultEnabled: group.enabledByDefault
                            )
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.demarPrimary)
                    .disabled(isFree || !rulesOn)
                }
            )

            if open {
                VStack(spacing: 8) {
                    ForEach(group.sites, id: \.host) { site in
                        siteRow(site)
                    }
                }
                .padding(.top, 4)
            }
        }
        .clipped()
    }

    private func siteRow(_ site: TunSiteRef) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.demarPrimary.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.demarPrimary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .font(.demarBodyMedium)
                    .foregroundStyle(Color.demarOnSurface)
                    .lineLimit(1)
                if site.name.caseInsensitiveCompare(site.host) != .orderedSame {
                    Text(site.host)
                        .font(.demarBodySmall)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.snappy(duration: 0.22)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
        PlatformServices.lightImpact()
    }

    @MainActor
    private func reload() async {
        TunSettingsStore.loadIfNeeded()
        let settings = TunSettingsStore.currentSettings
        rulesEnabled = settings.rulesEnabled
        adBlockOverride = settings.adBlockEnabled
        overrides = settings.siteGroupOverrides
        catalog = TunSettingsStore.currentCatalog

        if let payload = await TunGroupsApi.fetch() {
            TunSettingsStore.cacheGroups(
                payload.catalog,
                raw: payload.raw,
                userId: AuthSessionStore.session?.userId
            )
            catalog = TunSettingsStore.currentCatalog
        }
    }
}
