# Core Runtime Artifacts

Папка зарезервирована под локальные runtime-артефакты и вспомогательные файлы.

## macOS + geo assets

```bash
python3 scripts/singbox-download-auto.py
```

Скрипт скачивает `sing-box` из release и geo-базы `geoip.db` / `geosite.db` в `ios/Shared/singbox/` и `macos/singbox_macos/`.

## iOS — Libbox (in-process)

На iOS Network Extension **нельзя** запускать `sing-box` через `posix_spawn` (EPERM). Ядро работает через **Libbox.xcframework** (gomobile), как в sing-box-for-apple.

Сборка (один раз после обновления sing-box или при отсутствии framework):

```bash
python3 scripts/libbox-build.py   # → ios/Frameworks/Libbox.xcframework
```

Сборка включает `with_naive_outbound` (Naive proxy). Требуется Go и Xcode.

macOS по-прежнему использует subprocess `sing-box` в extension (`macos/singbox_macos/`).
