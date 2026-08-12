# Demar Proxy (Apple) — структура проекта

По мере появления файлов синхронизируй дерево с фактическим кодом.

```
DemarVPN/                              # SwiftUI target
├── DemarVPNApp.swift                  # @main, тема, macOS окно зондов
├── ContentView.swift                  # TabView / NavigationSplitView
├── Info.plist                         # iOS, ATT
├── Info-macOS.plist                   # macOS bundle
├── DemarVPN.entitlements              # App Group + sandbox client (no server)
├── Assets.xcassets/                   # иконка, accent
│
├── Core/
│   ├── Theme/
│   │   ├── DemarTheme.swift           # цвета, шрифты M3
│   │   └── AppTheme.swift             # UIKit nav/tab (iOS)
│   ├── Icons/
│   │   └── FontAwesomeBrands.swift    # FA brands, соцссылки
│   ├── Models/
│   │   ├── VpnConnectionState.swift   # enum статуса VPN
│   │   ├── ServerProfile.swift        # профиль сервера + UI metadata/filters
│   │   └── TestServers.swift          # тестовые профили
│   ├── Network/
│   │   ├── DemarHttp.swift            # URLSession + CF-edge DPI remap (api/fastapi/account)
│   │   ├── AuthApi.swift              # auth.example.invalid / account.example.invalid auth
│   │   ├── ServersApi.swift           # POST vpn.example.invalid/vpn/servers → profiles
│   │   ├── VpnAccountApi.swift        # POST /vpn/account|notify|traffic
│   │   ├── PublicEgressDiagnostics.swift # IP, зонды TCP/HTTPS
│   │   └── LegalDocuments.swift       # ToS/PP raw GitHub Markdown fetch
│   ├── Vpn/
│   │   ├── Hysteria2Profile.swift     # Hysteria2 профиль (+ alpn/obfs)
│   │   ├── ApiBypassRuleSet.swift     # API route.rule_set (geoip/geosite)
│   │   ├── SingBoxConnectPlan.swift   # profile → outbound + tun options
│   │   └── SingBoxConfigBuilder.swift # Sing-box JSON TUN
│   ├── Services/
│   │   ├── AppState.swift             # UI state, auth, servers, account/traffic, toggle VPN
│   │   ├── AuthSessionStore.swift     # UserDefaults session + auth orchestration
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
│       ├── AppPlatform.swift          # «iOS» / «macOS»
│       ├── BundledCoreVersion.swift    # версия core из bundle
│       └── DemarNavigation.swift      # секции + demarDetailNavigationTitle (iOS scroll title)
│
├── Components/
│   ├── SectionCard.swift              # карточка-секция
│   ├── DemarCardRow.swift             # demarScrollScreen
│   ├── DemarKvRow.swift               # key / value
│   ├── VpnMainToggle.swift            # кнопка VPN
│   ├── SettingsActionButton.swift     # кнопка в настройках
│   ├── DemarBottomSheet.swift         # единый bottom sheet (iOS sheet / macOS overlay)
│   ├── SettingsLinksStrip.swift       # соцссылки
│   ├── DemarSnackBar.swift            # тосты
│   ├── ServersRefreshBanner.swift     # top banner при pull-refresh серверов
│   ├── DynamicIslandBadge.swift       # marketing badge на DI (iOS only)
│   └── DiagnosticsJournalTextView.swift # текстовый лог
│
├── Resources/
│   ├── en.lproj/Localizable.strings   # UI strings (en)
│   ├── ru.lproj/Localizable.strings   # UI strings (ru)
│   ├── InfoPlist.xcstrings            # privacy / NE usage ru/en
│   ├── TunBypass/                     # geoip-*.cidrs.json → NE excludedRoutes
│   └── Fonts/
│       ├── fa-brands-400.ttf
│       └── MaterialSymbolsOutlined.ttf  # резерв
│
└── Features/
    ├── Home/HomeView.swift            # toggle, скорость
    ├── Servers/ServersView.swift      # выбор сервера (API)
    ├── Account/
    │   ├── AccountView.swift          # сессия / подписка / notify / трафик
    │   └── TrafficPieChart.swift      # donut + legend по серверам
    ├── Auth/LoginSheet.swift          # Email OTP + TOTP + Telegram OAuth
    └── Settings/
        ├── SettingsView.swift         # настройки, 3 тапа → service
        ├── AppSettingsView.swift      # Change language + журнал
        ├── ServiceMenuView.swift      # служебное меню
        ├── DocumentsMenuSheet.swift   # ToS/PP через demarBottomSheet
        ├── LegalDocumentView.swift    # MarkdownUI viewer
        └── CustomEgressProbes.swift   # свои хосты зондов

DemarVPNTests/                         # unit tests (Sing-box, servers/account parse, DemarHttp control hosts, interface, legal docs)
DemarVPN.xcodeproj/                    # app + tunnel + controls

readme.md                              # сборка
readme-core.md                         # ядро VPN/Sing-box
singbox-version.txt                    # единая закреплённая версия core

scripts/
├── journal.sh                         # pull vpn_journal.log (macos/sim/ios)
├── singbox-download-auto.py           # latest sing-box + geo db
├── gen-tun-bypass-cidrs.py            # geoip-*.cidrs.json from sing-geoip .srs
├── libbox-build.py                    # Libbox.xcframework (latest)
├── upload-testflight.ps1              # App Store archive/upload
├── sign-singbox-in-appex.sh           # iOS appex binary signing
├── increment_version_auto.ps1
├── increment_version_common.ps1
├── ios-export-options.plist
└── macos-export-options.plist

macos/
└── singbox_macos/                      # geo db + dev sing-box CLI (gitignore)

ios/
├── Shared/
│   ├── VpnAppGroup.swift              # App Group paths
│   ├── DemarLogTime.swift             # journal stamp yyyy-MM-dd-HH-mm-ss (UTC)
│   ├── VpnSharedStore.swift           # journal, payload, state, Clash throughput
│   ├── TunBypassCidrs.swift           # geoip CIDR sidecars → NEIPv4Route
│   ├── ClashTraffic.swift             # parse Clash /traffic NDJSON sample
│   ├── DefaultInterfaceReporter.swift # sticky default iface + debounce для libbox
│   ├── VpnTunnelController.swift      # NETunnelProviderManager
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
│   ├── PacketTunnelProvider.swift     # tunnel + Libbox
│   ├── TunnelLifecycle.swift          # path monitor (iOS + macOS)
│   ├── IOSLibboxCore.swift            # Libbox in-process (iOS + macOS)
│   ├── DemarLibboxPlatform.swift      # NE platform interface
│   ├── ClashTrafficMonitor.swift      # stream Clash /traffic → App Group
│   ├── LibboxRunBlocking.swift        # async bridge for openTun
│   ├── Info.plist
│   └── DemarPacketTunnel.entitlements # + network.server (Clash/diag listen)
└── Frameworks/
    ├── README.md                      # Libbox build инструкции
    └── Libbox.xcframework/            # sing-box gomobile (gitignore; libbox-build.py)
```

## Связь с demar_vpn

Эталон UI: `demar_vpn/lib/presentation/`.  
VPN iOS: `demar_vpn/ios/`.  
Assets: `python3 scripts/singbox-download-auto.py`.
