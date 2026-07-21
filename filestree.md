# Demar VPN (Apple) — структура проекта

По мере появления файлов синхронизируй дерево с фактическим кодом.

```
DemarVPN/                              # SwiftUI target
├── DemarVPNApp.swift                  # @main, тема, macOS окно зондов
├── ContentView.swift                  # TabView / NavigationSplitView
├── Info.plist                         # iOS, ATT
├── Info-macOS.plist                   # macOS bundle
├── DemarVPN.entitlements              # App Group
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
│   │   ├── DeviceTrafficTotals.swift  # RX/TX getifaddrs
│   │   ├── PublicEgressDiagnostics.swift # IP, зонды TCP/HTTPS
│   │   └── LegalDocuments.swift       # ToS/PP raw GitHub Markdown fetch
│   ├── Vpn/
│   │   ├── Hysteria2Profile.swift     # Hysteria2 профиль
│   │   ├── SingBoxConnectPlan.swift   # profile → outbound + tun options
│   │   └── SingBoxConfigBuilder.swift # Sing-box JSON TUN
│   ├── Services/
│   │   ├── AppState.swift             # UI state, toggle VPN
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
│       └── DemarNavigation.swift      # секции навигации
│
├── Components/
│   ├── SectionCard.swift              # карточка-секция
│   ├── DemarCardRow.swift             # demarScrollScreen + top curtain
│   ├── DemarKvRow.swift               # key / value
│   ├── VpnMainToggle.swift            # кнопка VPN
│   ├── SettingsActionButton.swift     # кнопка в настройках
│   ├── SettingsLinksStrip.swift       # соцссылки
│   ├── DemarSnackBar.swift            # тосты
│   ├── ServersRefreshBanner.swift     # top banner при pull-refresh серверов
│   └── DiagnosticsJournalTextView.swift # текстовый лог
│
├── Resources/Fonts/
│   ├── fa-brands-400.ttf
│   └── MaterialSymbolsOutlined.ttf    # резерв
│
└── Features/
    ├── Home/HomeView.swift            # toggle, скорость
    ├── Servers/ServersView.swift      # выбор сервера
    ├── Account/AccountView.swift      # вход MVP
    └── Settings/
        ├── SettingsView.swift         # настройки, 3 тапа → service
        ├── AppSettingsView.swift      # журнал
        ├── ServiceMenuView.swift      # служебное меню
        ├── DocumentsMenuSheet.swift   # bottom sheet ToS / PP
        ├── LegalDocumentView.swift    # MarkdownUI viewer
        └── CustomEgressProbes.swift   # свои хосты зондов

DemarVPNTests/                         # unit tests (Sing-box, interface, legal docs)
DemarVPN.xcodeproj/                    # app + tunnel + controls

readme.md                              # сборка
readme-core.md                         # ядро VPN/Sing-box
singbox-version.txt                    # единая закреплённая версия core

scripts/
├── journal.sh                         # pull vpn_journal.log (macos/sim/ios)
├── singbox-download-auto.py           # latest sing-box + geo db
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
│   ├── VpnSharedStore.swift           # journal, payload, state
│   ├── DefaultInterfaceReporter.swift # sticky default iface + debounce для libbox
│   ├── VpnTunnelController.swift      # NETunnelProviderManager
│   ├── VpnControlConstants.swift      # kind CC widget
│   ├── VpnControlIntent.swift         # CC toggle intent
│   ├── VpnStatusSignal.swift          # Darwin notify
│   └── singbox/                       # geo db (gitignore bin)
├── DemarControls/                     # Control Center (iOS 18+)
│   ├── DemarControlsBundle.swift
│   ├── VpnToggleControl.swift         # CC toggle UI
│   ├── Info.plist
│   └── DemarControls.entitlements
├── DemarPacketTunnel/
│   ├── PacketTunnelProvider.swift     # tunnel + Libbox
│   ├── TunnelLifecycle.swift          # path monitor (iOS + macOS)
│   ├── IOSLibboxCore.swift            # Libbox in-process (iOS + macOS)
│   ├── DemarLibboxPlatform.swift      # NE platform interface
│   ├── LibboxRunBlocking.swift        # async bridge for openTun
│   ├── Info.plist
│   └── DemarPacketTunnel.entitlements
└── Frameworks/
    ├── README.md                      # Libbox build инструкции
    └── Libbox.xcframework/            # sing-box gomobile (gitignore; libbox-build.py)
```

## Связь с demar_vpn

Эталон UI: `demar_vpn/lib/presentation/`.  
VPN iOS: `demar_vpn/ios/`.  
Assets: `python3 scripts/singbox-download-auto.py`.
