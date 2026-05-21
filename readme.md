**Demar VPN (Apple)** — нативный VPN-клиент на SwiftUI: управление профилями подключения, установка защищённого туннеля и контроль состояния соединения. Ядро — **Xray-core** (VLESS / REALITY), как в кроссплатформенной Flutter-версии [`demar_vpn`](../demar_vpn).

Поддерживаются **iOS 18+** и **macOS 14+** (нативное приложение, один target). Web, Android, Windows и Linux не поддерживаются.

Все доступные сервера и их конфиги планируется получать удалённо; в MVP — один или несколько тестовых VLESS URI (см. `DemarVPN/Core/Models/TestServers.swift`).

## Сборка

- **Xcode 15+**
- Deployment: **iOS 18+**, **macOS 14+** (VPN на Mac — **Apple Silicon arm64**)
- Bundle ID: `com.demar.vpn`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + `DemarXray.xcframework` + App Group
- **macOS:** Network Extension + subprocess `xray` в extension (`xray_macos/`, `XRAY_TUN_FD`)
- См. [`readme-core.md`](readme-core.md)

Один раз перед сборкой (скрипт только для разработчиков, в runtime не вызывается):

```bash
python3 scripts/xray-download-auto.py   # → macos/xray_macos/, ios/Shared/xray/
```

Xcode копирует `macos/xray_macos` в app и в `DemarPacketTunnel.appex` (macOS).

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
# Рекомендуемый локальный путь для macOS: xray + сборка + подпись + установка
pwsh ./scripts/build-macos.ps1 -Install

# Один раз: cp scripts/build-macos.local.ps1.example scripts/build-macos.local.ps1
# Заполните P12_PASSWORD, APPLE_ID, APPLE_APP_PASSWORD (+ demar_vpn_client_apple.p12 в scripts/)
pwsh ./scripts/build-macos.ps1 -Package -Install

# Распространение (+ notarytool, те же секреты в local.ps1)
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

Документация Xray: https://xtls.github.io/en/document/

Структура кода: [`filestree.md`](filestree.md) — обновляй при изменениях в проекте.

## Навигация

Три раздела (нижние вкладки): **Главная**, **Сервера**, **Настройки**.

### Главная

Вкл/выкл VPN, статус, имя сервера, скорость RX/TX при подключении (iOS: дельта `getifaddrs`, 1 с; macOS пока 0). **iOS:** control «Demar VPN» в Control Center; UI синхронизируется с `NEVPNConnection` при любом переключении Demar (приложение, control, Настройки → VPN, системная кнопка VPN в CC).

### Сервера

Список профилей (MVP — тестовые URI), выбор активного сервера.

### Настройки

Ссылки, действия, переход в настройки приложения (журнал). **Служебное меню** — тройной тап по версии внизу экрана: сводка приложения и идентификаторы устройства (IDFV/IDFA или macOS UUID). **iOS IDFA:** системный запрос ATT при первом запуске (когда статус ещё не определён); в служебном меню кнопка **«Включить IDFA»** — повторный ATT или переход в настройки приложения, если отслеживание уже запрещено.

