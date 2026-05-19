# DemarXray.xcframework

Не хранится в git (слишком большой для GitHub). Соберите локально из соседнего репозитория:

```bash
python ../demar_vpn/scripts/build_xray_ios_xcframework.py
```

Результат: `ios/Frameworks/DemarXray.xcframework` (нужен для `DemarPacketTunnel` и линковки в Xcode).

Geo-ассеты для Xray: `python scripts/xray-download-auto.py` → `ios/Shared/xray/`.
