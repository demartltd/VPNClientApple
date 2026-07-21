# Ядро VPN: Sing-box (Hysteria2) — Demar VPN (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 18+ / macOS 14+** (`demar_vpn_apple`).

Целевая версия core: **sing-box 1.13.14**, зафиксированная в [`singbox-version.txt`](singbox-version.txt). Оба build-скрипта и `bundled_version.txt` обязаны использовать эту версию.

Документация Sing-box:

- [Hysteria2 outbound](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)
- [TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [TLS outbound](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Dial fields](https://sing-box.sagernet.org/configuration/shared/dial/)
- [DNS rule action](https://sing-box.sagernet.org/configuration/dns/rule_action/)
- [CLI](https://sing-box.sagernet.org/command/)

---

## Идея

Sing-box используется как proxy-core. **Device-wide VPN** строится через **TUN inbound** в `config.json`; маршруты и utun создаёт **Network Extension** (`NEPacketTunnelProvider`), extension запускает Libbox in-process.

Pipeline: `ServerProfile` → [`SingBoxConnectPlan`](DemarVPN/Core/Vpn/SingBoxConnectPlan.swift) → [`SingBoxConfigBuilder`](DemarVPN/Core/Vpn/SingBoxConfigBuilder.swift) → `config.json`. Extension мержит runtime-resolved uplink IPv4 в bypass rules перед стартом Libbox; TUN fd создаёт NE platform interface.

Формат config.json соответствует sing-box **1.12+ / 1.13**:

| Legacy (≤1.11) | Текущий формат |
|----------------|----------------|
| `routing` | `route` |
| `inet4_address` | `address` |
| `inbound.sniff` | `route.rules` → `action: sniff` |
| `outbound: block` | `action: reject` |
| DNS `address: local` | DNS `type: local` |
| `domain_strategy` на outbound | `domain_resolver: { server, strategy }` |
| — | `route.default_domain_resolver` (обязателен с 1.12) |

Проверка: `sing-box check -c config.json` (тесты `SingBoxConfigTests`).

---

## Hysteria2: профиль и config.json

### App model — `Hysteria2Profile`

[`Hysteria2Profile`](DemarVPN/Core/Vpn/Hysteria2Profile.swift) — структурированный профиль (без URI-парсера). Тестовые значения: [`TestServers.swift`](DemarVPN/Core/Models/TestServers.swift).

| App field | sing-box | Required |
|-----------|----------|----------|
| `server` | `server` | yes |
| `port` | `server_port` | yes |
| `password` | `password` | yes |
| `tlsServerName` | `tls.server_name` | yes |
| `displayName` / `city` | — | UI only |

### Outbound (`SingBoxConnectPlan.hysteria2`)

Один outbound + `direct`:

| Outbound | tag | Role |
|----------|-----|------|
| hysteria2 | `proxy` | route final / DoH detour; dial host/port; `tls` + `alpn: ["h3"]`; `domain_resolver` → `dns-direct` |
| direct | `direct` | bypass |

Pin endpoint / `mergeDirectIPs` целят **`proxy`**.

### TUN / DNS / route

| Параметр | Значение | Эффект |
|----------|----------|--------|
| `dns.final` | `dns-remote` | DNS через proxy |
| `dns-remote` | `https` DoH, `detour: proxy` | DNS через proxy |
| `dns-direct` | `local` | системный Darwin resolver |
| PTR | `action: reject` (`drop`) | отсев локальных reverse/DNS-SD floods в NE |
| `experimental.cache_file` | `enabled: true` | кэш DNS/rule-set |
| DNS bootstrap | `[tlsServerName, server]` → direct DNS | SNI + uplink host |
| `strict_route` | `false` (NE) | не конфликтует с excludedRoutes на iOS 26 |
| `stack` | `system` | Apple NE TUN |
| `directDomains` | `[tlsServerName, server]` | SNI / uplink → direct |
| `directIPs` | IPv4 literal или runtime merge | exclude/route bypass |

На Apple endpoint IP сначала исключается из `NEPacketTunnelNetworkSettings`, затем применяется новый config. Hysteria2 (UDP/QUIC) dial'ит uplink напрямую — без TCP hairpin/relay. Libbox Apple уже с `with_quic`.

Старт туннеля: deferred capture (routes пустые) → `waitForSatisfiedPath` → `activateTrafficCapture` → settle → `resumeDefaultInterfaceAfterCapture`. На iOS 26 pre-capture BSD `connect` к diagnostic mixed inbound даёт `EADDRNOTAVAIL`, поэтому старт **не** гейтится TCP data probe.

### Default interface monitor (NE, iOS + macOS)

Libbox закрывает **все** соединения при пустом default interface (`updateDefaultInterface("", -1)`). Внутри NE `NWPathMonitor` кратковременно флапает в `.unsatisfied`, поэтому сырые апдейты в ядро не передаются:

- `DefaultInterfaceReportFilter` — дедуп; потеря интерфейса только если держится ≥3 c.
- `DefaultInterfaceResolver` — **sticky**: пока last-known uplink ещё в candidates, Wi‑Fi↔LTE не rebind'ит libbox. Новый iface — когда sticky ушёл. Если path satisfied, но phys скрыт за TUN — last-known uplink.
- macOS: transient `.unsatisfied` не потеря, пока в `availableInterfaces` есть phys iface.
- `TunnelLifecycle`: soft-restart только после `pathRecoveredAfterLoss` или смены excluded-маршрутов; wake здоровый туннель не перезапускает.
- `includeAllNetworks` выключен; full tunnel — routes + `/32` exclusion endpoint.
- Endpoint резолвится до старта NE и пинится в dial-outbound; TLS SNI остаётся доменным.
- `dns-direct: local` — Darwin `getaddrinfo`.

---

## Общий стек (iOS + macOS)

| Компонент | Путь |
|-----------|------|
| Connect plan | `DemarVPN/Core/Vpn/SingBoxConnectPlan.swift` |
| Config builder | `DemarVPN/Core/Vpn/SingBoxConfigBuilder.swift` |
| App Group, пути | `ios/Shared/VpnAppGroup.swift` |
| Connect/disconnect | `ios/Shared/VpnTunnelController.swift` |
| UI VPN API | `DemarVPN/Core/Services/NativeVpnService.swift` |
| Статус NE | `DemarVPN/Core/Services/VpnStatusMonitor.swift` |
| Packet tunnel | `ios/DemarPacketTunnel/PacketTunnelProvider.swift` |

**App Group:** `group.com.demar.vpn`  
**Bundle tunnel:** `com.demar.vpn.packet-tunnel`  
**Журнал (dev):** `./scripts/journal.sh` — см. [`readme.md`](readme.md) § Журнал.

Assets: `python3 scripts/singbox-download-auto.py` → `sing-box` из release + `geoip.db`/`geosite.db` из [sing-geoip](https://github.com/SagerNet/sing-geoip) и [sing-geosite](https://github.com/SagerNet/sing-geosite).

### macOS

| Компонент | Путь |
|-----------|------|
| Libbox in-process | `ios/Frameworks/Libbox.xcframework` |
| Platform interface | `ios/DemarPacketTunnel/DemarLibboxPlatform.swift` |
| Запуск core | `ios/DemarPacketTunnel/IOSLibboxCore.swift` |

Connect: `NativeVpnService` → `VpnTunnelController` → extension → Libbox (тот же путь, что iOS).

---

## Чеклист интеграции

- [x] `DemarPacketTunnel` + `NativeVpnService`
- [x] Hysteria2 → config (`Hysteria2Profile`, `SingBoxConnectPlan.hysteria2`)
- [x] Geo в bundle iOS / macOS
- [x] `AppState` + `VpnStatusMonitor` (iOS + macOS)
- [x] macOS Network Extension + Libbox in-process

---

## Текущее состояние

**iOS:** SwiftUI + Network Extension + App Group + Sing-box config pipeline.  
**macOS:** SwiftUI + Network Extension + Libbox in-process (Apple Silicon).

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
