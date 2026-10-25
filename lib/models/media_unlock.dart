// Adapted from appshubcc/Bettbox, commit 1fb8806fdf8275a3694cda31eec7ed2062330aee.
// GPL-3.0; upstream authorship and license retained. See THIRD-PARTY.md.
enum MediaPlatform {
  openai,
  claude,
  gemini,
  grok,
  openrouter,
  poe,
  suno,
  cloudflare,
  perplexity,
  netflix,
  disney,
  youtube,
  youtubemusic,
  spotify,
  tiktok,
  iqiyi,
  crunchyroll,
  missav,
  ehentai,
  tencent,
  alibaba,
  netease,
  douyin,
  bilibili,
  cloudflarecn,
  reddit,
  x,
  discord,
  v2ex,
  medium,
  stackoverflow,
  quora,
  telegram,
  github,
  wikipedia,
  apple,
  onetrust,
  gitlab,
  npm,
  cdnjs,
  unpkg,
  nodejs,
  steam,
  epic,
  ubisoft,
  humblebundle,
  coinbase,
  okx,
  kraken,
  cryptocom,
  phantom,
  paypal,
  mytvsuper,
  viutv,
  hoytv,
  rthk,
}

enum MediaUnlockStatus {
  unlocked,
  limited,
  flagged,
  blocked,
  failed,
  testing,
  unknown,
}

class MediaUnlockResult {
  final MediaPlatform platform;
  final MediaUnlockStatus status;
  final String? region;
  final int? latency;
  final String? colo;
  final String? ip;
  final bool isWarp;

  const MediaUnlockResult({
    required this.platform,
    required this.status,
    this.region,
    this.latency,
    this.colo,
    this.ip,
    this.isWarp = false,
  });

  MediaUnlockResult copyWith({
    MediaPlatform? platform,
    MediaUnlockStatus? status,
    String? region,
    int? latency,
    String? colo,
    String? ip,
    bool? isWarp,
  }) {
    return MediaUnlockResult(
      platform: platform ?? this.platform,
      status: status ?? this.status,
      region: region ?? this.region,
      latency: latency ?? this.latency,
      colo: colo ?? this.colo,
      ip: ip ?? this.ip,
      isWarp: isWarp ?? this.isWarp,
    );
  }
}
