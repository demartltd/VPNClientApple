# Ядро VPN: Xray-core (VLESS) — Demar VPN (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 17+ / macOS 14+** (`demar_vpn_apple`).

Документация Xray (Project X):
- [VLESS outbound](https://xtls.github.io/en/config/outbounds/vless.html)
- [Command line](https://xtls.github.io/en/document/command.html)
- [Environment variables](https://xtls.github.io/en/config/features/env.html)
- [TUN inbound](https://raw.githubusercontent.com/XTLS/Xray-core/main/proxy/tun/README.md)

---

## Идея

Xray-core — proxy-core. **Device-wide VPN** через **TUN inbound**: ОС создаёт TUN, трафик уходит в Xray, наружу — **VLESS** outbound. Маршрутизация и исключение петель — на стороне ОС (Network Extension).

---

## Профиль и config.json

**RemoteProfile → XrayConfig.json**

Минимум для VLESS outbound: `address`, `port`, `id`, `encryption` (`"none"`), опционально `flow`, REALITY (`sni`, `fp`, `pbk`, `sid`).

На **фазе 1** (SwiftUI UI) генерация конфига не реализована — моки в `MockVpnService`.

На **фазе 2** портировать из Dart:
- `demar_vpn/lib/data/vpn/vless_uri_parser.dart`
- `demar_vpn/lib/data/vpn/xray_config_builder.dart`

---

## iOS VPN (фаза 2 — готовый код в `demar_vpn/ios/`)

Рабочая реализация уже в соседнем репозитории:

| Компонент | Путь |
|-----------|------|
| App Group, пути | `demar_vpn/ios/Shared/VpnAppGroup.swift` |
| Connect/disconnect | `demar_vpn/ios/Shared/VpnTunnelController.swift` |
| Состояние, логи | `demar_vpn/ios/Shared/VpnSharedStore.swift` |
| Packet tunnel | `demar_vpn/ios/DemarPacketTunnel/PacketTunnelProvider.swift` |
| Xray (gomobile) | `demar_vpn/ios/Frameworks/DemarXray.xcframework` |
| Control Center | `demar_vpn/ios/DemarControls/` (iOS 18+) |

**App Group:** `group.com.demar.vpn`  
**Bundle tunnel:** `com.demar.vpn.packet-tunnel`

Сборка xcframework: `python ../demar_vpn/scripts/build_xray_ios_xcframework.py`  
Geo assets (iOS): `python scripts/xray-download-auto.py` → `ios/Shared/xray/`  
macOS arm64 binary + geo: тот же скрипт → `macos/xray/` (будущий subprocess VPN на Apple Silicon)

Порядок connect (как во Flutter bridge):
1. Записать `config.json` и assets в App Group
2. `NETunnelProviderManager` → extension
3. `XRAY_TUN_FD` + `DemarxrayStart` / `DemarxrayStop`

Подпись: Apple Developer, capabilities **Network Extension** + **App Groups**.

---

## Чеклист интеграции (фаза 2)

- [x] Targets extensions в `DemarVPN.xcodeproj` (`DemarPacketTunnel`)
- [x] `IosVpnService` → `VpnTunnelController.shared`
- [x] Swift: VLESS URI → `config.json` (`VlessUriParser`, `XrayConfigBuilder`)
- [x] `geoip.dat` / `geosite.dat` в bundle (`ios/Shared/xray/`)
- [x] `AppState` + `VpnStatusMonitor` (`NEVPNStatus` на iOS; macOS — мок)

---

## Текущее состояние (demar_vpn_apple)

**iOS:** SwiftUI + `DemarPacketTunnel` + `DemarXray.xcframework` + App Group (`group.com.demar.vpn`).  
**macOS:** SwiftUI + мок VPN (`MockVpnControlling`).  
См. [`readme.md`](readme.md).
