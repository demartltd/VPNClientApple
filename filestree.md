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
│   │   ├── ServerProfile.swift        # VLESS профиль в UI
│   │   └── TestServers.swift          # тестовые URI
│   ├── Network/
│   │   ├── DeviceTrafficTotals.swift  # RX/TX getifaddrs
│   │   └── PublicEgressDiagnostics.swift # IP, зонды TCP/HTTPS
│   ├── Vpn/
│   │   ├── VlessRealityProfile.swift  # поля REALITY
│   │   ├── VlessUriParser.swift       # vless:// → модель
│   │   └── XrayConfigBuilder.swift    # JSON TUN + VLESS
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
│       ├── BundledXrayVersion.swift    # версия из bundle
│       └── DemarNavigation.swift      # секции навигации
│
├── Components/
│   ├── SectionCard.swift              # карточка-секция
│   ├── DemarCardRow.swift             # строка списка
│   ├── DemarKvRow.swift               # key / value
│   ├── VpnMainToggle.swift            # кнопка VPN
│   ├── SettingsActionButton.swift     # кнопка в настройках
│   ├── SettingsLinksStrip.swift       # соцссылки
│   ├── DemarSnackBar.swift            # тосты
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
        ├── SettingsView.swift         # настройки, 7 тапов → service
        ├── AppSettingsView.swift      # журнал
        ├── ServiceMenuView.swift      # служебное меню
        └── CustomEgressProbes.swift   # свои хосты зондов

DemarVPN.xcodeproj/                    # app + tunnel + controls

readme.md                              # сборка
readme-core.md                         # ядро VPN/Xray

scripts/
├── xray-download-auto.py              # geo + xray
├── generate_icons.py                  # AppIcon
├── build-macos.ps1                    # build, sign, notarize
├── build-macos.local.ps1              # локальный конфиг
├── increment_version_auto.ps1         # bump version
├── increment_version.ps1              # version интерактивно
├── increment_version_common.ps1       # shared bump
└── push-github.ps1                    # push / tag

ios/
├── Shared/
│   ├── VpnAppGroup.swift              # App Group paths
│   ├── VpnSharedStore.swift           # journal, payload, state
│   ├── VpnTunnelController.swift      # NETunnelProviderManager
│   ├── VpnControlConstants.swift      # kind CC widget
│   ├── VpnControlIntent.swift         # CC toggle intent
│   ├── VpnStatusSignal.swift          # Darwin notify
│   └── xray/                          # geo (gitignore bin)
├── DemarControls/                     # Control Center (iOS 18+)
│   ├── DemarControlsBundle.swift
│   ├── VpnToggleControl.swift         # CC toggle UI
│   ├── Info.plist
│   └── DemarControls.entitlements
├── DemarPacketTunnel/
│   ├── PacketTunnelProvider.swift     # tunnel + xray
│   ├── TunnelLifecycle.swift          # path monitor (iOS)
│   ├── MacXrayProcess.swift           # subprocess (macOS)
│   ├── FlutterExtension.xcconfig      # legacy paths
│   ├── Info.plist
│   └── DemarPacketTunnel.entitlements
└── Frameworks/
    ├── README.md
    └── DemarXray.xcframework/         # iOS Xray (gitignore bin)

macos/
└── xray_macos/                        # xray arm64 (gitignore)
    └── README.md
```

## Связь с demar_vpn

Эталон UI: `demar_vpn/lib/presentation/`.  
VPN iOS: `demar_vpn/ios/`.  
Assets: `python3 scripts/xray-download-auto.py`.  
XCFramework: `python ../demar_vpn/scripts/build_xray_ios_xcframework.py`.
