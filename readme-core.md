# Ядро VPN: Xray-core (VLESS) — Demar VPN (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 18+ / macOS 14+** (`demar_vpn_apple`).

Документация Xray (Project X):

- [VLESS outbound](https://xtls.github.io/en/config/outbounds/vless.html)
- [Command line](https://xtls.github.io/en/document/command.html)
- [Environment variables](https://xtls.github.io/en/config/features/env.html)
- [TUN inbound](https://raw.githubusercontent.com/XTLS/Xray-core/main/proxy/tun/README.md)

---

## Идея

Xray-core — proxy-core. **Device-wide VPN** через **TUN inbound**: трафик уходит в Xray, наружу — **VLESS** outbound. На **iOS и macOS** маршруты и utun задаёт **Network Extension** (`NEPacketTunnelProvider`); xray получает fd через `XRAY_TUN_FD`.

---

## Профиль и config.json

**VLESS URI → XrayConfig.json** — `VlessUriParser`, `XrayConfigBuilder` (TUN + REALITY). Имя utun в JSON патчится extension’ом под фактический интерфейс NE.

---

## Общий стек (iOS + macOS)

| Компонент | Путь |
|-----------|------|
| App Group, пути | `ios/Shared/VpnAppGroup.swift` |
| Connect/disconnect | `ios/Shared/VpnTunnelController.swift` |
| UI VPN API | `DemarVPN/Core/Services/NativeVpnService.swift` |
| Статус NE | `DemarVPN/Core/Services/VpnStatusMonitor.swift` |
| Packet tunnel | `ios/DemarPacketTunnel/PacketTunnelProvider.swift` |

**App Group:** `group.com.demar.vpn`  
**Bundle tunnel:** `com.demar.vpn.packet-tunnel`

Geo: `python3 scripts/xray-download-auto.py` → `ios/Shared/xray/`, `macos/xray_macos/`

### iOS

| Компонент | Путь |
|-----------|------|
| Xray (gomobile) | `ios/Frameworks/DemarXray.xcframework` |

Connect: App Group config → extension → `XRAY_TUN_FD` + `DemarxrayStart`.

Сборка xcframework: `python ../demar_vpn/scripts/build_xray_ios_xcframework.py`

### macOS

| Компонент | Путь |
|-----------|------|
| Xray subprocess в extension | `macos/xray_macos/` → Resources appex |
| Запуск xray | `ios/DemarPacketTunnel/MacXrayProcess.swift` |

Connect: `NativeVpnService` → `VpnTunnelController` → extension → `XRAY_TUN_FD` + `xray run` (без создания utun из app).

Бинарник `xray` также в main app bundle (geo для App Group при connect).

---

## Чеклист интеграции

- [x] `DemarPacketTunnel` + `NativeVpnService`
- [x] VLESS → config (`VlessUriParser`, `XrayConfigBuilder`)
- [x] Geo в bundle iOS / macOS
- [x] `AppState` + `VpnStatusMonitor` (iOS + macOS)
- [x] macOS Network Extension + xray в extension

---

## Текущее состояние

**iOS:** SwiftUI + Network Extension + App Group + DemarXray.  
**macOS:** SwiftUI + Network Extension + subprocess xray в extension (Apple Silicon).

См. [`readme.md`](readme.md).

---

## macOS/App Store preflight (обязательно)

Для предсказуемого старта `NEPacketTunnelProvider` на macOS:

- Оба App ID (`com.demar.vpn`, `com.demar.vpn.packet-tunnel`) имеют `App Groups` и `Network Extensions (Packet Tunnel Provider)`.
- В обоих используется один `App Group`: `group.com.demar.vpn`.
- Provisioning profiles после изменений capabilities обновлены и применены.
- Хост `.app` и `DemarPacketTunnel.appex` подписаны одной Team ID.
- Пользователь один раз включил расширение в `System Settings → Login Items & Extensions → Network Extensions`.

Для App Store-ветки не используем root/helper-модель повышения привилегий; Packet Tunnel работает в рамках entitlement-модели Network Extension.
