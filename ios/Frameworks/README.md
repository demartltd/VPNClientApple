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

Сборка через upstream `build_libbox` (Apple) с вырезанными `with_naive_outbound` / `with_usbip` (без Chromium/cronet и без IOUSBHost). Hysteria2 — через `with_quic`. Требуется Go и Xcode. Версия из корневого `singbox-version.txt` (**v1.14.1**).

## OpenFlux (host app only, in-process)

iOS запрещает `posix_spawn` в app/NE; на macOS та же схема для одного Go runtime на процесс. OpenFlux SOCKS — **liboflux** в DemarVPN (не в Packet Tunnel — там Libbox).

```bash
./scripts/openflux-build-apple.sh
# → ios/Frameworks/OpenFlux/liboflux.h
# → ios/Frameworks/OpenFlux/iphoneos/liboflux.a
# → ios/Frameworks/OpenFlux/macosx/liboflux.a   (arm64+x86_64)
```

Линк только DemarVPN (`-loflux`, iphoneos + macosx). Tunnel ждёт `127.0.0.1:11080`.
