**Demar VPN (Apple)** — нативный VPN-клиент на SwiftUI: управление профилями подключения, установка защищённого туннеля и контроль состояния соединения. Ядро — **latest sing-box** (Hysteria2 через Libbox).

Поддерживаются **iOS 18+** и **macOS 14+** (нативное приложение, один target).

Все доступные сервера и их конфиги получаются удалённо после входа (`POST https://vpn.example.invalid/vpn/servers`). Без сессии вкладки **Сервера** и **Аккаунт** открывают login bottom sheet.

## Сборка

- **Xcode 15+**
- Deployment: **iOS 18+**, **macOS 14+** (VPN на Mac — **Apple Silicon arm64**)
- Bundle ID: `com.demar.vpn`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + App Group + sing-box **1.13.14**
- **macOS:** Network Extension + Libbox in-process (как iOS)
- См. [`readme-core.md`](readme-core.md)

Один раз перед сборкой (скрипт только для разработчиков, в runtime не вызывается):

```bash
python3 scripts/singbox-download-auto.py   # pinned by singbox-version.txt
python3 scripts/libbox-build.py           # same pinned core → Libbox.xcframework
```

Xcode копирует geo assets в host app и в `DemarPacketTunnel.appex` (iOS: `singbox/`, macOS: `singbox_macos/`). Dev binary `sing-box` в runtime bundle не включается.

В [Apple Developer](https://developer.apple.com/account) для App ID `com.demar.vpn`, `com.demar.vpn.packet-tunnel` и **`com.demar.vpn.controls`** (Control Center) включите: **App Groups** (`group.com.demar.vpn`), **Network Extensions** → Packet Tunnel. Entitlements уже в `DemarVPN.entitlements`, `ios/DemarPacketTunnel/DemarPacketTunnel.entitlements` и `ios/DemarControls/DemarControls.entitlements`.

### Definition of Done: capabilities/provisioning

Перед запуском VPN на macOS проверьте, что выполнены все пункты:

- Для `com.demar.vpn` включены `App Groups` и `Network Extensions (Packet Tunnel Provider)`.
- Для `com.demar.vpn.packet-tunnel` включены `App Groups` и `Network Extensions (Packet Tunnel Provider)`.
- В обоих App ID присутствует одинаковая группа `group.com.demar.vpn`.
- После изменения capabilities пересозданы provisioning profiles и подтянуты в Xcode.
- Хост и `DemarPacketTunnel.appex` подписаны одной Team (`codesign: app=... appex=... match=yes`).
- Локально установлен один активный bundle (не смешивать старые копии из `DerivedData` и `/Applications`).

Для macOS/App Store не используем root/helper-эскалацию привилегий: для Packet Tunnel корректный путь только через Network Extension entitlement + системное разрешение пользователя.

```bash
# macOS Debug (Xcode, только для отладки)
xcodebuild -scheme DemarVPN -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -scheme DemarVPN -destination 'platform=iOS Simulator,name=iPhone 17' build
```

В Xcode: выберите destination **My Mac** или симулятор iPhone.

Для App Store / TestFlight используйте:

```powershell
pwsh ./scripts/upload-testflight.ps1 -Platform macOS
```

Для проверки Packet Tunnel на macOS запускайте приложение через Xcode (**My Mac**) или установленную App Store/TestFlight сборку, затем включите `Demar VPN` в `System Settings → Login Items & Extensions → Network Extensions`.

Документация Sing-box: https://sing-box.sagernet.org/

Структура кода: [`filestree.md`](filestree.md) — обновляй при изменениях в проекте.

### Журнал

UI («Настройки → Настройки приложения») и CLI — один журнал (до 512 строк).  
**macOS / Simulator:** App Group `demar_vpn/vpn_journal.log`.  
**Physical iOS:** host зеркалит в `Documents/demar/demar_app.log` (CoreDevice не отдаёт App Group `demar_vpn/`); скрипт тянет через `devicectl` `appDataContainer`.

```bash
./scripts/journal.sh                 # auto: macos → sim → device
./scripts/journal.sh -o journal.txt  # сохранить в файл
./scripts/journal.sh --core          # core.log (info: каждое dial destination→outbound)
./scripts/journal.sh --core --tg     # только Telegram DC / домены
./scripts/journal.sh -p ios             # физическое устройство
./scripts/journal.sh -p ios --core --tg # Telegram DC / domains in core.log
./scripts/journal.sh -d "iPhone Rem"    # имя / UDID для devicectl
```

Runtime `core.log`: `log.level=info`, timestamp, ring ~20k строк. На device открой app (чтобы зеркало обновилось) или connect VPN. Fallback: Share в UI.

## Навигация

Три раздела: **Подключение**, **Сервера**, **Настройки**, **Аккаунт**. **iOS** — нижние вкладки (`TabView`); **Аккаунт** — отдельная круглая кнопка справа (`Tab(role: .search)`). **macOS** — боковая панель слева (`NavigationSplitView`), аккаунт внизу sidebar.

### Подключение

Вкл/выкл VPN, статус, имя сервера, скорость RX/TX при подключении (Clash API `GET /traffic` в extension → App Group; Home читает ↓/↑ KB/s). **iOS:** control «Demar VPN» в Control Center; UI синхронизируется с `NEVPNConnection` при любом переключении Demar (приложение, control, Настройки → VPN, системная кнопка VPN в CC).

### Сервера

Список профилей с API по подписке (после входа). SegmentBar: Hysteria2 + All/Free/Plus/Vip (+ Dev/Tester если есть). Pull-to-refresh обновляет список. Гость — CTA «Войти».

### Настройки

Ссылки, действия, переход в настройки приложения (журнал). **Документы** — меню ToS/PP: **iOS** system bottom sheet, **macOS** overlay (dismiss по клику вне); тексты всегда загружаются с raw GitHub Markdown (`demartltd/tos-pp`) и показываются через MarkdownUI. **iOS push-detail:** title после скролла, bar без blur, лёгкий top-градиент. **macOS** — обычный `navigationTitle`. **Служебное меню** — тройной тап по версии внизу экрана: сводка приложения и идентификаторы устройства (IDFV/IDFA или macOS UUID). **iOS IDFA:** системный запрос ATT при первом запуске (когда статус ещё не определён); в служебном меню кнопка **«Включить IDFA»** — повторный ATT или переход в настройки приложения, если отслеживание уже запрещено.

### Аккаунт

Email OTP (+ optional TOTP) и Telegram OAuth → `auth.example.invalid` / `account.example.invalid`. Сессия: `userId`+`loginAt` в UserDefaults; при старте — `session/check`. **Гость:** вход через bottom sheet. **Вошёл:** username, план VPN, срок, «Выйти» (logout API + stop VPN + clear servers). Callback: `demar://auth/callback`.

