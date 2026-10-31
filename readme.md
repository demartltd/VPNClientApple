**Demar Proxy (Apple)** — native VPN client in SwiftUI: connection profiles, secure tunnel setup, and connection state. Core: **latest sing-box** / Libbox (Hysteria2 / Trojan / VLESS Reality / **OpenFlux** host `liboflux` → local SOCKS + Libbox outbound).

Supports **iOS 18+** and **macOS 15+** (native app, single target).

Server list and configs load remotely after sign-in (`POST /vpn/servers`). **Servers** tab: unified list with tier/protocol badges, toolbar Refresh/Filters, favorites, ping (TCP/TLS/QUIC), details sheet, locked → Premium. Without a session, **Servers** and **Account** open the login bottom sheet.

## Build

- **Xcode 15+**
- Deployment: **iOS 18+**, **macOS 15+** (VPN on Mac — **Apple Silicon arm64**)
- Display name: **Demar Proxy**
- Bundle ID: `com.demar.adblock` · SKU: `demar-adblock`
- Extensions: `com.demar.adblock.packet-tunnel`, `com.demar.adblock.controls`
- App Group: `group.com.demar.adblock`
- **iOS:** SwiftUI + Network Extension (`DemarPacketTunnel`) + App Group + sing-box **1.14.1**
- **macOS:** Network Extension + Libbox in-process (same as iOS)
- See [`readme-core.md`](readme-core.md)

Before building, prepare locally (not in git): copy `.env.example` → `.env` (and `DemarVPN/Resources/demar.env`), geo assets (`geoip.db` / `geosite.db`), `Libbox.xcframework`, OpenFlux `liboflux`, and rule-sets — see [`readme-core.md`](readme-core.md).

Xcode copies geo assets into the host app and `DemarPacketTunnel.appex` (iOS: `singbox/`, macOS: `singbox_macos/`). The dev `sing-box` binary is not shipped in the runtime bundle. Entitlements: `DemarVPN.entitlements`, `ios/DemarPacketTunnel/…`, `ios/DemarControls/…` (App Group + Packet Tunnel).

```bash
# macOS Debug
xcodebuild -scheme DemarVPN -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -scheme DemarVPN -destination 'platform=iOS Simulator,name=iPhone 17' build
```

In Xcode: destination **My Mac** or an iPhone simulator. On Mac after install, enable the extension under `System Settings → Login Items & Extensions → Network Extensions`.

Sing-box docs: https://sing-box.sagernet.org/

Code layout: [`filestree.md`](filestree.md).

### Journal

UI (**Settings → App settings**) — up to 512 lines.  
**macOS / Simulator:** App Group `demar_vpn/vpn_journal.log`.  
**Physical iOS:** host mirrors to `Documents/demar/demar_app.log` (CoreDevice does not expose App Group `demar_vpn/`); pull via `devicectl` `appDataContainer`.

Runtime `core.log`: `log.level=info`, timestamp, ring ~20k lines. On device, open the app (to refresh the mirror) or connect VPN. Fallback: Share in the UI.

## Navigation

Four sections: **Home**, **Servers**, **Settings**, **Account**. **iOS** — `TabView`: three main tabs + **Account** on the right (`TabRole.prominent` on iOS 27+, `.search` on 18…26; icon-only from iOS 26). **macOS** — left sidebar (`NavigationSplitView`), account at the bottom.

### Home

VPN on/off, status, server name, RX/TX while connected (Clash API `GET /traffic` in the extension → App Group; Home reads ↓/↑ KB/s). **iOS:** Control Center control «Demar Proxy»; UI stays in sync with `NEVPNConnection` for any Demar toggle (app, control, Settings → VPN, system VPN button in CC).

### Servers

Subscription server profiles after sign-in. SegmentBar: protocols from the API (HY2 / Trojan / VLESS) + All/Free/Plus/Vip (+ Dev/Tester when present). Pull-to-refresh reloads the list. Guest — sign-in CTA.

### Settings

Links, actions, app settings (Change language + journal). **Languages:** `en` (default) / `ru` / `uk` / `tr` / `uz` / `zh-Hans` / `zh-Hant` / `ko` / `ja` / `es` / `de` / `fr` / `hi` (`Localizable.strings` + `InfoPlist.xcstrings`); change via system per-app language or **App settings → Change language**. **Feedback / Support** — support API tickets (list / chat / draft, up to 10 WebP photos, 8s polling, unread badge); guest → login sheet; channel `ios`/`macos`, `sourceId=2`; silent diagnostics (device + journal) on ticket create. **Documents** — ToS/PP menu: **iOS** system bottom sheet, **macOS** overlay (dismiss on outside tap); Markdown from GitHub (`demartltd/tos-pp`) via MarkdownUI. **iOS push-detail:** title after scroll, bar without blur, light top gradient. **macOS** — standard `navigationTitle`. **Service menu** — triple-tap version at the bottom: app summary and device IDs (IDFV/IDFA or macOS UUID); **Info sheets** (like Android): Expiry / FreeTraffic / Traffic / PayResult ok|fail — UI only, no API. Traffic sheet is global (no tab switch). **Auto-alerts:** on `scenePhase == .active` (same as update alert); paid — Expiry in 72–24h and ≤18h windows (3h cooldown); free — FreeTraffic at ≥200 MiB (6h cooldown). **iOS IDFA:** system ATT prompt on first launch (when status is undetermined); service menu **Enable IDFA** — re-prompt ATT or open app settings if tracking was denied.

### Account

Email OTP (+ optional TOTP) and Telegram OAuth → auth API (sign-in/session only). Session: `userId`+`loginAt` in UserDefaults; on launch — `session/check`. Plan, expiry, notify prefs, and monthly traffic — VPN API (`POST /vpn/account`, `/vpn/notify`, `/vpn/traffic`). **Guest:** login bottom sheet. **Signed in:** avatar + username + tap ID (clipboard); subscription card (Plan/Expires + Buy/Renew → checkout bottom sheet via `/vpn/pay/*`); traffic row with `used/limit · %` preview → **Traffic sheet** (pie); connect limit → FreeTraffic alert (free) or Traffic (paid); **Increase limits** → same checkout; family stub → Coming soon; Notifications → **Notify sheet** (2 toggles); Expiry / FreeTraffic upsell sheets (`SubscriptionAlertStore`); Sign out → confirm → logout API + stop VPN + clear servers. **Checkout:** Plus/VIP × week/month/quarter/year × RUB/EUR, promo discount alert (`/vpn/promo/apply`), RollyPay in Safari, return `demarvpn://pay/ok|fail` → PayResultSheet + `refreshSessionData()` on ok (no `/vpn/pay/status` polling). Deeplinks: `demarvpn://account/buy|plans|traffic` (+ legacy `settings/traffic`); pay `demarvpn://pay/ok|fail`. **Compare plans** — separate bottom sheet. **Revoked / logout:** stop tunnel, wipe App Group `config.json` + connect payload, `removeFromPreferences` — Control Center / Settings VPN cannot connect without auth. Callback: `demarvpn://auth/callback`. **App Review:** email `test@test.com` — local sign-in without OTP; `POST /vpn/servers` as usual (free without passwords); connect blocked with snackbar.
