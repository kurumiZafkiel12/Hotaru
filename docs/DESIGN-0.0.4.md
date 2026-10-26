# Hotaru 0.0.4

Owner: Codex. User scope: 2026-10-27, Windows and Android together.

## Product contract

- Name the home page Dashboard / 仪表盘. Use a cold slate palette: page
  `#111317`, card `#181B20`, inset `#20242B`, mint `#34D399`, emerald
  `#10B981`, a white 6% card outline, and restrained cyan motion.
- Default desktop: status/IP hero, two traffic figures, outbound mode and
  system proxy/TUN controls. Keep every secondary widget available in the
  editor. Preserve customized layouts; restore defaults explicitly.
- Status: running dot, country badge, monospaced address, evidence-based IP
  type/quality, uptime and ISP; replace the filled fluorescent cookie with a
  dark cyan wave control and white play/pause glyph.
- Grid: responsive 4/2/1 columns, compact sizes, bounded width/height edits,
  a dashed preview during reorder/resize and one layout commit on release.
  Cancellation clears gesture state and leaves the saved layout unchanged.
  Restore classic proportions, persist across restart, respect text scaling.
- Speed tool: thin dual arc, sparse ticks and a moving tip; no horizontal
  separator or center ornaments. Separate latency/jitter/download/upload
  figures. Keep route correctness, cancellation and unsupported-upload states.
- Flat toolbox: service and routing check, speed, DNS leak, STUN/WebRTC leak,
  IP analysis, and Windows recovery (Windows only). No automatic traffic tests.
- Service check: all 57 requested service cases, bounded concurrency,
  per-request actual rule / group / chain / endpoint evidence. Distinguish
  reachability, account requirements, anti-bot challenges, region blocks,
  confirmed unlock and inconclusive responses. A 200 alone is not unlock.
- DNS: authoritative resolver observations; label incomplete evidence. Compare
  resolver ownership with policy, show domestic ISP risks and secure DNS advice.
- STUN: verify transaction IDs and XOR addresses; compare observed public IP
  with proxy egress, separate private addresses. Explain native STUN scope and
  browser-specific WebRTC limits. Rule changes are explicit and reversible.
- IP: preserve sourced type/quality analysis; Google challenge probe has an
  inconclusive state and never fabricates residential or purity claims.
- Windows recovery: clear system proxy and PAC, flush DNS, and recover Hotaru
  TUN through its authoritative lifecycle. Report each outcome independently.
- Android: official core-splashscreen, centered vector logo on cold black,
  short system fade/scale exit and first-frame fade/lift. Respect reduced motion,
  do not delay readiness artificially. Replace FlClash Quick Settings and
  notification glyphs with Hotaru monochrome branding.
- Shared semantics and branding across both platforms; native-only tools are
  platform-gated. Use the pinned persistent Android certificate and increasing
  internal version code; public version 0.0.4.

## Service inventory

AI (13): OpenAI Web, OpenAI API, Claude Web, Claude API, Gemini, Copilot,
Perplexity, Grok, Poe, Midjourney, DeepSeek, Kimi, Doubao.

International media (17): Netflix, YouTube Premium, Disney+, Spotify, Prime
Video, Apple TV+, HBO Max, Hulu, Paramount+, BBC iPlayer, DAZN, Crunchyroll,
Twitch, AbemaTV, TVer, Bahamut Anime, Viu.

Domestic media (6): Bilibili main, Bilibili regional, iQIYI, Tencent Video,
NetEase Music, QQ Music. Main-site direct routing and regional checks are
distinct; a reachable music page does not establish licensed playback.

Social (9): Telegram (web plus five nonce-checked MTProto DC probes), Discord, X, Reddit, Instagram, TikTok, WhatsApp, LINE,
WeChat Web. Telegram DC observations must not be inferred from a web page or identify an account session.

Developer/productivity (7): GitHub including raw, Docker Hub, Hugging Face,
Google Workspace, OneDrive/Office 365, Notion, Wikipedia.

Games/stores (5): Steam store/community, Epic Games, PSN, Nintendo eShop,
Google Play.

## Release evidence

Baseline: merge main `0aa99f7` with the published Windows 0.0.3 source
`4a9f0e6`; do not discard either Muse's application changes or persistent
signing. Prior version test totals are historical.

Require fresh format/analyze/localization/code-generation and focused tests,
full CI, Windows and Android builds, controlled A/B routing observations,
cancel/error/stale-result checks, responsive light/dark screenshots and
downloaded artifact/hash/version/signature inspection. Measure performance
before claiming 60 fps. Record physical-device and Windows-host gaps explicitly.
Publish neither a placeholder tool nor an unverified "all unlocked" result.
