# Demar Proxy (Apple) — структура проекта

По мере появления файлов синхронизируй дерево с фактическим кодом.

```
DemarVPN/                              # SwiftUI target
├── DemarVPNApp.swift                  # @main, тема, macOS размер окна + зонды
├── ContentView.swift                  # TabView / NavigationSplitView
├── Info.plist                         # iOS, ATT
├── Info-macOS.plist                   # macOS bundle
├── DemarVPN.entitlements              # App Group + sandbox client (no server)
├── Assets.xcassets/                   # иконка, accent
│
├── Core/
│   ├── Theme/
│   │   ├── DemarTheme.swift           # цвета, шрифты
│   │   └── AppTheme.swift             # UIKit nav/tab (iOS)
│   ├── Icons/
│   │   └── FontAwesomeBrands.swift    # FA brands, соцссылки
│   ├── Models/
│   │   ├── VpnConnectionState.swift   # enum статуса VPN
│   │   ├── ServerProfile.swift        # профиль сервера + UI metadata/filters
│   │   ├── ServerReachability.swift   # TCP/TLS/QUIC ping state + UplinkProbe
│   │   └── TestServers.swift          # тестовые профили
│   ├── Network/
│   │   ├── DemarHttp.swift            # URLSession, UA, vpnPost/Get, retry/reset, DemarAPIError
│   │   ├── AuthApi.swift              # auth.example.invalid / account.example.invalid auth
│   │   ├── ServersApi.swift           # POST vpn.example.invalid/vpn/servers → profiles
│   │   ├── TunGroupsApi.swift         # GET vpn.example.invalid/tun → site groups
│   │   ├── VpnAccountApi.swift        # POST /vpn/account|notify|traffic
│   │   ├── PayApi.swift               # GET /vpn/pay/plans, POST create|status
│   │   ├── PromoApi.swift             # POST /vpn/promo/activate|apply
│   │   ├── SupportApi.swift           # csauth.example.invalid tickets / themes / media
│   │   ├── PublicEgressDiagnostics.swift # IP, зонды TCP/HTTPS/TLS (+ QUIC API)
│   │   ├── SalamanderObfs.swift       # HY2 salamander wrap (blake2b) for QUIC ping
│   │   └── LegalDocuments.swift       # ToS/PP via DemarHttp Markdown fetch
│   ├── Vpn/
│   │   ├── ProxyProfile.swift         # enum HY2 / Trojan / VLESS / OpenFlux → connectPlan
│   │   ├── Hysteria2Profile.swift     # Hysteria2 профиль (+ alpn/obfs)
│   │   ├── TrojanProfile.swift        # Trojan (password + TLS)
│   │   ├── VlessRealityProfile.swift  # VLESS Reality (uuid + utls + reality)
│   │   ├── OpenFluxNative.h/.m        # ObjC bridge → liboflux (host only)
│   │   ├── ApiBypassRuleSet.swift     # API route.rule_set (geoip/geosite)
│   │   ├── TunModels.swift            # site groups / TunSettings / effective bypass hosts
│   │   ├── SingBoxConnectPlan.swift   # profile → outbound + tun; DemarControlPlane hosts
│   │   └── SingBoxConfigBuilder.swift # Sing-box JSON TUN
│   ├── Services/
│   │   ├── AppState.swift             # @Observable state, init, bootstrap helpers
│   │   ├── AppState+Vpn.swift         # connect/disconnect/switch/status/throughput
│   │   ├── AppState+AuthSession.swift # auth, session refresh, sign-out, version
│   │   ├── AppState+AccountPay.swift  # AccountFlowSheet host (checkout/pay/traffic/alerts)
│   │   ├── AuthSessionStore.swift     # UserDefaults session + auth orchestration
│   │   ├── SessionCacheStore.swift    # servers/account/traffic/tun/reachability disk cache
│   │   ├── ServersPreferencesStore.swift # favorites + tier/protocol filters
│   │   ├── TunSettingsStore.swift     # site-group prefs + in-memory catalog
│   │   ├── SupportStore.swift         # ticket cache + unread badge
│   │   ├── SubscriptionAlertStore.swift # Expiry / FreeTraffic cooldown + windows
│   │   ├── AppLanguage.swift          # open system per-app language settings
│   │   ├── VpnControlling.swift       # connect/disconnect API
│   │   ├── NativeVpnService.swift     # → VpnTunnelController
│   │   ├── VpnStatusMonitor.swift     # NEVPNStatus → UI
│   │   ├── AppLog.swift               # журнал, маскировка IP
│   │   ├── DeviceIdentity.swift         # IDFV/UUID, fingerprint
│   │   └── IDFATracking.swift         # ATT, IDFA
│   └── Utilities/
│       ├── ThroughputFormatter.swift  # KB/s
│       ├── PlatformServices.swift     # pasteboard, haptic
│       ├── MacVpnDiag.swift            # pluginkit, NE preflight
│       ├── AppPlatform.swift          # «iOS» / «macOS» + supportChannel
│       ├── BundledCoreVersion.swift    # версия core из bundle
│       ├── AppRuntimeUpgrade.swift    # wipe App Group VPN runtime on app/core bump
│       ├── DemarNavigation.swift      # секции, demarPush, route IDs/deep links, demarDetailNavigationTitle
│       └── Flight.swift               # keyed coalesce concurrent async callers
│
├── Components/
│   ├── SectionCard.swift              # карточка-секция
│   ├── DemarCardRow.swift             # demarScrollScreen
│   ├── DemarKvRow.swift               # key / value
│   ├── VpnMainToggle.swift            # кнопка VPN
│   ├── SettingsActionButton.swift     # кнопка в настройках (+ unread)
│   ├── DemarBottomSheet.swift         # единый bottom sheet (iOS sheet / macOS overlay)
│   ├── SettingsLinksStrip.swift       # соцссылки
│   ├── DemarSnackBar.swift            # тосты
│   ├── DynamicIslandBadge.swift       # marketing badge на DI (iOS only)
│   └── DiagnosticsJournalTextView.swift # текстовый лог
│
├── Resources/
│   ├── en.lproj/Localizable.strings   # UI strings (en)
│   ├── ru.lproj/Localizable.strings   # UI strings (ru)
│   ├── uk.lproj/Localizable.strings   # UI strings (uk)
│   ├── tr.lproj/Localizable.strings   # UI strings (tr)
│   ├── uz.lproj/Localizable.strings   # UI strings (uz, Latin)
│   ├── zh-Hans.lproj/Localizable.strings  # Simplified Chinese
│   ├── zh-Hant.lproj/Localizable.strings  # Traditional Chinese
│   ├── ko.lproj/Localizable.strings   # Korean
│   ├── ja.lproj/Localizable.strings   # Japanese
│   ├── es.lproj/Localizable.strings   # Spanish
│   ├── de.lproj/Localizable.strings   # German
│   ├── fr.lproj/Localizable.strings   # French
│   ├── hi.lproj/Localizable.strings   # Hindi
│   ├── InfoPlist.xcstrings            # privacy / NE usage (all locales)
│   ├── silent.wav                     # iOS OpenFlux/WL host keep-alive (loop)
│   ├── TunBypass/                     # geoip-*.cidrs.json (aggregated ≤/20) → NE excludedRoutes
│   ├── RuleSets/                      # ads + geosite-*.srs (gitignore; sync_rulesets.ps1)
│   └── Fonts/
│       ├── fa-brands-400.ttf
│       └── MaterialSymbolsOutlined.ttf  # резерв
│
└── Features/
    ├── Home/HomeView.swift            # toggle, скорость, details sheet
    ├── Servers/
    │   ├── ServersView.swift          # список + toolbar refresh/filters
    │   ├── ServerBadges.swift         # tier/protocol badges
    │   ├── ServerFiltersSheet.swift   # multi-select tier + protocol
    │   └── ServerDetailsSheet.swift   # load / ping / traffic / favorites
    ├── Account/
    │   ├── AccountView.swift          # сессия / подписка / notify / трафик / checkout
    │   ├── SubscriptionCheckoutSheet.swift # Plus/VIP × period × currency + pay
    │   ├── PlanCompareSheet.swift       # compare table (separate sheet)
    │   ├── PayResultSheet.swift         # pay deeplink ok/fail → icon + OK
    │   ├── SubscriptionInfoSheet.swift  # Expiry / FreeTraffic upsell sheets
    │   └── TrafficPieChart.swift        # donut + TrafficBottomSheet
    ├── Auth/LoginSheet.swift          # Email OTP + TOTP + Telegram OAuth
    └── Settings/
        ├── SettingsView.swift         # настройки, 3 тапа → service
        ├── AppSettingsView.swift      # language + TUN + журнал
        ├── TunSettingsView.swift      # site-group bypass (из App settings)
        ├── ServiceMenuView.swift      # служебное меню
        ├── DocumentsMenuSheet.swift   # ToS/PP через demarBottomSheet
        ├── LanguageMenuSheet.swift    # macOS: выбор языка флагами
        ├── LegalDocumentView.swift    # MarkdownUI viewer
        ├── CustomEgressProbes.swift   # свои хосты зондов
        └── Support/
            ├── SupportScreen.swift    # ticket list / draft entry
            ├── SupportChatPane.swift  # chat + polling / send
            ├── SupportComposer.swift  # input bar + glass chrome
            ├── SupportBubble.swift    # message bubble / album / menu
            ├── SupportAttach.swift    # gallery photo ingest / WebP compress
            └── SupportHelpers.swift   # errors, time, linkify

DemarVPNTests/                         # unit tests (Sing-box, connect hot-path, TUN sites, servers filter/reachability, account/pay parse, interface, legal docs)
DemarVPN.xcodeproj/                    # app + tunnel + controls

readme.md                              # сборка
readme-core.md                         # ядро VPN/Sing-box
singbox-version.txt                    # единая закреплённая версия core

scripts/
├── journal.sh                         # pull vpn_journal.log (macos/sim/ios)
├── singbox-download-auto.py           # latest sing-box + geo db
├── openflux-build-apple.sh            # OpenFlux liboflux.a → ios/Frameworks/OpenFlux
├── gen-tun-bypass-cidrs.py            # geoip-*.cidrs.json (coarsen ≤/20 + aggregate)
├── sync_rulesets.ps1                  # ads + geosite-ru/ir/cn → Resources/RuleSets
├── libbox-build.py                    # Libbox.xcframework (latest)
├── upload-testflight.ps1              # App Store archive/upload (syncs ads first)
├── sign-singbox-in-appex.sh           # iOS appex binary signing
├── increment_version_common.ps1
├── ios-export-options.plist
└── macos-export-options.plist

macos/
└── singbox_macos/                      # geo db + dev sing-box CLI (gitignore)

ios/
├── Shared/
│   ├── VpnAppGroup.swift              # App Group paths
│   ├── DemarLogTime.swift             # journal stamp yyyy-MM-dd-HH-mm-ss (UTC)
│   ├── VpnSharedStore.swift           # payload, control state, session/stop, OFX link
│   ├── VpnSharedStore+Journal.swift   # journal append / import / mirror
│   ├── VpnSharedStore+Heartbeat.swift # heartbeat, throughput, start failure
│   ├── OpenFluxSocksProfile.swift     # OpenFlux / White List (local SOCKS)
│   ├── OpenFluxLink.swift             # decode openflux://v1 → secret + boards URL
│   ├── OpenFluxHostProcess.swift      # host liboflux SOCKS + iOS silent-audio keep-alive
│   ├── VpnHostHooks.swift             # host-only OpenFlux reconnect hook
│   ├── LoopbackPortWait.swift         # shared TCP poll for host/NE SOCKS ready
│   ├── TunBypassCidrs.swift           # geoip CIDR sidecars → NEIPv4Route (cached)
│   ├── ClashTraffic.swift             # parse Clash /traffic NDJSON sample
│   ├── DefaultInterfaceReporter.swift # sticky default iface + debounce для libbox
│   ├── UplinkIPv4Resolver.swift       # getaddrinfo + TTL DNS cache
│   ├── VpnTunnelError.swift           # NE connect errors
│   ├── VpnTunnelController.swift      # NE manager cache / status / commands
│   ├── VpnTunnelController+Connect.swift    # connect / startTunnel / prefs fast-path
│   ├── VpnTunnelController+Lifecycle.swift  # disconnect / revoke / remove profiles
│   ├── VpnTunnelController+Readiness.swift  # wait connected + heartbeat
│   ├── VpnTunnelController+MacDiag.swift    # macOS preflight / post-start probes
│   ├── VpnControlConstants.swift      # kind CC widget
│   ├── VpnControlIntent.swift         # CC toggle intent
│   ├── VpnStatusSignal.swift          # Darwin notify
│   └── singbox/                       # geo db (gitignore bin)
├── DemarControls/                     # Control Center (iOS 18+)
│   ├── DemarControlsBundle.swift
│   ├── VpnToggleControl.swift         # CC toggle UI (strings from app Localizable)
│   ├── Info.plist
│   └── DemarControls.entitlements
├── DemarPacketTunnel/
│   ├── PacketTunnelProvider.swift     # tunnel + Libbox + OpenFlux wait
│   ├── OpenFluxSidecar.swift          # wait for host SOCKS (no liboflux in NE)
│   ├── TunnelLifecycle.swift          # path monitor (iOS + macOS)
│   ├── IOSLibboxCore.swift            # Libbox in-process (iOS + macOS)
│   ├── DemarLibboxPlatform.swift      # NE platform interface
│   ├── ClashTrafficMonitor.swift      # stream Clash /traffic → App Group
│   ├── LibboxRunBlocking.swift        # async bridge for openTun
│   ├── Info.plist
│   └── DemarPacketTunnel.entitlements # + network.server (Clash/diag listen)
└── Frameworks/
    ├── README.md                      # Libbox build инструкции
    ├── Libbox.xcframework/            # sing-box gomobile (gitignore; libbox-build.py)
    └── OpenFlux/                      # liboflux.h + iphoneos/ + macosx/ (host only)
```
