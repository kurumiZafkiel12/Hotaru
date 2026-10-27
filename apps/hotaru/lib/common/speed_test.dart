import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum SpeedTestProvider {
  apple,
  cloudflare,
  speedtest,
  fast,
  librespeed,
  google,
  mlab,
  cachefly,
  vultr,
}

enum SpeedTestPhase { connecting, latency, download, upload, done }

extension SpeedTestProviderLabel on SpeedTestProvider {
  String get label => switch (this) {
    SpeedTestProvider.apple => 'Apple',
    SpeedTestProvider.cloudflare => 'Cloudflare',
    SpeedTestProvider.speedtest => 'Speedtest',
    SpeedTestProvider.fast => 'Fast.com',
    SpeedTestProvider.librespeed => 'LibreSpeed',
    SpeedTestProvider.google => 'Google',
    SpeedTestProvider.mlab => 'M-Lab',
    SpeedTestProvider.cachefly => 'CacheFly',
    SpeedTestProvider.vultr => 'Vultr',
  };

  /// The address a run actually talks to, shown beside the name so the
  /// user can see where the traffic goes before spending it.
  String get endpointLabel => switch (this) {
    SpeedTestProvider.apple => 'mensura.cdn-apple.com',
    SpeedTestProvider.cloudflare => 'speed.cloudflare.com',
    SpeedTestProvider.speedtest => 'www.speedtest.net · 自动选最近服务器',
    SpeedTestProvider.fast => 'api.fast.com · Netflix 服务器',
    SpeedTestProvider.librespeed => 'librespeed.org · 自动选最近站点',
    SpeedTestProvider.google => 'dl.google.com · Chrome 安装包（171 MB）',
    SpeedTestProvider.mlab => 'locate.measurementlab.net · 自动选最近机房',
    SpeedTestProvider.cachefly => 'cachefly.cachefly.net · 100 MB 测试文件',
    SpeedTestProvider.vultr => 'hnd-jp-ping.vultr.com · 东京 · 100 MB 文件',
  };
}

class SpeedTestTarget {
  const SpeedTestTarget({
    required this.latencyUrl,
    required this.downloadUrl,
    required this.uploadUrl,
    required this.serverLabel,
    this.supportsUpload = true,
  });

  final String latencyUrl;
  final String downloadUrl;
  final String uploadUrl;
  final String serverLabel;
  final bool supportsUpload;
}

class SpeedTestResult {
  const SpeedTestResult({
    this.latencyMs,
    this.jitterMs,
    this.downloadBps,
    this.uploadBps,
    this.uploadUnsupported = false,
    this.serverLabel = '',
    this.error,
    this.cancelled = false,
  });

  final double? latencyMs;
  final double? jitterMs;
  final double? downloadBps;
  final double? uploadBps;
  final bool uploadUnsupported;
  final String serverLabel;
  final String? error;
  final bool cancelled;

  bool get succeeded => error == null && !cancelled;
}

/// Smallest round gauge scale (in bps) that keeps [bps] inside the dial.
double speedGaugeScaleMax(double bps) {
  final mbps = bps / 1e6;
  for (final tier in [
    10.0,
    25.0,
    50.0,
    100.0,
    250.0,
    500.0,
    1000.0,
    2500.0,
    5000.0,
  ]) {
    if (mbps <= tier) {
      return tier * 1e6;
    }
  }
  return 10000 * 1e6;
}

typedef SpeedTestProgress =
    void Function(SpeedTestPhase phase, double liveBps, double progress);

String formatSpeedValue(double bps) {
  final mbps = bps / 1e6;
  if (mbps >= 1000) {
    return (mbps / 1000).toStringAsFixed(2);
  }
  return mbps.toStringAsFixed(1);
}

String formatSpeedUnit(double bps) => bps / 1e6 >= 1000 ? 'Gbps' : 'Mbps';

const speedTestUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

class SpeedTestRunner {
  SpeedTestRunner({required this.findProxy});

  final String Function(Uri uri) findProxy;

  bool _cancelled = false;
  HttpClient? _client;
  WebSocket? _webSocket;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    _webSocket?.close().ignore();
    _webSocket = null;
  }

  HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = speedTestUserAgent
      ..findProxy = findProxy;
    _client = client;
    return client;
  }

  Future<SpeedTestResult> run({
    required SpeedTestProvider provider,
    required int durationSeconds,
    required SpeedTestProgress onProgress,
    bool downloadOnly = false,
  }) async {
    _cancelled = false;
    try {
      onProgress(SpeedTestPhase.connecting, 0, 0);
      if (provider == SpeedTestProvider.mlab) {
        return await _runMLab(
          durationSeconds: durationSeconds,
          onProgress: onProgress,
          downloadOnly: downloadOnly,
        );
      }
      final target = await _resolveTarget(provider);
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
      double? latency;
      double? jitter;
      if (!downloadOnly) {
        onProgress(SpeedTestPhase.latency, 0, 0);
        final measured = await _measureLatency(target.latencyUrl);
        latency = measured.median;
        jitter = measured.jitter;
        if (_cancelled) {
          return const SpeedTestResult(cancelled: true);
        }
      }
      onProgress(SpeedTestPhase.download, 0, 0);
      final download = await _measureLoad(
        target.downloadUrl,
        durationSeconds,
        true,
        (liveBps, progress) =>
            onProgress(SpeedTestPhase.download, liveBps, progress),
      );
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
      double? upload;
      var uploadUnsupported = false;
      if (!downloadOnly) {
        if (!target.supportsUpload) {
          uploadUnsupported = true;
        } else {
          onProgress(SpeedTestPhase.upload, 0, 0);
          upload = await _measureLoad(
            target.uploadUrl,
            durationSeconds,
            false,
            (liveBps, progress) =>
                onProgress(SpeedTestPhase.upload, liveBps, progress),
          );
          if (_cancelled) {
            return const SpeedTestResult(cancelled: true);
          }
        }
      }
      onProgress(SpeedTestPhase.done, 0, 1);
      return SpeedTestResult(
        latencyMs: latency,
        jitterMs: jitter,
        downloadBps: download,
        uploadBps: upload,
        uploadUnsupported: uploadUnsupported,
        serverLabel: target.serverLabel,
      );
    } catch (error) {
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
      return SpeedTestResult(error: error.toString());
    } finally {
      _client?.close(force: true);
      _client = null;
      _webSocket?.close().ignore();
      _webSocket = null;
    }
  }

  Future<SpeedTestTarget> _resolveTarget(SpeedTestProvider provider) async {
    switch (provider) {
      case SpeedTestProvider.apple:
        return _resolveApple();
      case SpeedTestProvider.cloudflare:
        return _resolveCloudflare();
      case SpeedTestProvider.speedtest:
        return _resolveSpeedtestNet();
      case SpeedTestProvider.fast:
        return _resolveFast();
      case SpeedTestProvider.librespeed:
        return _resolveLibreSpeed();
      case SpeedTestProvider.google:
        return const SpeedTestTarget(
          latencyUrl:
              'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi',
          downloadUrl:
              'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi',
          uploadUrl: '',
          serverLabel: 'dl.google.com · Google CDN',
          supportsUpload: false,
        );
      case SpeedTestProvider.cachefly:
        return const SpeedTestTarget(
          latencyUrl: 'https://cachefly.cachefly.net/100mb.test',
          downloadUrl: 'https://cachefly.cachefly.net/100mb.test',
          uploadUrl: '',
          serverLabel: 'cachefly.cachefly.net · CacheFly CDN',
          supportsUpload: false,
        );
      case SpeedTestProvider.vultr:
        return const SpeedTestTarget(
          latencyUrl: 'https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin',
          downloadUrl: 'https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin',
          uploadUrl: '',
          serverLabel: 'Vultr · 东京 (Tokyo)',
          supportsUpload: false,
        );
      case SpeedTestProvider.mlab:
        throw StateError('M-Lab runs through its own WebSocket flow');
    }
  }

  Future<SpeedTestTarget> _resolveApple() async {
    final body = await _getText(
      'https://mensura.cdn-apple.com/api/v1/gm/config',
    );
    final data = jsonDecode(body) as Map<String, dynamic>;
    final urls = data['urls'] as Map<String, dynamic>?;
    final large = urls?['large_https_download_url'] as String?;
    final upload = urls?['https_upload_url'] as String?;
    final small = urls?['small_https_download_url'] as String?;
    final endpoint = data['test_endpoint'] as String?;
    if (large == null || large.isEmpty || upload == null || upload.isEmpty) {
      throw Exception('Apple speed test config is incomplete');
    }
    return SpeedTestTarget(
      latencyUrl: (small == null || small.isEmpty) ? large : small,
      downloadUrl: large,
      uploadUrl: upload,
      serverLabel: endpoint ?? 'mensura.cdn-apple.com',
    );
  }

  Future<SpeedTestTarget> _resolveCloudflare() async {
    final trace = await _getText('https://speed.cloudflare.com/cdn-cgi/trace');
    final fields = <String, String>{};
    for (final line in trace.split('\n')) {
      final parts = line.split('=');
      if (parts.length == 2) {
        fields[parts[0].trim()] = parts[1].trim();
      }
    }
    final ip = fields['ip'] ?? '';
    if (ip.isEmpty) {
      throw Exception('Cloudflare speed test trace is incomplete');
    }
    final labelParts = [
      'speed.cloudflare.com',
      if ((fields['loc'] ?? '').isNotEmpty) fields['loc']!.toUpperCase(),
      if ((fields['colo'] ?? '').isNotEmpty) fields['colo']!.toUpperCase(),
    ];
    return SpeedTestTarget(
      latencyUrl: 'https://speed.cloudflare.com/__down?bytes=0',
      downloadUrl: 'https://speed.cloudflare.com/__down?bytes=25000000',
      uploadUrl: 'https://speed.cloudflare.com/__up',
      serverLabel: labelParts.join(' · '),
    );
  }

  Future<SpeedTestTarget> _resolveSpeedtestNet() async {
    final body = await _getText(
      'https://www.speedtest.net/api/js/servers?engine=js&limit=25&https_functional=true',
    );
    final servers = (jsonDecode(body) as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .where((server) => (server['host'] as String? ?? '').isNotEmpty)
        .take(25)
        .toList();
    if (servers.isEmpty) {
      throw Exception('Speedtest server list is empty');
    }
    final probed =
        <({String host, String uploadUrl, String label, double latency})>[];
    await Future.wait(
      servers.map((server) async {
        final host = server['host'] as String;
        final latency = await _probeLatency('https://$host/latency.txt');
        if (latency == null) {
          return;
        }
        final advertised = server['url'] as String? ?? '';
        probed.add((
          host: host,
          uploadUrl: advertised.startsWith('http')
              ? advertised.replaceFirst('http://', 'https://')
              : 'https://$host/upload',
          label: [
            if ((server['sponsor'] as String? ?? '').isNotEmpty)
              server['sponsor'] as String,
            if ((server['name'] as String? ?? '').isNotEmpty)
              server['name'] as String,
            if ((server['cc'] as String? ?? '').isNotEmpty)
              (server['cc'] as String).toUpperCase(),
          ].join(' · '),
          latency: latency,
        ));
      }),
    );
    probed.sort((a, b) => a.latency.compareTo(b.latency));
    for (final candidate in probed.take(5)) {
      final reachable = await _probeDownload(
        'https://${candidate.host}/download?size=100000',
        100000,
      );
      if (reachable) {
        return SpeedTestTarget(
          latencyUrl: 'https://${candidate.host}/latency.txt',
          downloadUrl: 'https://${candidate.host}/download?size=25000000',
          uploadUrl: candidate.uploadUrl,
          serverLabel: candidate.label.isNotEmpty
              ? candidate.label
              : candidate.host,
        );
      }
    }
    throw Exception('No reachable Speedtest server');
  }

  Future<SpeedTestTarget> _resolveFast() async {
    final html = await _getText('https://fast.com');
    final script = RegExp(r'/app-[a-z0-9]+\.js').firstMatch(html);
    if (script == null) {
      throw Exception('Fast.com page layout changed');
    }
    final js = await _getText('https://fast.com${script.group(0)}');
    final token = RegExp(r'token:"([A-Za-z0-9_-]+)"').firstMatch(js);
    if (token == null) {
      throw Exception('Fast.com token not found');
    }
    final body = await _getText(
      'https://api.fast.com/netflix/speedtest/v2?https=true&token=${token.group(1)}&urlCount=5',
    );
    final data = jsonDecode(body) as Map<String, dynamic>;
    final targets = (data['targets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .where((target) => (target['url'] as String? ?? '').isNotEmpty)
        .toList();
    if (targets.isEmpty) {
      throw Exception('Fast.com returned no targets');
    }
    final first = targets.first;
    final location = first['location'] as Map<String, dynamic>?;
    final label = [
      'Netflix',
      if ((location?['city'] as String? ?? '').isNotEmpty)
        location!['city'] as String,
      if ((location?['country'] as String? ?? '').isNotEmpty)
        (location!['country'] as String).toUpperCase(),
    ].join(' · ');
    final url = first['url'] as String;
    return SpeedTestTarget(
      latencyUrl: url,
      downloadUrl: url,
      uploadUrl: '',
      serverLabel: label,
      supportsUpload: false,
    );
  }

  Future<SpeedTestTarget> _resolveLibreSpeed() async {
    final body = await _getText(
      'https://librespeed.org/backend-servers/servers.php',
    );
    final servers = (jsonDecode(body) as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .where(
          (server) =>
              (server['server'] as String? ?? '').startsWith('https://'),
        )
        .take(8)
        .toList();
    final probed = <({String base, String name, double latency})>[];
    await Future.wait(
      servers.map((server) async {
        var base = server['server'] as String;
        if (!base.endsWith('/')) {
          base = '$base/';
        }
        final latency = await _probeLatency('${base}getIP.php');
        if (latency == null) {
          return;
        }
        probed.add((
          base: base,
          name: server['name'] as String? ?? base,
          latency: latency,
        ));
      }),
    );
    probed.sort((a, b) => a.latency.compareTo(b.latency));
    for (final candidate in probed.take(4)) {
      final downloadOk = await _probeDownload(
        '${candidate.base}garbage.php',
        1,
      );
      if (!downloadOk) {
        continue;
      }
      final uploadOk = await _probeUpload('${candidate.base}empty.php');
      if (!uploadOk) {
        continue;
      }
      return SpeedTestTarget(
        latencyUrl: '${candidate.base}getIP.php',
        downloadUrl: '${candidate.base}garbage.php',
        uploadUrl: '${candidate.base}empty.php',
        serverLabel: candidate.name,
      );
    }
    throw Exception('No reachable LibreSpeed server');
  }

  Future<SpeedTestResult> _runMLab({
    required int durationSeconds,
    required SpeedTestProgress onProgress,
    required bool downloadOnly,
  }) async {
    final target = await _resolveMLab();
    if (_cancelled) {
      return const SpeedTestResult(cancelled: true);
    }
    double? latency;
    double? jitter;
    if (!downloadOnly) {
      onProgress(SpeedTestPhase.latency, 0, 0);
      final samples = <double>[];
      for (var i = 0; i < 3 && !_cancelled; i++) {
        final sample = await _mlabHandshakeMs(target.downloadWs);
        if (sample != null) {
          samples.add(sample);
        }
      }
      if (samples.isEmpty) {
        throw Exception('M-Lab server is unreachable');
      }
      final stats = _latencyStats(samples);
      latency = stats.median;
      jitter = stats.jitter;
    }
    onProgress(SpeedTestPhase.download, 0, 0);
    final download = await _mlabDownload(
      target.downloadWs,
      durationSeconds,
      (liveBps, progress) =>
          onProgress(SpeedTestPhase.download, liveBps, progress),
    );
    if (_cancelled) {
      return const SpeedTestResult(cancelled: true);
    }
    double? upload;
    if (!downloadOnly) {
      onProgress(SpeedTestPhase.upload, 0, 0);
      upload = await _mlabUpload(
        target.uploadWs,
        durationSeconds,
        (liveBps, progress) =>
            onProgress(SpeedTestPhase.upload, liveBps, progress),
      );
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
    }
    onProgress(SpeedTestPhase.done, 0, 1);
    return SpeedTestResult(
      latencyMs: latency,
      jitterMs: jitter,
      downloadBps: download,
      uploadBps: upload,
      serverLabel: target.label,
    );
  }

  Future<({String downloadWs, String uploadWs, String label})>
  _resolveMLab() async {
    final body = await _getText(
      'https://locate.measurementlab.net/v2/nearest/ndt/ndt7',
    );
    final data = jsonDecode(body) as Map<String, dynamic>;
    final results = data['results'] as List<dynamic>? ?? const [];
    if (results.isEmpty) {
      throw Exception('M-Lab returned no servers');
    }
    final first = results.first as Map<String, dynamic>;
    final urls = first['urls'] as Map<String, dynamic>? ?? const {};
    String? downloadWs;
    String? uploadWs;
    for (final entry in urls.entries) {
      final value = entry.value as String? ?? '';
      if (!value.startsWith('wss://')) {
        continue;
      }
      if (entry.key.contains('download')) {
        downloadWs = value;
      }
      if (entry.key.contains('upload')) {
        uploadWs = value;
      }
    }
    if (downloadWs == null || uploadWs == null) {
      throw Exception('M-Lab server has no secure endpoints');
    }
    final location = first['location'] as Map<String, dynamic>?;
    final city = location?['city'] as String? ?? '';
    final country = location?['country'] as String? ?? '';
    final label = [
      (first['machine'] as String?) ?? 'measurementlab.net',
      if (city.isNotEmpty && country.isNotEmpty) '$city, $country',
    ].join(' · ');
    return (downloadWs: downloadWs, uploadWs: uploadWs, label: label);
  }

  Future<double?> _mlabHandshakeMs(String url) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await _wsConnect(url);
      stopwatch.stop();
      await socket.close();
      if (identical(_webSocket, socket)) {
        _webSocket = null;
      }
      return stopwatch.elapsedMilliseconds.toDouble();
    } catch (_) {
      return null;
    }
  }

  Future<WebSocket> _wsConnect(String url) async {
    final socket = await WebSocket.connect(
      url,
      protocols: ['net.measurementlab.ndt.v7'],
      headers: {'User-Agent': speedTestUserAgent},
      customClient: _newClient(),
    );
    _webSocket = socket;
    return socket;
  }

  Future<double> _mlabDownload(
    String url,
    int durationSeconds,
    void Function(double liveBps, double progress) onSample,
  ) async {
    final socket = await _wsConnect(url);
    var totalBytes = 0;
    var closed = false;
    final subscription = socket.listen(
      (message) {
        if (message is List<int>) {
          totalBytes += message.length;
        }
      },
      onDone: () => closed = true,
      onError: (_) => closed = true,
    );
    final started = DateTime.now();
    final deadline = started.add(Duration(seconds: durationSeconds));
    var lastBytes = 0;
    var lastSample = started;
    while (!_cancelled && !closed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final now = DateTime.now();
      final elapsed = now.difference(lastSample).inMilliseconds / 1000;
      if (elapsed >= 0.5) {
        onSample(
          (totalBytes - lastBytes) * 8 / elapsed,
          now.difference(started).inMilliseconds / (durationSeconds * 1000),
        );
        lastBytes = totalBytes;
        lastSample = now;
      }
    }
    final elapsedSeconds =
        DateTime.now().difference(started).inMilliseconds / 1000;
    await subscription.cancel();
    await socket.close();
    if (identical(_webSocket, socket)) {
      _webSocket = null;
    }
    if (totalBytes <= 0) {
      throw Exception('No data transferred during the test');
    }
    return totalBytes * 8 / elapsedSeconds;
  }

  Future<double> _mlabUpload(
    String url,
    int durationSeconds,
    void Function(double liveBps, double progress) onSample,
  ) async {
    final socket = await _wsConnect(url);
    var closed = false;
    final subscription = socket.listen(
      (_) {},
      onDone: () => closed = true,
      onError: (_) => closed = true,
    );
    final payload = Uint8List(128 * 1024);
    var sentBytes = 0;
    final started = DateTime.now();
    final deadline = started.add(Duration(seconds: durationSeconds));
    var finished = false;
    final upload = socket
        .addStream(() async* {
          while (!_cancelled && !closed && DateTime.now().isBefore(deadline)) {
            sentBytes += payload.length;
            yield payload;
          }
        }())
        .whenComplete(() => finished = true);
    var lastBytes = 0;
    var lastSample = started;
    final grace = deadline.add(const Duration(seconds: 3));
    while (!finished && !_cancelled && DateTime.now().isBefore(grace)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final now = DateTime.now();
      final elapsed = now.difference(lastSample).inMilliseconds / 1000;
      if (elapsed >= 0.5) {
        onSample(
          (sentBytes - lastBytes) * 8 / elapsed,
          now.difference(started).inMilliseconds / (durationSeconds * 1000),
        );
        lastBytes = sentBytes;
        lastSample = now;
      }
    }
    final elapsedSeconds =
        DateTime.now().difference(started).inMilliseconds / 1000;
    await socket.close();
    try {
      await upload.timeout(const Duration(seconds: 2));
    } catch (_) {
      // The close above already ended the transfer.
    }
    await subscription.cancel();
    if (identical(_webSocket, socket)) {
      _webSocket = null;
    }
    if (sentBytes <= 0) {
      throw Exception('No data transferred during the test');
    }
    return sentBytes * 8 / elapsedSeconds;
  }

  ({double median, double? jitter}) _latencyStats(List<double> samples) {
    double? jitter;
    if (samples.length >= 2) {
      var total = 0.0;
      for (var i = 1; i < samples.length; i++) {
        total += (samples[i] - samples[i - 1]).abs();
      }
      jitter = total / (samples.length - 1);
    }
    final sorted = [...samples]..sort();
    return (median: sorted[sorted.length ~/ 2], jitter: jitter);
  }

  Future<bool> _probeDownload(String url, int expectedBytes) async {
    try {
      final client = _newClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        client.close(force: true);
        return false;
      }
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received >= expectedBytes) {
          break;
        }
      }
      client.close(force: true);
      return received >= expectedBytes;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeUpload(String url) async {
    try {
      final client = _newClient();
      final request = await client.postUrl(Uri.parse(url));
      request.add(Uint8List(100 * 1024));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      return response.statusCode < HttpStatus.badRequest;
    } catch (_) {
      return false;
    }
  }

  Future<double?> _probeLatency(String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      final client = _newClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        client.close();
        return null;
      }
      await response.take(1).drain<void>();
      client.close(force: true);
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds.toDouble();
    } catch (_) {
      return null;
    }
  }

  Future<({double median, double? jitter})> _measureLatency(String url) async {
    final samples = <double>[];
    for (var i = 0; i < 5; i++) {
      if (_cancelled) {
        break;
      }
      final sample = await _probeLatency(url);
      if (sample != null) {
        samples.add(sample);
      }
    }
    if (samples.isEmpty) {
      throw Exception('Latency probe failed');
    }
    return _latencyStats(samples);
  }

  Future<String> _getText(String url) async {
    final client = _newClient();
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (builder, chunk) => builder..add(chunk),
    );
    client.close();
    if (response.statusCode != HttpStatus.ok) {
      throw Exception('Request failed with status ${response.statusCode}');
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<double> _measureLoad(
    String url,
    int durationSeconds,
    bool download,
    void Function(double liveBps, double progress) onSample,
  ) async {
    final client = _newClient();
    final deadline = DateTime.now().add(Duration(seconds: durationSeconds));
    var totalBytes = 0;
    var lastBytes = 0;
    var lastSample = DateTime.now();
    var failedWorkers = 0;
    const workerCount = 4;
    final payload = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (index) => index % 256),
    );
    Future<void> worker() async {
      while (!_cancelled && DateTime.now().isBefore(deadline)) {
        try {
          if (download) {
            final request = await client.getUrl(Uri.parse(url));
            final response = await request.close();
            if (response.statusCode != HttpStatus.ok) {
              throw Exception(
                'Request failed with status ${response.statusCode}',
              );
            }
            await for (final chunk in response) {
              totalBytes += chunk.length;
              if (_cancelled || DateTime.now().isAfter(deadline)) {
                break;
              }
            }
          } else {
            final request = await client.postUrl(Uri.parse(url));
            request.headers.set(
              HttpHeaders.contentTypeHeader,
              'application/octet-stream',
            );
            request.add(payload);
            final response = await request.close();
            await response.drain<void>();
            if (response.statusCode >= HttpStatus.badRequest) {
              throw Exception(
                'Request failed with status ${response.statusCode}',
              );
            }
            totalBytes += payload.length;
          }
        } catch (_) {
          if (_cancelled || DateTime.now().isAfter(deadline)) {
            break;
          }
          failedWorkers++;
          if (failedWorkers > workerCount * 3) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }

    final workers = List<Future<void>>.generate(workerCount, (_) => worker());
    final started = DateTime.now();
    while (!_cancelled && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = DateTime.now();
      final elapsed = now.difference(lastSample).inMilliseconds / 1000;
      if (elapsed > 0) {
        final progress =
            now.difference(started).inMilliseconds / (durationSeconds * 1000);
        onSample((totalBytes - lastBytes) * 8 / elapsed, progress);
        lastBytes = totalBytes;
        lastSample = now;
      }
    }
    final elapsedSeconds =
        DateTime.now().difference(started).inMilliseconds / 1000;
    client.close(force: true);
    for (final worker in workers) {
      try {
        await worker;
      } catch (_) {
        continue;
      }
    }
    if (totalBytes <= 0) {
      throw Exception('No data transferred during the test');
    }
    if (elapsedSeconds <= 0) {
      throw Exception('Test duration was zero');
    }
    return totalBytes * 8 / elapsedSeconds;
  }
}
