# Ядро VPN: Sing-box (VLESS) — Demar VPN (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 18+ / macOS 14+** (`demar_vpn_apple`).

Документация Sing-box:

- [VLESS outbound](https://sing-box.sagernet.org/configuration/outbound/vless/)
- [TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [TLS/Reality fields](https://sing-box.sagernet.org/configuration/shared/tls/)
- [CLI](https://sing-box.sagernet.org/command/)

---

## Идея

Sing-box используется как proxy-core. **Device-wide VPN** строится через **TUN inbound** в `config.json`; маршруты и utun создаёт **Network Extension** (`NEPacketTunnelProvider`), а extension запускает `sing-box run -c`.

---

## Профиль и config.json

Целевая версия core: **sing-box 1.13.x** (см. `macos/singbox_macos/bundled_version.txt`, Libbox из того же тега).

**VLESS URI → Sing-box config.json** — [`VlessUriParser`](DemarVPN/Core/Vpn/VlessUriParser.swift), [`SingBoxStreamSettings`](DemarVPN/Core/Vpn/SingBoxStreamSettings.swift), [`SingBoxConfigBuilder`](DemarVPN/Core/Vpn/SingBoxConfigBuilder.swift). Имя utun патчится extension’ом под фактический интерфейс NE.

Формат config.json соответствует sing-box **1.12+ / 1.13**:

| Legacy (≤1.11) | Текущий формат |
|----------------|----------------|
| `routing` | `route` |
| `inet4_address` | `address` |
| `inbound.sniff` | `route.rules` → `action: sniff` |
| `outbound: block` | `action: reject` |
| DNS `address: 1.1.1.1` | DNS `type: udp`, `server: 1.1.1.1` |
| `domain_strategy` на outbound | `domain_resolver: { server, strategy }` |
| — | `route.default_domain_resolver` (обязателен с 1.12) |

Проверка: `sing-box check -c config.json` (тесты `VlessUriParserTests`).

`VlessUriParser` всё ещё парсит расширенные query-поля вручную, но runtime-builder для Sing-box строго отклоняет Xray-only параметры (`xhttp`, `pqv`, `spx`, `extra`, `mode`, `x_padding_bytes`, `encryption != none`).

### Маппинг `vless://` query → Sing-box JSON

| Query | JSON |
|-------|------|
| `flow` | `outbounds[].flow` |
| `type` / `network` | `outbounds[].network` |
| `security=tls` | `outbounds[].tls.enabled=true` |
| `security=reality` + `pbk/sid` | `outbounds[].tls.reality.{public_key,short_id}` |
| `sni`, `host` | `outbounds[].tls.server_name` |
| `fp` | `outbounds[].tls.utls.fingerprint` |
| `path`, `host`, `ed` | `outbounds[].transport` (ws) |
| `path` | `outbounds[].transport.service_name` (grpc) |

Тесты: target `DemarVPNTests` → `VlessUriParserTests` (golden на [`TestServers.swift`](DemarVPN/Core/Models/TestServers.swift)).

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

Assets: `python3 scripts/singbox-download-auto.py` → `sing-box` из release + `geoip.db`/`geosite.db` из [sing-geoip](https://github.com/SagerNet/sing-geoip) и [sing-geosite](https://github.com/SagerNet/sing-geosite).

### macOS

| Компонент | Путь |
|-----------|------|
| Sing-box subprocess в extension | `macos/singbox_macos/` → Resources appex |
| Запуск core | `ios/DemarPacketTunnel/MacCoreProcess.swift` (`MacCoreProcess`) |

Connect: `NativeVpnService` → `VpnTunnelController` → extension → `sing-box run -c`.

---

## Чеклист интеграции

- [x] `DemarPacketTunnel` + `NativeVpnService`
- [x] VLESS → config (`VlessUriParser`, `SingBoxConfigBuilder`)
- [x] Geo в bundle iOS / macOS
- [x] `AppState` + `VpnStatusMonitor` (iOS + macOS)
- [x] macOS Network Extension + sing-box в extension

---

## Текущее состояние

**iOS:** SwiftUI + Network Extension + App Group + Sing-box config pipeline.  
**macOS:** SwiftUI + Network Extension + subprocess sing-box в extension (Apple Silicon).

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
