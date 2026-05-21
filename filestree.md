# Demar VPN (Apple) — структура проекта

По мере появления файлов синхронизируй дерево с фактическим кодом.

```
DemarVPN/                              # SwiftUI app target
├── DemarVPNApp.swift                  # @main, AppState, тема
├── ContentView.swift                  # TabView; iOS: ATT при scenePhase == .active
├── Info.plist                         # iOS (+ NSUserTrackingUsageDescription для ATT)
├── Info-macOS.plist                   # macOS
├── DemarVPN.entitlements              # App Group (iOS)
├── Assets.xcassets/
│
├── Core/
│   ├── Theme/
│   │   ├── DemarTheme.swift
│   │   └── AppTheme.swift
│   ├── Icons/
│   │   └── FontAwesomeBrands.swift
│   ├── Models/
│   │   ├── VpnConnectionState.swift
│   │   ├── ServerProfile.swift
│   │   └── TestServers.swift
│   ├── Network/
│   │   ├── DeviceTrafficTotals.swift      # iOS: getifaddrs RX/TX (скорость на главной)
│   │   └── PublicEgressDiagnostics.swift   # служебное меню: IP/страна, TCP+HTTPS зонды (независимо)
│   ├── Vpn/
│   │   ├── VlessRealityProfile.swift
│   │   ├── VlessUriParser.swift
│   │   └── XrayConfigBuilder.swift    # TUN + preflight SOCKS test JSON
│   ├── Services/
│   │   ├── AppState.swift
│   │   ├── VpnControlling.swift
│   │   ├── NativeVpnService.swift     # iOS + macOS: NETunnelProvider
│   │   ├── VpnStatusMonitor.swift     # iOS + macOS: NEVPNStatus
│   │   ├── AppLog.swift               # журнал UI; фильтр Xray access + маскировка IP (`***.***.o3.o4`)
│   │   ├── DeviceIdentity.swift
│   │   └── IDFATracking.swift
│   └── Utilities/
│       ├── ThroughputFormatter.swift
│       ├── PlatformServices.swift
│       ├── MacVpnDiag.swift             # macOS: pluginkit, codesign, NE preflight
│       ├── AppPlatform.swift
│       ├── BundledXrayVersion.swift
│       └── DemarNavigation.swift
│
├── Components/
│   └── …
├── Resources/Fonts/
│   └── fa-brands-400.ttf
│
└── Features/
    ├── Home/HomeView.swift
    ├── Servers/ServersView.swift
    └── Settings/…

DemarVPN.xcodeproj/

scripts/
├── xray-download-auto.py              # ios/Shared/xray geo + macos/xray binary
├── build-macos.ps1                    # macOS Release: build, sign, install, notarize
├── increment_version_auto.ps1         # patch + build во всех местах версии
└── increment_version.ps1              # интерактивно задать X.Y.Z (+ build +1)

ios/
├── Shared/ … + xray/
├── DemarPacketTunnel/
│   ├── PacketTunnelProvider.swift
│   ├── TunnelLifecycle.swift          # iOS: NWPathMonitor + wake recovery
│   └── MacXrayProcess.swift           # macOS: xray subprocess + XRAY_TUN_FD
└── Frameworks/DemarXray.xcframework/

macos/
└── xray_macos/                        # xray arm64, geo (gitignored binaries)
    └── README.md
```

## Связь с demar_vpn

Визуальный эталон: `demar_vpn/lib/presentation/`.  
Нативное VPN-ядро iOS: `demar_vpn/ios/`.  
Assets: `python3 scripts/xray-download-auto.py` → `ios/Shared/xray/`, `macos/xray_macos/`.  
XCFramework: `python ../demar_vpn/scripts/build_xray_ios_xcframework.py`.
