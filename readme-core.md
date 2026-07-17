# Ядро VPN: Sing-box (NaiveProxy + Hysteria2) — Demar VPN (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 18+ / macOS 14+** (`demar_vpn_apple`).

Целевая версия core: **latest sing-box release** (`scripts/libbox-build.py`, `scripts/singbox-download-auto.py`). Фактическая версия — в UI (`bundled_version.txt` в bundle).

Документация Sing-box:

- [Naive outbound](https://sing-box.sagernet.org/configuration/outbound/naive/)
- [Hysteria2 outbound](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)
- [TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [TLS outbound](https://sing-box.sagernet.org/configuration/shared/tls/)
- [UDP over TCP](https://sing-box.sagernet.org/configuration/shared/udp-over-tcp/)
- [Dial fields](https://sing-box.sagernet.org/configuration/shared/dial/)
- [DNS rule action](https://sing-box.sagernet.org/configuration/dns/rule_action/)
- [CLI](https://sing-box.sagernet.org/command/)

---

## Идея

Sing-box используется как proxy-core. **Device-wide VPN** строится через **TUN inbound** в `config.json`; маршруты и utun создаёт **Network Extension** (`NEPacketTunnelProvider`), extension запускает `sing-box run -c`.

Pipeline: `ServerProfile` → [`SingBoxConnectPlan`](DemarVPN/Core/Vpn/SingBoxConnectPlan.swift) → [`SingBoxConfigBuilder`](DemarVPN/Core/Vpn/SingBoxConfigBuilder.swift) → `config.json`. Extension мержит runtime-resolved uplink IPv4 в bypass rules перед стартом Libbox; TUN fd создаёт NE platform interface.

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

Проверка: `sing-box check -c config.json` (тесты `SingBoxConfigTests`).

---

## NaiveProxy: профиль и config.json

### App model — `NaiveProfile`

[`NaiveProfile`](DemarVPN/Core/Vpn/NaiveProfile.swift) — структурированный профиль (без URI-парсера). Тестовые значения: [`TestServers.swift`](DemarVPN/Core/Models/TestServers.swift).

| App field | sing-box key | Required |
|-----------|--------------|----------|
| `server` | `server` | yes |
| `port` | `server_port` | yes |
| `username` | `username` | no |
| `password` | `password` | no |
| `tlsServerName` | `tls.server_name` | yes (TLS обязателен для naive) |
| `displayName` | — | UI only |
| `city` | — | UI subtitle only |

### Hardcoded defaults (Demar builder)

Задаются в `SingBoxConnectPlan.naive(_:)`:

| sing-box key | Значение | Зачем |
|--------------|----------|-------|
| `type` | `"naive"` | |
| `tag` | `"proxy"` | route final |
| `tls.enabled` | `true` | naive требует TLS |
| `domain_resolver` | `{ server: "dns-direct", strategy: "ipv4_only" }` | sing-box 1.12+ |
| `udp_over_tcp` | `{ enabled: true, version: 2 }` | UDP через TCP |
| `quic` | `false` | HTTP/2, не QUIC |

### TUN / DNS / route overrides (Naive)

| Параметр | Значение | Эффект |
|----------|----------|--------|
| `dns.final` | `dns-remote` | DNS через proxy |
| `dns-remote` тип | `https` (DoH, `detour: proxy`) | одно мультиплексированное соединение через прокси вместо потока на каждый запрос (raw tcp/udp) — без лавины `stream failed: aborted` |
| `dns-direct` тип | `udp` 1.1.1.1 | bootstrap/SNI напрямую |
| PTR (reverse) запросы | `action: reject` (`drop`) | локальные `*.in-addr.arpa` / `_dns-sd._udp` отбрасываются: прямой резолвер недоступен внутри macOS NE и перегружал единственное соединение naive |
| `experimental.cache_file` | `enabled: true` | кэш DNS/rule-set переживает рестарты |
| route resolve | нет | данные не зависят от прямого DNS: домены идут в прокси, резолв на стороне сервера |
| QUIC (`udp` :443) | `action: reject` | apps падают на TCP — без утечек IPv6/UDP и без нагрузки на единственное соединение naive |
| DNS bootstrap | `[tlsServerName]` через `action: route` | SNI → direct DNS |
| `strict_route` | `true` | |
| direct domain | `[tlsServerName]` | SNI → direct outbound |
| `directIPs` | IPv4 literal `server` или runtime merge hostname → IPv4 | exclude/route bypass |

### sing-box: поля Naive (не экспонированы в app)

Из [upstream docs](https://sing-box.sagernet.org/configuration/outbound/naive/) — для будущего расширения:

| Field | Type | Description |
|-------|------|-------------|
| `extra_headers` | object | Доп. HTTP-заголовки |
| `udp_over_tcp.enabled` | bool | Включение UDP-over-TCP (сейчас hardcoded `true`) |
| `quic` | bool | QUIC вместо HTTP/2 (сейчас `false`) |
| `quic_congestion_control` | string | `bbr` (default), `bbr2`, `cubic`, `reno` |
| `tls.certificate` | string[] | Self-signed (не для production) |
| `tls.certificate_path` | string | Путь к сертификату |
| `tls.ech` | object | ECH |
| Dial fields | — | `detour`, `bind_interface`, `inet4_bind_address`, … см. [Dial Fields](https://sing-box.sagernet.org/configuration/shared/dial/) |

**Platform:** Naive outbound доступен на Apple platforms; iOS Libbox собирается с `with_naive_outbound` — см. [`ios/Frameworks/README.md`](ios/Frameworks/README.md).

### Hysteria2: профиль и outbound

[`Hysteria2Profile`](DemarVPN/Core/Vpn/Hysteria2Profile.swift) → `SingBoxConnectPlan.hysteria2(_:)`:

| App field | sing-box key |
|-----------|--------------|
| `server` | `server` |
| `port` | `server_port` |
| `password` | `password` |
| `tlsServerName` | `tls.server_name` |

Hardcoded: `type: hysteria2`, `tag: proxy`, `tls.enabled: true`, `tls.alpn: ["h3"]`, `domain_resolver` → `dns-direct`. TUN/DNS/route — те же overrides, что у Naive (DoH remote, SNI bootstrap, `strict_route`, reject app QUIC `:443` — uplink hy2 на другом порту не затрагивается). Libbox Apple уже с `with_quic`; отдельный build tag не нужен.

### Default interface monitor (NE, iOS + macOS)

Libbox закрывает **все** соединения, как только платформа сообщает пустой default interface (`updateDefaultInterface("", -1)`) — для naive это рвёт HTTP/2-туннель (каскад `stream failed: aborted`, `dial: operation was canceled`). Внутри NE `NWPathMonitor` кратковременно флапает в `.unsatisfied` (применение routes/DNS, Wi-Fi-скан, sleep/wake), поэтому сырые апдейты в ядро не передаются:

- `DefaultInterfaceReportFilter` (`ios/Shared/DefaultInterfaceReporter.swift`) — дедуп одинаковых апдейтов; потеря интерфейса репортится только если держится ≥3 c (debounce), восстановление отменяет потерю.
- `DefaultInterfaceResolver` — **sticky**: пока last-known uplink (`en0`/`pdp_ip*`/Ethernet) ещё в `availableInterfaces`, смена `usesInterfaceType` (Wi‑Fi↔LTE) **не** меняет репорт в libbox — иначе naive HTTP/2 рвётся на rebind. Новый iface берётся только когда sticky ушёл из candidates. Если path **satisfied**, но phys скрыт за TUN (типично iOS NE: в списке только `utun*`), репортится last-known uplink.
- На macOS NE transient `.unsatisfied` не считается потерей, пока `availableInterfaces` содержит физический интерфейс; `getInterfaces()` при `.unsatisfied` возвращает last-known snapshot.
- `TunnelLifecycle` (path monitor, sleep/wake, heartbeat) работает на обеих платформах; короткие `.unsatisfied` флапы при handoff не перезапускают core, софт-рестарт ядра — только после подтверждённой потери пути (`pathRecoveredAfterLoss`) или смены excluded-маршрутов, wake (каждая разблокировка) здоровый туннель не перезапускает.

---

## Добавление протокола

1. **Profile** — struct с полями сервера (или URI parser → struct).
2. **`SingBoxConnectPlan`** — factory `static func yourProtocol(_:)` с `proxyOutbound`, `directIPs`, `tun`.
3. **`ServerProfile.Kind`** — новый case + `connectPlan` switch.
4. **`TestServers`** — seed для dev.
5. **`SingBoxConfigTests`** — `sing-box check` на сгенерированный JSON.
6. **Libbox** — при необходимости обновить build tags в `scripts/libbox-build.py`.

Config builder, tunnel и NE менять не нужно — они protocol-agnostic.

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
- [x] NaiveProxy → config (`SingBoxConnectPlan`, `SingBoxConfigBuilder`)
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
