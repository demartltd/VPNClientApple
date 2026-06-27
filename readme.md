**Demar VPN (Apple)** — нативный VPN-клиент на SwiftUI: управление профилями подключения, установка защищённого туннеля и контроль состояния соединения. Ядро — **Sing-box 1.13.14** (NaiveProxy).

Поддерживаются **iOS 18+** и **macOS 14+** (нативное приложение, один target). Web, Android, Windows и Linux не поддерживаются.

Все доступные сервера и их конфиги планируется получать удалённо; в MVP — тестовые NaiveProxy профили (см. `DemarVPN/Core/Models/TestServers.swift`).

## Сборка

- **Xcode 15+**
- Deployment: **iOS 18+**, **macOS 14+** (VPN на Mac — **Apple Silicon arm64**)
- Bundle ID: `com.demar.vpn`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + App Group + Sing-box config pipeline
- **macOS:** Network Extension + Libbox in-process (как iOS)
- См. [`readme-core.md`](readme-core.md)

Один раз перед сборкой (скрипт только для разработчиков, в runtime не вызывается):

```bash
python3 scripts/singbox-download-auto.py   # → geo db в ios/Shared/singbox/
python3 scripts/libbox-build.py           # → ios/Frameworks/Libbox.xcframework (iOS + macOS)
```

Xcode копирует runtime-assets в app и в `DemarPacketTunnel.appex` (macOS).

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

```powershell
# Локально: Apple Development из Keychain (открывается без нотаризации)
pwsh ./scripts/build-macos.ps1 -Install

# Один раз: cp scripts/build-macos.local.ps1.example scripts/build-macos.local.ps1
# Для -Notarize: P12_PASSWORD, APPLE_ID, APPLE_APP_PASSWORD + demar_vpn_client_apple.p12 в scripts/

# Распространение: Developer ID + нотаризация (иначе macOS: «can't be opened»)
pwsh ./scripts/build-macos.ps1 -Notarize -Package
```

```bash
# macOS Debug (Xcode, только для отладки)
xcodebuild -scheme DemarVPN -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -scheme DemarVPN -destination 'platform=iOS Simulator,name=iPhone 17' build
```

В Xcode: выберите destination **My Mac** или симулятор iPhone.

Для проверки стабильного запуска Packet Tunnel на macOS используйте один путь установки: `pwsh ./scripts/build-macos.ps1 -Install`, затем включите `Demar VPN` в `System Settings → Login Items & Extensions → Network Extensions`.

Документация Sing-box: https://sing-box.sagernet.org/

Структура кода: [`filestree.md`](filestree.md) — обновляй при изменениях в проекте.

## Навигация

Три раздела: **Подключение**, **Сервера**, **Настройки**, **Аккаунт**. **iOS** — нижние вкладки (`TabView`); **Аккаунт** — отдельная круглая кнопка справа (`Tab(role: .search)`). **macOS** — боковая панель слева (`NavigationSplitView`), аккаунт внизу sidebar.

### Подключение

Вкл/выкл VPN, статус, имя сервера, скорость RX/TX при подключении (дельта `getifaddrs`, 1 с; macOS — `utun*`). **iOS:** control «Demar VPN» в Control Center; UI синхронизируется с `NEVPNConnection` при любом переключении Demar (приложение, control, Настройки → VPN, системная кнопка VPN в CC).

### Сервера

Список профилей (MVP — тестовые URI), выбор активного сервера.

### Настройки

Ссылки, действия, переход в настройки приложения (журнал). **Служебное меню** — тройной тап по версии внизу экрана: сводка приложения и идентификаторы устройства (IDFV/IDFA или macOS UUID). **iOS IDFA:** системный запрос ATT при первом запуске (когда статус ещё не определён); в служебном меню кнопка **«Включить IDFA»** — повторный ATT или переход в настройки приложения, если отслеживание уже запрещено.

### Аккаунт

Вход и выход (MVP — локальный stub до подключения API). **Гость:** email, пароль, «Войти», «Создать аккаунт». **Вошёл:** имя, email, статус подписки, «Выйти».

