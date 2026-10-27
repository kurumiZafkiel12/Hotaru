# Hotaru · 蛍

An open-source Mihomo proxy client for Windows and Android.

[**Download**](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) · [Release notes](https://github.com/kurumiZafkiel12/Hotaru/releases) · [Report an issue](https://github.com/kurumiZafkiel12/Hotaru/issues) · [Community](https://t.me/kurumizafkiel1) · [中文](README.md)

## Features

- A customizable dashboard with outbound IP, connection status and live traffic.
- Subscription and profile import, node selection, proxy groups, rules and overrides.
- Windows system proxy and TUN; Android VPN; rule, global and direct modes.
- Bandwidth tests, connectivity and routing checks for 50+ services, DNS checks, native STUN tests and IP analysis.
- Live connections, logs, and local or WebDAV backups.

Bring your own configuration: Hotaru does not provide servers or subscriptions. Reachability does not establish account access or content unlock. DNS samples and native STUN tests do not certify every application or browser against leaks.

## Install and update

| Platform | Requirements | Downloads |
| --- | --- | --- |
| Windows | Windows 10/11, x64 | [Installer and portable ZIP](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) |
| Android | Android 7.0 or later | [ARM64, ARMv7 and x86_64 APKs](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) |

Packages and SHA256 checksums are available on each release page. macOS and Linux packages are currently unavailable.

- Quit Hotaru from the Windows tray before installing an update. Extract portable packages into a new directory. Windows installers do not carry Authenticode signatures.
- Most Android phones use ARM64. Production APKs share a persistent signing identity and support in-place updates. Export configurations before migrating from an early `.dev` debug package.
- Import a subscription or file under Profiles, select a node under Proxies, then enable network takeover as needed.
- Back up your configuration before upgrading. Existing dashboard layouts are preserved; use Edit → Restore defaults → Done to adopt the default layout.

## Build

Use Flutter 3.47.6, Go 1.27.1 and Rust. Windows also requires Visual Studio C++ tools and Inno Setup 6.

```bash
git clone --recursive https://github.com/kurumiZafkiel12/Hotaru.git
cd Hotaru
flutter pub get
dart setup.dart windows --env stable
```

See [.agents/commands.md](.agents/commands.md) for build commands and [tool/editor-config](tool/editor-config/README.md) for optional editor templates.

## License and credits

[GPL-3.0](LICENSE). Based on [FlClash](https://github.com/chen08209/FlClash) and [Mihomo](https://github.com/MetaCubeX/mihomo), with parts of the toolbox experience inspired by [Bettbox](https://github.com/appshubcc/Bettbox). Original author attribution and dependency licenses are preserved.
