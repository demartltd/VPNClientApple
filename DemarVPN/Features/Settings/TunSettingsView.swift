import SwiftUI

struct TunSettingsView: View {
    let isFree: Bool
    var onBuySubscription: (() -> Void)?

    @State private var rulesEnabled = TunSettingsStore.currentSettings.rulesEnabled
    @State private var adBlockOverride = TunSettingsStore.currentSettings.adBlockEnabled
    @State private var catalog = TunSettingsStore.currentCatalog
    @State private var overrides = TunSettingsStore.currentSettings.siteGroupOverrides
    @State private var customHosts = TunSettingsStore.currentSettings.bypassHosts
    @State private var expanded = Set<String>()
    @State private var customSitesExpanded = false
    @State private var siteDraft = ""
    @FocusState private var siteFieldFocused: Bool

    private var rulesOn: Bool { isFree || rulesEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsActionButton(
                    systemImage: "hand.raised",
                    title: "Ad block",
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
                    title: "Routing",
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

                customSitesSection
                    .padding(.top, 16)
                    .opacity(rulesOn ? 1 : 0.4)

                if catalog.siteGroups.isEmpty {
                    Text(String(localized: "No site groups yet. Pull to refresh servers while signed in."))
                        .font(.demarBodyMedium)
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                        .padding(.top, 24)
                } else {
                    Text(String(localized: "Site Groups"))
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
                    .opacity(rulesOn ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .demarScrollScreen()
        #if os(iOS)
        .demarDetailNavigationTitle("Routing")
        #else
        .navigationTitle("Routing")
        #endif
        .scrollDismissesKeyboard(.interactively)
        .task { await reload() }
        .onChange(of: isFree) { _, free in
            guard free else { return }
            rulesEnabled = true
            adBlockOverride = nil
            overrides = [:]
            customHosts = TunSettingsStore.currentSettings.bypassHosts
            siteDraft = ""
            siteFieldFocused = false
        }
    }

    private var customSitesTitle: String {
        let base = String(localized: "Custom sites")
        return customHosts.isEmpty ? base : "\(base) (\(customHosts.count))"
    }

    @ViewBuilder
    private var customSitesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsActionButton(
                systemImage: "globe",
                title: customSitesTitle,
                subtitle: String(localized: isFree
                    ? "Available with a paid subscription"
                    : "Paste links separated by commas"),
                action: rulesOn ? { toggleCustomSites() } : nil,
                trailing: {
                    Image(systemName: customSitesExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.demarOnSurfaceVariant)
                }
            )

            if customSitesExpanded, rulesOn {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(String(localized: "example.com"), text: $siteDraft)
                        .textFieldStyle(.plain)
                        .font(.demarBodyMedium)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                        .submitLabel(.done)
                        .focused($siteFieldFocused)
                        .disabled(isFree)
                        .opacity(isFree ? 0.4 : 1)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.demarSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.demarOutline.opacity(0.20), lineWidth: 1)
                                )
                        )
                        .onSubmit(commitSiteDraft)

                    ForEach(customHosts, id: \.self) { host in
                        customHostRow(host)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func customHostRow(_ host: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.demarPrimary.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.demarPrimary)
                }

            Text(host)
                .font(.demarBodyMedium)
                .foregroundStyle(Color.demarOnSurface)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                TunSettingsStore.removeBypassHost(host)
                customHosts = TunSettingsStore.currentSettings.bypassHosts
                PlatformServices.lightImpact()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.demarOnSurfaceVariant)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private func toggleCustomSites() {
        withAnimation(.snappy(duration: 0.22)) {
            customSitesExpanded.toggle()
        }
        if !customSitesExpanded {
            siteFieldFocused = false
        }
        PlatformServices.lightImpact()
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.snappy(duration: 0.22)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
        PlatformServices.lightImpact()
    }

    private func commitSiteDraft() {
        guard !isFree else { return }
        _ = TunSettingsStore.addBypassHosts(siteDraft)
        customHosts = TunSettingsStore.currentSettings.bypassHosts
        siteDraft = ""
        siteFieldFocused = false
    }

    @MainActor
    private func reload() async {
        TunSettingsStore.loadIfNeeded()
        let settings = TunSettingsStore.currentSettings
        rulesEnabled = settings.rulesEnabled
        adBlockOverride = settings.adBlockEnabled
        overrides = settings.siteGroupOverrides
        customHosts = settings.bypassHosts
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
