**Demar VPN (Apple)** — нативный VPN-клиент на SwiftUI: управление профилями подключения, установка защищённого туннеля и контроль состояния соединения. Ядро — **Xray-core** (VLESS / REALITY), как в кроссплатформенной Flutter-версии [`demar_vpn`](../demar_vpn).

Поддерживаются **iOS 17+** и **macOS 14+** (нативное приложение, один target). Web, Android, Windows и Linux в этом репозитории не поддерживаются.

Все доступные сервера и их конфиги планируется получать удалённо; в MVP — один или несколько тестовых VLESS URI (см. `DemarVPN/Core/Models/TestServers.swift`).

## Сборка

- **Xcode 15+**
- Deployment: **iOS 17+**, **macOS 14+**
- Bundle ID: `com.demar.vpn`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + `DemarXray.xcframework` + App Group
- **macOS:** SwiftUI UI, VPN через моки (`MockVpnControlling`) — без Network Extension
- См. [`readme-core.md`](readme-core.md)
- **DemarXray (iOS, не в git):** `python ../demar_vpn/scripts/build_xray_ios_xcframework.py` → `ios/Frameworks/DemarXray.xcframework`
- **Xray assets (фаза 2, на Mac):** `pip install scrapling` → `python scripts/xray-download-auto.py` (geo в `ios/Shared/xray/`, бинарник arm64 + geo в `macos/xray/`)

```bash
# macOS
xcodebuild -scheme DemarVPN -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -scheme DemarVPN -destination 'platform=iOS Simulator,name=iPhone 17' build
```

В Xcode: выберите destination **My Mac** или симулятор iPhone.

Документация Xray: https://xtls.github.io/en/document/

Структура кода: [`filestree.md`](filestree.md) — обновляй при изменениях в проекте.

## Навигация

Три раздела (нижние вкладки): **Главная**, **Сервера**, **Настройки**.

### Главная

Вкл/выкл VPN, статус, имя сервера, скорость RX/TX.

### Сервера

Список профилей (MVP — тестовые URI), выбор активного сервера.

### Настройки

Ссылки, действия, переход в настройки приложения (журнал). **Служебное меню** — тройной тап по версии внизу экрана: сводка приложения и идентификаторы устройства (IDFV/IDFA или macOS UUID). **iOS IDFA:** системный запрос ATT при первом запуске (когда статус ещё не определён); в служебном меню кнопка **«Включить IDFA»** — повторный ATT или переход в настройки приложения, если отслеживание уже запрещено.

## Roadmap (VPN)

1. ~~`DemarPacketTunnel` + `VpnTunnelController` на iOS~~
2. `DemarControls` (Control Center, iOS 18+) — отдельно
3. macOS VPN (subprocess + `macos/xray/`)
