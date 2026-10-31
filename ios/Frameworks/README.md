# Core Runtime Artifacts

## Geo assets

Локально положите `geoip.db` / `geosite.db` в `ios/Shared/singbox/` (и опционально dev-бинарник в `macos/singbox_macos/` для `sing-box check` в тестах). Файлы не в git.

## Libbox (iOS + macOS, in-process)

Network Extension **нельзя** запускать `sing-box` через `posix_spawn` (EPERM на TUN). Ядро работает через **Libbox.xcframework** (gomobile), как в sing-box-for-apple.

Соберите `ios/Frameworks/Libbox.xcframework` локально (Go + Xcode) после обновления sing-box или при отсутствии framework. Upstream `build_libbox` (Apple) с вырезанными `with_naive_outbound` / `with_usbip` (без Chromium/cronet и без IOUSBHost). Hysteria2 — через `with_quic`. Версия из корневого `singbox-version.txt` (**v1.14.1**).

## OpenFlux (host app only, in-process)

iOS запрещает `posix_spawn` в app/NE; на macOS та же схема для одного Go runtime на процесс. OpenFlux SOCKS — **liboflux** в DemarVPN (не в Packet Tunnel — там Libbox).

Локально соберите:

- `ios/Frameworks/OpenFlux/liboflux.h`
- `ios/Frameworks/OpenFlux/iphoneos/liboflux.a`
- `ios/Frameworks/OpenFlux/macosx/liboflux.a` (arm64+x86_64)

Линк только DemarVPN (`-loflux`, iphoneos + macosx). Tunnel ждёт `127.0.0.1:11080`.
