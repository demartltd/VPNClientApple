# Demar VPN (Apple) — структура проекта

По мере появления файлов синхронизируй дерево с фактическим кодом.

```
DemarVPN/                              # SwiftUI app target
├── DemarVPNApp.swift                  # @main, AppState, тема
├── ContentView.swift                  # TabView; iOS: ATT при scenePhase == .active
├── Info.plist                         # iOS (+ NSUserTrackingUsageDescription для ATT)
├── Info-macOS.plist                   # macOS
├── DemarVPN.entitlements              # App Group (фаза VPN)
├── Assets.xcassets/
│
├── Core/
│   ├── Theme/
│   │   ├── DemarTheme.swift           # iOS-семантика цветов (accent, card, label, …)
│   │   └── AppTheme.swift             # UIKit chrome (tab bar, nav bar)
│   ├── Icons/
│   │   └── FontAwesomeBrands.swift    # соцсети (FA6 Brands, incl. Bluesky)
│   ├── Models/
│   │   ├── VpnConnectionState.swift   # disconnected / connecting / …
│   │   ├── ServerProfile.swift        # displayName + uri
│   │   └── TestServers.swift          # kTestServerUris (MVP)
│   ├── Vpn/
│   │   ├── VlessRealityProfile.swift
│   │   ├── VlessUriParser.swift       # vless:// → профиль
│   │   └── XrayConfigBuilder.swift    # TUN + VLESS REALITY config.json
│   ├── Services/
│   │   ├── AppState.swift             # @Observable: серверы, vpnState, throughput
│   │   ├── VpnControlling.swift       # протокол connect/disconnect
│   │   ├── IosVpnService.swift        # iOS: NETunnelProvider + Xray
│   │   ├── VpnStatusMonitor.swift     # iOS: NEVPNStatus → UI
│   │   ├── MockVpnControlling.swift   # macOS: мок VPN
│   │   ├── MockVpnService.swift       # задержки/throughput мока (macOS)
│   │   ├── AppLog.swift               # журнал для UI настроек
│   │   ├── DeviceIdentity.swift       # IDFV/IDFA (iOS), mac_* + fingerprint (macOS)
│   │   └── IDFATracking.swift        # iOS: ATT при старте; «Включить IDFA» → Настройки при отказе
│   └── Utilities/
│       ├── ThroughputFormatter.swift  # KB/s как во Flutter
│       ├── PlatformServices.swift     # pasteboard, haptics (iOS)
│       ├── AppPlatform.swift          # метка платформы iOS / macOS
│       └── DemarNavigation.swift      # navigationBarTitleDisplayMode (iOS)
│
├── Components/
│   ├── DemarCardRow.swift             # карточка списка (Сервера / Настройки)
│   ├── VpnMainToggle.swift
│   ├── SectionCard.swift
│   ├── DemarKvRow.swift               # key/value для служебного меню
│   ├── SettingsLinksStrip.swift
│   └── DemarSnackBar.swift            # toast: material, swipe, tap → copy
├── Resources/Fonts/
│   └── fa-brands-400.ttf
│
└── Features/
    ├── Home/
    │   └── HomeView.swift
    ├── Servers/
    │   └── ServersView.swift
    └── Settings/
        ├── SettingsView.swift
        ├── AppSettingsView.swift
        └── ServiceMenuView.swift       # секретное меню (тройной тап по версии)

DemarVPN.xcodeproj/                    # Xcode project

ios/                                   # фаза 2: VPN (из demar_vpn)
├── Shared/
│   ├── VpnAppGroup.swift
│   ├── VpnSharedStore.swift
│   ├── VpnTunnelController.swift
│   ├── VpnControlConstants.swift
│   └── xray/                          # geoip.dat, geosite.dat, bundled_version.txt
├── DemarPacketTunnel/
│   └── PacketTunnelProvider.swift
└── Frameworks/DemarXray.xcframework/  # Headers/plist в git; DemarXray binary — build script

macos/
└── xray/                              # xray (arm64), geo, bundled_version.txt (xray-download-auto.py)
```

## Связь с demar_vpn

Визуальный эталон: `demar_vpn/lib/presentation/`.  
Нативное VPN-ядро для фазы 2: `demar_vpn/ios/Shared/`, `DemarPacketTunnel/`.  
Assets Xray в этом репо: `python scripts/xray-download-auto.py` → `ios/Shared/xray/`, `macos/xray/`.  
XCFramework: `python ../demar_vpn/scripts/build_xray_ios_xcframework.py`.
