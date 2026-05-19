# DemarXray.xcframework

В git — только оболочка (Headers, Info.plist, modulemap). Бинарники `DemarXray.framework/DemarXray` в `.gitignore` (сотни MB).

Сборка после клона:

```bash
python ../demar_vpn/scripts/build_xray_ios_xcframework.py
```

Geo и macOS xray: `python scripts/xray-download-auto.py` → `ios/Shared/xray/`, `macos/xray/`.
