**Demar Proxy (Apple)** — нативный VPN-клиент на SwiftUI: управление профилями подключения, установка защищённого туннеля и контроль состояния соединения. Ядро — **latest sing-box** / Libbox (Hysteria2 / Trojan / VLESS Reality / **OpenFlux** host `liboflux` → local SOCKS + Libbox outbound).

Поддерживаются **iOS 18+** и **macOS 15+** (нативное приложение, один target).

Все доступные сервера и их конфиги получаются удалённо после входа (`POST /vpn/servers`). Вкладка **Servers**: единый список с бейджами tier/protocol, toolbar Refresh/Filters, favorites, ping (TCP/TLS/QUIC), details sheet, locked → Premium. Без сессии вкладки **Сервера** и **Аккаунт** открывают login bottom sheet.

## Сборка

- **Xcode 15+**
- Deployment: **iOS 18+**, **macOS 15+** (VPN на Mac — **Apple Silicon arm64**)
- Display name: **Demar Proxy**
- Bundle ID: `com.demar.adblock` · SKU: `demar-adblock`
- Extensions: `com.demar.adblock.packet-tunnel`, `com.demar.adblock.controls`
- App Group: `group.com.demar.adblock`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + App Group + sing-box **1.14.1**
- **macOS:** Network Extension + Libbox in-process (как iOS)
- См. [`readme-core.md`](readme-core.md)

Перед сборкой локально нужны geo assets (`geoip.db` / `geosite.db`), `Libbox.xcframework`, OpenFlux `liboflux` и rule-sets — они не в git (см. [`readme-core.md`](readme-core.md)).

Xcode копирует geo assets в host app и в `DemarPacketTunnel.appex` (iOS: `singbox/`, macOS: `singbox_macos/`). Dev binary `sing-box` в runtime bundle не включается. Entitlements: `DemarVPN.entitlements`, `ios/DemarPacketTunnel/…`, `ios/DemarControls/…` (App Group + Packet Tunnel).

```bash
# macOS Debug
xcodebuild -scheme DemarVPN -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -scheme DemarVPN -destination 'platform=iOS Simulator,name=iPhone 17' build
```

В Xcode: destination **My Mac** или симулятор iPhone. На Mac после установки включите расширение в `System Settings → Login Items & Extensions → Network Extensions`.

Документация Sing-box: https://sing-box.sagernet.org/

Структура кода: [`filestree.md`](filestree.md).

### Журнал

UI («Настройки → Настройки приложения») — журнал до 512 строк.  
**macOS / Simulator:** App Group `demar_vpn/vpn_journal.log`.  
**Physical iOS:** host зеркалит в `Documents/demar/demar_app.log` (CoreDevice не отдаёт App Group `demar_vpn/`); pull через `devicectl` `appDataContainer`.

Runtime `core.log`: `log.level=info`, timestamp, ring ~20k строк. На device открой app (чтобы зеркало обновилось) или connect VPN. Fallback: Share в UI.

## Навигация

Четыре раздела: **Подключение**, **Сервера**, **Настройки**, **Аккаунт**. **iOS** — `TabView`: три основные вкладки + **Аккаунт** отдельно справа (`TabRole.prominent` на iOS 27+, `.search` на 18…26; icon-only с iOS 26). **macOS** — боковая панель слева (`NavigationSplitView`), аккаунт внизу sidebar.

### Подключение

Вкл/выкл VPN, статус, имя сервера, скорость RX/TX при подключении (Clash API `GET /traffic` в extension → App Group; Home читает ↓/↑ KB/s). **iOS:** control «Demar Proxy» в Control Center; UI синхронизируется с `NEVPNConnection` при любом переключении Demar (приложение, control, Настройки → VPN, системная кнопка VPN в CC).

### Сервера

Список профилей с API по подписке (после входа). SegmentBar: протоколы из ответа API (HY2 / Trojan / VLESS) + All/Free/Plus/Vip (+ Dev/Tester если есть). Pull-to-refresh обновляет список. Гость — CTA «Войти».

### Настройки

Ссылки, действия, переход в настройки приложения (Change language + журнал). **Языки:** `en` (default) / `ru` / `uk` / `tr` / `uz` / `zh-Hans` / `zh-Hant` / `ko` / `ja` / `es` / `de` / `fr` / `hi` (`Localizable.strings` + `InfoPlist.xcstrings`); смена — системный per-app language или **Настройки приложения → Change language**. **Feedback / Support** — тикеты support API (list / chat / draft, альбом до 10 фото WebP, polling 8с, unread badge); гость → login sheet; channel `ios`/`macos`, `sourceId=2`; silent diagnostics (device + journal) при создании тикета. **Документы** — меню ToS/PP: **iOS** system bottom sheet, **macOS** overlay (dismiss по клику вне); тексты всегда загружаются с raw GitHub Markdown (`demartltd/tos-pp`) и показываются через MarkdownUI. **iOS push-detail:** title после скролла, bar без blur, лёгкий top-градиент. **macOS** — обычный `navigationTitle`. **Служебное меню** — тройной тап по версии внизу экрана: сводка приложения и идентификаторы устройства (IDFV/IDFA или macOS UUID); секция **Info sheets** (как Android): Expiry / FreeTraffic / Traffic / PayResult ok|fail — только UI, без API. Traffic sheet глобальный (без смены вкладки). **Авто-alerts:** при `scenePhase == .active` (как update alert); paid — Expiry в окнах 72–24h и ≤18h (cooldown 3h); free — FreeTraffic при ≥200 MiB (cooldown 6h). **iOS IDFA:** системный запрос ATT при первом запуске (когда статус ещё не определён); в служебном меню кнопка **«Включить IDFA»** — повторный ATT или переход в настройки приложения, если отслеживание уже запрещено.

### Аккаунт

Email OTP (+ optional TOTP) и Telegram OAuth → auth API (только вход/сессия). Сессия: `userId`+`loginAt` в UserDefaults; при старте — `session/check`. План, срок, уведомления и трафик за месяц — VPN API (`POST /vpn/account`, `/vpn/notify`, `/vpn/traffic`). **Гость:** вход через bottom sheet. **Вошёл (как Android):** avatar + username + tap ID (clipboard); карточка подписки (Plan/Expires + Buy/Renew → единый checkout bottom sheet через `/vpn/pay/*`); ряд трафика с preview `used/limit · %` и progress → **Traffic sheet** (pie); лимит на connect → FreeTraffic alert (free) или Traffic (paid); **Increase limits** → тот же checkout; family stub → «Скоро»; Notifications → **Notify sheet** (2 toggle); Expiry / FreeTraffic upsell sheets (`SubscriptionAlertStore`); Sign out → confirm → logout API + stop VPN + clear servers. **Checkout:** Plus/VIP × week/month/quarter/year × RUB/EUR, промокод скидки через alert (`/vpn/promo/apply`), оплата RollyPay в Safari, возврат `demarvpn://pay/ok|fail` → PayResultSheet (иконка + Хорошо) + `refreshSessionData()` на ok (без polling `/vpn/pay/status`). Deeplink: `demarvpn://account/buy|plans|traffic` (+ legacy `settings/traffic`); pay `demarvpn://pay/ok|fail`. **Compare plans** — отдельный bottom sheet с таблицей тарифов. **Revoked / logout:** stop tunnel, wipe App Group `config.json` + connect payload, `removeFromPreferences` — Control Center / Settings VPN не подключат без авторизации. Callback: `demarvpn://auth/callback`. **App Review:** email `test@test.com` — локальный вход без OTP; `POST /vpn/servers` как обычно (free без паролей); connect блокируется snackbar.

