import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum SpeedTestProvider { apple, cloudflare, speedtest }

enum SpeedTestPhase { connecting, latency, download, upload, done }

extension SpeedTestProviderLabel on SpeedTestProvider {
  String get label => switch (this) {
    SpeedTestProvider.apple => 'Apple',
    SpeedTestProvider.cloudflare => 'Cloudflare',
    SpeedTestProvider.speedtest => 'Speedtest',
  };
}

class SpeedTestTarget {
  const SpeedTestTarget({
    required this.latencyUrl,
    required this.downloadUrl,
    required this.uploadUrl,
    required this.serverLabel,
  });

  final String latencyUrl;
  final String downloadUrl;
  final String uploadUrl;
  final String serverLabel;
}

class SpeedTestResult {
  const SpeedTestResult({
    this.latencyMs,
    this.downloadBps,
    this.uploadBps,
    this.serverLabel = '',
    this.error,
    this.cancelled = false,
  });

  final double? latencyMs;
  final double? downloadBps;
  final double? uploadBps;
  final String serverLabel;
  final String? error;
  final bool cancelled;

  bool get succeeded => error == null && !cancelled;
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

class SpeedTestRunner {
  SpeedTestRunner({required this.findProxy});

  final String Function(Uri uri) findProxy;

  bool _cancelled = false;
  HttpClient? _client;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = findProxy;
    _client = client;
    return client;
  }

  Future<SpeedTestResult> run({
    required SpeedTestProvider provider,
    required int durationSeconds,
    required SpeedTestProgress onProgress,
  }) async {
    _cancelled = false;
    try {
      onProgress(SpeedTestPhase.connecting, 0, 0);
      final target = await _resolveTarget(provider);
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
      onProgress(SpeedTestPhase.latency, 0, 0);
      final latency = await _measureLatency(target.latencyUrl);
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
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
      onProgress(SpeedTestPhase.upload, 0, 0);
      final upload = await _measureLoad(
        target.uploadUrl,
        durationSeconds,
        false,
        (liveBps, progress) =>
            onProgress(SpeedTestPhase.upload, liveBps, progress),
      );
      if (_cancelled) {
        return const SpeedTestResult(cancelled: true);
      }
      onProgress(SpeedTestPhase.done, 0, 1);
      return SpeedTestResult(
        latencyMs: latency,
        downloadBps: download,
        uploadBps: upload,
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
      'https://www.speedtest.net/api/js/servers?engine=js&limit=10&https_functional=true',
    );
    final servers = (jsonDecode(body) as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .where((server) => (server['host'] as String? ?? '').isNotEmpty)
        .take(10)
        .toList();
    if (servers.isEmpty) {
      throw Exception('Speedtest server list is empty');
    }
    String? bestHost;
    String bestLabel = '';
    double bestLatency = double.infinity;
    await Future.wait(
      servers.map((server) async {
        final host = server['host'] as String;
        final latency = await _probeLatency('https://$host/latency.txt');
        if (latency != null && latency < bestLatency) {
          bestLatency = latency;
          bestHost = host;
          bestLabel = [
            if ((server['sponsor'] as String? ?? '').isNotEmpty)
              server['sponsor'] as String,
            if ((server['name'] as String? ?? '').isNotEmpty)
              server['name'] as String,
            if ((server['cc'] as String? ?? '').isNotEmpty)
              (server['cc'] as String).toUpperCase(),
          ].join(' · ');
        }
      }),
    );
    final host = bestHost ?? servers.first['host'] as String;
    final label = bestLabel.isNotEmpty
        ? bestLabel
        : servers.first['host'] as String;
    return SpeedTestTarget(
      latencyUrl: 'https://$host/latency.txt',
      downloadUrl: 'https://$host/download?size=25000000',
      uploadUrl: 'https://$host/upload',
      serverLabel: label,
    );
  }

  Future<double?> _probeLatency(String url) async {
    try {
      final stopwatch = Stopwatch()..start();
      final client = _newClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      stopwatch.stop();
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      return stopwatch.elapsedMilliseconds.toDouble();
    } catch (_) {
      return null;
    }
  }

  Future<double> _measureLatency(String url) async {
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
    samples.sort();
    return samples[samples.length ~/ 2];
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
