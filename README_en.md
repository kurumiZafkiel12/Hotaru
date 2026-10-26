# Hotaru · 蛍

An open-source Mihomo proxy client, independently maintained from FlClash 0.9.2. v0.0.4 builds Windows 10/11 x64 setup and portable packages alongside three Android APKs. Public availability follows the assets in Releases; Linux and macOS are not shipped for this version.

[Download v0.0.4](https://github.com/kurumiZafkiel12/Hotaru/releases/tag/v0.0.4) · [中文介绍](README.md) · [Author community](https://t.me/kurumizafkiel1)

Profiles and subscriptions, node latency and selection, routing rules and overrides, system proxy and TUN, live connections and logs, backup, and network tools are available. Bring your own configuration: the project does not supply servers or subscriptions.

v0.0.2 introduces the Firefly desktop: a slimmer branded sidebar, a full-width outbound card, grouped widgets, calmer light/dark colors and lighter shadows. Existing IP quality checks, details, refresh, network speed, profiles, LAN IP, service checks, memory, connections and proxy groups remain available. Country badges use a bundled flag font. Diagnostic logs append and rotate within a size limit, and JSON parsing runs off the UI isolate. Uninstall data cleanup now targets the actual app directory. The Windows runner no longer restores focus while inactive or minimized; the reported flashing still needs user verification. Intermittent UI freezes remain unconfirmed, and updates do not yet guarantee zero leftover files.

v0.0.1 resets the product version from 0.5.x. It enables effective unified-delay and TCP-concurrent defaults, adds IPv6 (off) and the memory-conservative GEO loader (on), removes the first-launch disclaimer gate and its tools entry, and corrects the author community link. Existing setting values and routing rules are preserved. The latency difference was reproduced with real probes and the user confirmed recovery after enabling the effective overrides; inaccessible nodes still report failure.

Users on 0.5.x must download manually after the version reset; exit the app from its tray before installing, and verify SHA256SUMS. Packages are unsigned. Build with Flutter 3.47.6, Go 1.27.1 and Rust via `dart setup.dart windows --env stable`; Windows also needs Visual Studio C++ tools and Inno Setup 6.

Licensed under [GPL-3.0](LICENSE). Credits: [FlClash](https://github.com/chen08209/FlClash), [Mihomo](https://github.com/MetaCubeX/mihomo), [Bettbox](https://github.com/appshubcc/Bettbox), their contributors and dependencies. Original attribution remains in the application and source.
## v0.0.4

Windows x64 and Android share a cold slate dashboard, compact core widgets and a flat toolbox. Grid resizing uses a ghost preview and commits on release. The 57-service audit distinguishes reachability from unlock evidence and exposes observed rules and proxy chains. Native STUN, authoritative DNS samples, IP analysis and Windows recovery have explicit scope limits. Android keeps the persistent formal signing identity and uses Hotaru splash/tile/notification branding. See [release notes](docs/RELEASE-0.0.4.md) for validation limits and upgrade details.
