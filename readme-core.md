# Ядро VPN: Sing-box (Hysteria2) — Demar Proxy (Apple)

Сокращённая версия [`demar_vpn/readme-core.md`](../demar_vpn/readme-core.md) для нативного клиента **iOS 18+ / macOS 15+** (`demar_vpn_apple`).

Целевая версия core: **sing-box 1.14.1**, зафиксированная в [`singbox-version.txt`](singbox-version.txt). Оба build-скрипта и `bundled_version.txt` обязаны использовать эту версию.

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

Формат config.json соответствует sing-box **1.12+ / 1.14** (legacy DNS `address:` удалён в 1.14):

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
| `upMbps` / `downMbps` | `up_mbps` / `down_mbps` | no (empty → BBR; set values floored to ≥10) |
| `displayName` / `city` | — | UI only |

### Outbound (`SingBoxConnectPlan.hysteria2`)

Один outbound + `direct`:

| Outbound | tag | Role |
|----------|-----|------|
| hysteria2 | `proxy` | route final / DoH detour; dial host/port; `tls` + `alpn: ["h3"]`; `domain_resolver` → `dns-direct` |
| direct | `direct` | bypass |

Pin endpoint / `mergeDirectIPs` целят **`proxy`**.

### API geo-bypass (из `clientConfigJson`)

Servermaster кладёт remote `route.rule_set` (RU/IR/CN) в `clientConfigJson`. Клиент парсит tags/URLs в `ApiBypassRuleSet`.

**Apple dataplane** (не копия Android JSON — нет `VpnService.protect`):

| Источник | Применение |
|----------|------------|
| `geoip-*` | bundled `geoip-*.cidrs.json` → NE `excludedRoutes` (`TunBypassCidrs` в `openTun`) |
| `geosite-*` | remote `route.rule_set` + DNS → `dns-direct` (UDP `1.1.1.1`) |
| API `route_exclude_address_set` | **игнор** (no-op под Libbox `platformInterface`) |
| geo*/geosite → `outbound:direct` | **не эмитим** (`ENETUNREACH` внутри TUN) |

`dns-direct` остаётся `type: local`, пока нет geosite bypass; при geosite — UDP `1.1.1.1` + `route_exclude_address` `1.1.1.1/32`. Sidecars: `scripts/gen-tun-bypass-cidrs.py` — **не** raw dump: coarsen ≤`/20` + lossless aggregate (~9.8k combined vs ~16k raw). Floor `/20` (не `/16`): слепой `/16` invent’ил покрытие дырявых блоков и уводил чужие платформы (в т.ч. Telegram DC) в NE `excludedRoutes` мимо TUN.

### Site-группы TUN (`GET /tun`)

Каталог `sites[]` с API (массив `windows[]` на Apple игнорируется). Disk cache в `SessionCacheStore` рядом с servers (hydrate при старте, UI disk-first). Включённая группа → `domain_suffix` в DNS → `dns-direct`; A-записи резолвятся на Connect (apex + `www.`) и кладутся в TUN `route_exclude_address` → NE `excludedRoutes` (как geoip). **Не** эмитим `route` → `outbound:direct` для site-hosts — внутри full tunnel на Apple NE это даёт `ENETUNREACH` на en0. Новые CDN IP вне exclude-списка идут в `proxy` и всё равно грузятся. `dns.reverse_mapping=true` оставлен. `route.final` = `proxy`. Free: все группы принудительно on; Plus/VIP — overrides + мастер-тоггл. Применение на следующем Connect.

**Нельзя:** из‑за site-hosts переключать `dns-direct` на UDP `1.1.1.1` или добавлять `route_exclude` `1.1.1.1/32` — это **только** для geosite. Site-hosts идут в уже существующий `dns-direct` (`local` без geosite).

### TUN / DNS / route

| Параметр | Значение | Эффект |
|----------|----------|--------|
| `dns.final` | `dns-remote` | DNS через proxy |
| `dns-remote` | `https` DoH, `detour: proxy` | DNS через proxy |
| `dns-direct` | `local` / UDP `1.1.1.1` | без bypass — Darwin; с geosite — вне TUN |
| PTR | `action: reject` (`drop`) | отсев локальных reverse/DNS-SD floods в NE |
| `experimental.cache_file` | `enabled` + `store_dns` | rule-set + persist DNS (1.14) |
| DNS bootstrap | `[tlsServerName, server]` → direct DNS | SNI + uplink host |
| `strict_route` | `false` (NE) | не конфликтует с excludedRoutes на iOS 26 |
| `stack` | `gvisor` | как первый Hysteria2 (`9f0c3cc`) |
| `dns.optimistic` | `true` | stale-while-revalidate (1.14) |
| UDP NAT | `udp_mapping`/`udp_filtering` = `endpoint_independent`, `udp_nat_max` 4096 | 1.14 fields; `endpoint_independent_nat` no-op |
| `address` | IPv4 `/30` only | IPv4-only TUN |
| `route_address` | v4 `/1` + `/1` | полный IPv4 tunnel |
| AAAA DNS | нет отдельного reject | `strategy: ipv4_only` |
| IPv6 route | late `reject` | как `9f0c3cc` (v6 не в TUN) |
| UDP/443 | `reject` + `method: default` | форс TCP: QUIC-in-QUIC над H2 вешает App Store; bare reject = blackhole |
| Hysteria2 `udp_fragment` | `true` | QUIC/MTU на Apple NE |
| TUN `mtu` | `4064` | Apple utun default; low 1400 cap starved bulk TCP |
| `directDomains` | `[tlsServerName, server]` | SNI / uplink → direct |
| `directIPs` | IPv4 literal или runtime merge | exclude/route bypass |

На Apple endpoint IP сначала исключается из `NEPacketTunnelNetworkSettings`, затем применяется новый config. Hysteria2 (UDP/QUIC) dial'ит uplink напрямую — без TCP hairpin/relay. Libbox Apple уже с `with_quic`.

Старт туннеля: deferred capture (routes пустые) → короткий path wait → `activateTrafficCapture` → `resumeDefaultInterfaceAfterCapture`. После full routes NE path часто остаётся `.unsatisfied` при живом `en0` — **не** ждать satisfied (раньше это давало ~15 с на каждый connect). На iOS 26 pre-capture BSD `connect` к diagnostic mixed inbound даёт `EADDRNOTAVAIL`, поэтому старт **не** гейтится TCP data probe.

### Default interface monitor (NE, iOS + macOS)

Libbox закрывает **все** соединения при пустом default interface (`updateDefaultInterface("", -1)`). Hysteria2 uplink (QUIC/UDP) и long-lived TCP (в т.ч. Telegram MTProto на DC IP literals) умирают с `broken pipe` / `no recent network activity`. Поэтому:

- `activateTrafficCapture` **не** шлёт `.lost` — только hold reports, пока path flapping после full routes.
- После capture **не** `reportFilter.reset()`; `resumeDefaultInterfaceAfterCapture` разрешает first-report при `.unsatisfied` (steady state на iOS после full routes) — live `en0` всегда уходит в libbox, `.lost` — нет.
- Потеря iface **никогда** не форвардится в libbox, пока туннель жив (иначе Hysteria2 + Telegram MTProto → `broken pipe`).
- `DefaultInterfaceReportFilter` — дедуп; pending loss abort'ится.
- `DefaultInterfaceResolver` — **sticky**: пока last-known uplink ещё в candidates, Wi‑Fi↔LTE не rebind'ит libbox. Новый iface — когда sticky ушёл. Если path satisfied, но phys скрыт за TUN — last-known uplink.
- macOS: transient `.unsatisfied` не потеря, пока в `availableInterfaces` есть phys iface.
- `TunnelLifecycle`: soft-restart только после реального empty-phys outage → `pathRecoveredAfterLoss` (≥3s) или смены excluded-маршрутов; `.unsatisfied` при живом `en0` **не** arm'ит recovery (иначе reload убивает MTProto). Wake здоровый туннель не перезапускает.
- `includeAllNetworks` выключен; IPv4-only TUN (`ipv6=off`) — как первый Hysteria2 `9f0c3cc`.
- Endpoint резолвится до старта NE и пинится в dial-outbound; TLS SNI остаётся доменным; `udp_fragment: true` на Hysteria2.
- `dns-direct: local` — Darwin `getaddrinfo` (ipv4_only). PTR → drop; IPv6 / UDP/443 → reject `method: default` (ICMP/RST → App Store TCP fallback).
- Core log: `log.level=info` + timestamp; `./scripts/journal.sh -p ios --core --tg`.

Проверка (только iOS): `./scripts/journal.sh -p ios | rg 'ipv6=off'`; App Store без `outbound packet …:443` на apple CDN (только TCP); Telegram ок.

### Postmortem: Telegram iOS infinite refresh (2026-07-21)

Сайт `telegram.org` через VPN работал, приложение — бесконечное обновление. Hysteria2 outbound (server/password/tls/`alpn: h3`) **не** был причиной: он почти не менялся с первого H2 (`9f0c3cc`).

**Симптом в логах (только iOS):** при живом web через `outbound/hysteria2` — **ноль** dials на DC `149.154.*` / `91.108.*` / `2001:b28:*` в `core.log`. Telegram не доходил до IPv4 MTProto через TUN.

**Корневая причина:** Telegram iOS предпочитает **hardcoded DC IPv6**. Web идёт hostname → A → TCP/443 через proxy. Любая поломка IPv6-пути (blackhole / кривой RST / asymmetric NE routes) вешает приложение, пока IPv4 DC даже не пробуется — в core.log тишина по Telegram при работающих сайтах.

| Эксперимент | Результат |
|-------------|-----------|
| ULA + `::/1` + IPv6 **RST** before sniff + AAAA `reject method drop` | Hang. Silent DNS drop → retry ~1s; RST/HE на Apple NE/gvisor не спасал |
| IPv4-only TUN + AAAA REFUSED (`ipv6=off`) | Hang остался — v6 DC на physical (цензура/blackhole), IPv4 DC не dial'ились |
| Dual-stack + **proxy** IPv6 + снятие UDP/443 reject | Hang; DC в логах всё ещё не было |
| `includeAllNetworks=true` + `stack: system` | **Connect fail**: `system`/`mixed` запрещены с includeAll ([sing-tun#25](https://github.com/SagerNet/sing-tun/issues/25)) |
| Откат TUN/route к первому H2 `9f0c3cc` | **Telegram работает** |

**Рабочая формула (зафиксирована):**

- IPv4-only TUN: `172.19.0.1/30`, `route_address` v4 `/1`, `stack: gvisor`, `ipv6=off` в NE
- `includeAllNetworks=false`, `enforceRoutes=false`
- Route: sniff → hijack-dns → UDP/443 reject **`method: default`** → private/direct → reject IPv6 `method: default` → proxy
- DNS: `strategy: ipv4_only`, PTR drop; **без** AAAA drop/REFUSED-экспериментов
- H2: `udp_fragment: true`, pin endpoint; протокол не трогать ради Telegram

**Не повторять:** тянуть IPv6 в TUN «чтобы RST → Happy Eyeballs»; AAAA `method: drop`; `includeAllNetworks` без обязательного `gvisor`; bare UDP/443 `reject` без `method: default` (blackhole → App Store hang); пускать QUIC в H2 (QUIC-in-QUIC → App Store hang); считать багом поля Hysteria2 outbound.

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

Clash API `127.0.0.1:19090` (`experimental.clash_api`) — Home throughput via extension stream `GET /traffic` → App Group (host не видит localhost Packet Tunnel). На macOS App Sandbox bind этих listener'ов (Clash + diagnostic mixed) требует `com.apple.security.network.server` **только** в `DemarPacketTunnel.entitlements`; host остаётся client-only.

**App Group:** `group.com.demar.adblock`  
**Bundle tunnel:** `com.demar.adblock.packet-tunnel`  
**Журнал (dev):** `./scripts/journal.sh` — см. [`readme.md`](readme.md) § Журнал.

Assets: `python3 scripts/singbox-download-auto.py` → `sing-box` из release + `geoip.db`/`geosite.db` из [sing-geoip](https://github.com/SagerNet/sing-geoip) и [sing-geosite](https://github.com/SagerNet/sing-geosite).

### macOS

| Компонент | Путь |
|-----------|------|
| Libbox in-process | `ios/Frameworks/Libbox.xcframework` |
| Platform interface | `ios/DemarPacketTunnel/DemarLibboxPlatform.swift` |
| Запуск core | `ios/DemarPacketTunnel/IOSLibboxCore.swift` |

Libbox: stock Apple `build_libbox` tags минус `with_naive_outbound` (см. `scripts/libbox-build.py`).

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

- Оба App ID (`com.demar.adblock`, `com.demar.adblock.packet-tunnel`) имеют `App Groups` и `Network Extensions (Packet Tunnel Provider)`.
- В обоих используется один `App Group`: `group.com.demar.adblock`.
- Provisioning profiles после изменений capabilities обновлены и применены.
- Хост `.app` и `DemarPacketTunnel.appex` подписаны одной Team ID.
- Пользователь один раз включил расширение в `System Settings → Login Items & Extensions → Network Extensions`.

Для App Store-ветки не используем root/helper-модель повышения привилегий; Packet Tunnel работает в рамках entitlement-модели Network Extension.

### TestFlight / Mac: native vs iOS-on-Mac

При общем Bundle ID multiplatform-таргет по умолчанию отдаёт iOS-билд на Apple Silicon Mac (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`). External TestFlight тогда ставит iOS-on-Mac, internal видит native macOS. В проекте флаг выключен; `upload-testflight.ps1` после upload (или `-AscConfigureOnly`) через ASC API линкует macOS-билд и гасит `iosBuildsAvailableForAppleSiliconMac` (нужен API key App Manager/Admin; иначе — вручную в ASC). Разово: Pricing → *Don't Make Available*; имя листинга — App Information. Подробнее: [`readme.md`](readme.md) § TestFlight.
