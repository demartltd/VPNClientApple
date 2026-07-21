# Core Runtime Artifacts

## Geo assets

```bash
python3 scripts/singbox-download-auto.py
```

Скрипт скачивает geo-базы `geoip.db` / `geosite.db` в `ios/Shared/singbox/` (и опционально dev-бинарник в `macos/singbox_macos/` для `sing-box check` в тестах).

## Libbox (iOS + macOS, in-process)

Network Extension **нельзя** запускать `sing-box` через `posix_spawn` (EPERM на TUN). Ядро работает через **Libbox.xcframework** (gomobile), как в sing-box-for-apple.

Сборка (один раз после обновления sing-box или при отсутствии framework):

```bash
python3 scripts/libbox-build.py   # → ios/Frameworks/Libbox.xcframework
```

Сборка через upstream `build_libbox` (Apple). Hysteria2 входит в дефолтный набор (`with_quic`). Требуется Go и Xcode. Версия берётся из корневого `singbox-version.txt` и сейчас закреплена на **v1.13.14**.
