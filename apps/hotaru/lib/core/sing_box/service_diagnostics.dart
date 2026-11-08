import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../common/task_pool.dart';
import '../../models/models.dart';
import '../adapter.dart';
import 'service_catalog.dart';
import 'probe_evidence.dart';
import 'telegram_probe.dart' show telegramDataCenters;
import '../../common/constant.dart' show browserUa;

final class _ServiceRun {
  final cancelled = Completer<void>();
  int users = 0;
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

final class SingBoxServiceDiagnostics {
  final ServiceProbeSender send;
  final ServiceProbeSender? sendTcp;
  final TaskPool _pool = TaskPool(4);
  final _runs = <String, _ServiceRun>{};
  final _claims = <String, _ServiceRun>{};
  final _cancelled = <String, DateTime>{};
  bool _closed = false;

  SingBoxServiceDiagnostics({required this.send, this.sendTcp});

  Future<List<ServiceCheckItem>> check(ServiceCheckParams params) async {
    if (_closed) throw const CoreAdapterException('closed');
    if (params.runId.length > 256 ||
        params.names.length > 63 ||
        params.timeout > 120000) {
      throw const CoreAdapterException('invalid_probe_bounds');
    }
    if (params.cancel) {
      _runs[params.runId]?.cancel();
      if (params.runId.isNotEmpty) {
        _cancelled[params.runId] = DateTime.now();
        while (_cancelled.length > 64) {
          _cancelled.remove(_cancelled.keys.first);
        }
      }
      return [];
    }
    _cancelled.removeWhere(
      (_, at) => DateTime.now().difference(at) > const Duration(minutes: 10),
    );
    if (_cancelled.containsKey(params.runId)) return [];
    if (_runs.length >= 64 || _pool.pendingCount >= 128) {
      throw const CoreAdapterException('probe_queue_full');
    }
    final names = params.names.isEmpty
        ? singBoxServiceEndpoints.keys.toList()
        : params.names
              .toSet()
              .where(singBoxServiceEndpoints.containsKey)
              .toList();
    final run = params.runId.isEmpty
        ? _ServiceRun()
        : _runs.putIfAbsent(params.runId, _ServiceRun.new);
    run.users++;
    try {
      return await Future.wait(
        names.map((name) async {
          final claim = _ServiceRun();
          final key = '${params.connectivity}/$name';
          _claims.remove(key)?.cancel();
          _claims[key] = claim;
          final cancelled = Future.any([
            run.cancelled.future,
            claim.cancelled.future,
          ]);
          final env = _ServiceEnvironment(
            name,
            send,
            sendTcp,
            params,
            cancelled,
          );
          try {
            return await _pool.run(() async {
              if (_closed ||
                  run.cancelled.isCompleted ||
                  claim.cancelled.isCompleted) {
                return ServiceCheckItem(name: name, status: 'failed');
              }
              return env.check(name);
            });
          } finally {
            if (identical(_claims[key], claim)) _claims.remove(key);
            claim.cancel();
          }
        }),
      );
    } finally {
      run.users--;
      if (run.users == 0) {
        run.cancel();
        if (identical(_runs[params.runId], run)) _runs.remove(params.runId);
      }
    }
  }

  void close() {
    _closed = true;
    for (final run in [..._runs.values, ..._claims.values]) {
      run.cancel();
    }
    _runs.clear();
    _claims.clear();
    _cancelled.clear();
  }
}

final class _ServiceEnvironment {
  final String name;
  final ServiceProbeSender send;
  final ServiceProbeSender? sendTcp;
  final ServiceCheckParams params;
  final Future<void> cancelled;
  final observations = <ServiceObservation>[];
  final hits = <RouteHit>[];
  RouteSnapshot? snapshot;
  final watch = Stopwatch()..start();

  _ServiceEnvironment(
    this.name,
    this.send,
    this.sendTcp,
    this.params,
    this.cancelled,
  );

  Future<ProbeResult> get(
    String url, {
    int maxBody = 512 * 1024,
    bool tcp = false,
  }) async {
    final timeout = params.timeout <= 0 ? 10000 : params.timeout;
    final remaining =
        timeout * (name == 'telegram' ? 6 : 4) - watch.elapsedMilliseconds;
    if (remaining <= 0) return ProbeResult(url: url, error: 'timeout');
    final sender = tcp ? sendTcp : send;
    if (sender == null) {
      throw const CoreAdapterException('tcp_probe_unavailable');
    }
    final observed = await sender(
      ProbeParams(
        url: url,
        proxyName: params.proxyName,
        timeout: remaining < timeout ? remaining : timeout,
        maxBody: maxBody,
        headers: const {'User-Agent': browserUa},
      ),
      cancelled,
    );
    final previous = snapshot;
    if (previous != null && previous.coreEpoch != observed.snapshot.coreEpoch) {
      throw const CoreAdapterException('session_changed');
    }
    snapshot = observed.snapshot;
    final result = observed.result;
    observations.add(
      ServiceObservation(
        url: result.url,
        statusCode: result.statusCode,
        rule: result.rule,
        rulePayload: result.rulePayload,
        chains: result.chains,
        error: result.error ?? '',
      ),
    );
    for (final hit in observed.hits) {
      if (!hits.contains(hit)) hits.add(hit);
    }
    return result;
  }

  Future<ServiceCheckItem> check(String name) async {
    try {
      final endpoint = params.connectivity
          ? switch (name) {
              'google' => 'https://www.google.com/generate_204',
              'youtube' => 'https://www.youtube.com/generate_204',
              _ => singBoxServiceEndpoints[name]!,
            }
          : singBoxServiceEndpoints[name]!;
      var result = await get(
        endpoint,
        maxBody: params.connectivity
            ? 0
            : const {'prime-video', 'tiktok'}.contains(name)
            ? 8 * 1024 * 1024
            : 512 * 1024,
      );
      var classification = await classifyServiceResponse(
        result,
        connectivity: params.connectivity,
      );
      var region = '';
      if (!params.connectivity && name == 'bilibili') {
        result = await get(
          'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi',
          maxBody: 16384,
        );
        classification = await _bilibiliStatus(result);
        if (classification == 'available') {
          region = 'CN';
        } else if (classification == 'unsupported-region') {
          result = await get(
            'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi',
            maxBody: 16384,
          );
          classification = await _bilibiliStatus(result);
        }
      }
      if (!params.connectivity && result.error == null) {
        if (name == 'github' && classification == 'reachable') {
          result = await get(
            'https://raw.githubusercontent.com/github/gitignore/5808b77453dec299d4daf8557b05a80be832a5b8/Global/Windows.gitignore',
            maxBody: 16384,
          );
          classification = await classifyServiceResponse(result);
          final body = result.body;
          if (classification == 'reachable' &&
              await Isolate.run(
                    () => sha256.convert(utf8.encode(body)).toString(),
                  ) !=
                  'd763006b3cb986d97d8d5d9081e3e82783060cb9afceaef1544c43f5e6bf796f') {
            classification = 'failed';
            observations[observations.length - 1] = observations.last.copyWith(
              error: 'content-sha256-mismatch',
            );
          }
        } else if (name == 'netflix' && classification == 'reachable') {
          final original = result;
          final licensed = await get('https://www.netflix.com/title/70143836');
          final playable = RegExp(r'"isPlayable"\s*:\s*true');
          final originalBody = original.body;
          final licensedBody = licensed.body;
          final state = await Isolate.run(
            () => (
              original: playable.hasMatch(originalBody),
              licensed: playable.hasMatch(licensedBody),
            ),
          );
          classification = !state.original
              ? 'inconclusive'
              : licensed.error == null && licensed.statusCode == 404
              ? 'originals-only'
              : state.licensed &&
                    await classifyServiceResponse(licensed) == 'reachable'
              ? 'available'
              : 'inconclusive';
        } else if (name == 'steam' && classification == 'reachable') {
          final community = await get('https://steamcommunity.com/');
          classification = await classifyServiceResponse(community);
          if (community.body.contains('error code: -101') ||
              community.body.contains('error code: -105')) {
            classification = 'blocked';
          }
        }
        if (name == 'chatgpt' || name == 'claude') {
          final trace = await get(
            'https://${name == 'chatgpt' ? 'chatgpt.com' : 'claude.ai'}/cdn-cgi/trace',
            maxBody: 16384,
          );
          if (trace.error == null &&
              trace.statusCode == 200 &&
              _sameChain(result.chains, trace.chains)) {
            region =
                RegExp(
                  r'^loc=([A-Z]{2})$',
                  multiLine: true,
                ).firstMatch(trace.body)?.group(1) ??
                '';
          }
        } else {
          final body = result.body;
          final url = result.url;
          final fields = await Isolate.run(
            () => serviceRegionFields(name, body, url),
          );
          if (fields.region.isNotEmpty) region = fields.region;
          if (classification == 'reachable' && fields.unsupported) {
            classification = 'unsupported-region';
          }
        }
      }
      if (!params.connectivity && name == 'telegram') {
        var passed = 0;
        for (final (index, address) in telegramDataCenters.indexed) {
          final dc = await get(
            'mtproto://$address:443/DC${index + 1}',
            maxBody: 0,
            tcp: true,
          );
          if (dc.error == null && dc.statusCode == 200) passed++;
        }
        classification = passed == telegramDataCenters.length
            ? 'reachable'
            : 'inconclusive';
      }
      return ServiceCheckItem(
        name: name,
        status: classification,
        region: region,
        delay: result.delay,
        chains: result.chains,
        checkedAt: DateTime.now().millisecondsSinceEpoch,
        coreEpoch: snapshot?.coreEpoch ?? 0,
        routeVersion: snapshot?.routeVersion ?? 0,
        hits: hits,
        observations: observations,
      );
    } on CoreAdapterException catch (error) {
      return ServiceCheckItem(
        name: name,
        status: 'failed',
        observations: [
          ...observations,
          ServiceObservation(error: error.code),
        ],
      );
    }
  }
}

bool _sameChain(List<String> first, List<String> second) =>
    first.isNotEmpty &&
    first.length == second.length &&
    List.generate(
      first.length,
      (index) => first[index] == second[index],
    ).every((same) => same);

Future<String> classifyServiceResponse(
  ProbeResult result, {
  bool connectivity = false,
}) => Isolate.run(() {
  if (result.error != null) {
    return result.error == 'timeout' ? 'timeout' : 'failed';
  }
  if (connectivity) {
    return result.statusCode >= 100 && result.statusCode <= 599
        ? 'reachable'
        : 'failed';
  }
  final body = result.body.toLowerCase();
  bool contains(List<String> values) => values.any(body.contains);
  if (contains([
    'unsupported_country',
    'country_not_supported',
    'not available in your country',
    'not available in your region',
    'geo_restricted',
    'region_not_supported',
  ])) {
    return 'unsupported-region';
  }
  if (contains([
    'cf-chl-',
    'challenge-platform',
    'verify you are human',
    'just a moment...',
    'g-recaptcha',
    '/sorry/index',
  ])) {
    return 'challenge';
  }
  if (contains([
    'access denied',
    'request is not allowed',
    'sorry, you have been blocked',
  ])) {
    return 'restricted';
  }
  if (result.statusCode == 401) return 'authentication-required';
  if (result.statusCode >= 200 && result.statusCode < 300) return 'reachable';
  if (result.statusCode == 403 || result.statusCode == 429) return 'restricted';
  if (result.statusCode >= 500) return 'unavailable';
  return 'inconclusive';
});

({String region, bool unsupported}) serviceRegionFields(
  String name,
  String body,
  String url,
) {
  final patterns = switch (name) {
    'youtube' => [
      r'''id=["']country-code["'][^>]*>\s*([A-Za-z]{2,3})\s*<''',
      r'"GL"\s*:\s*"([A-Za-z]{2})"',
      r'"countryCode"\s*:\s*"([A-Za-z]{2})"',
      r'"country_code"\s*:\s*"([A-Za-z]{2})"',
    ],
    'disney-plus' || 'spotify' => [r'"countryCode"\s*:\s*"([A-Za-z]{2})"'],
    'discord' => [r'"country_code"\s*:\s*"([A-Za-z]{2})"'],
    'prime-video' => [r'"currentTerritory"\s*:\s*"([A-Za-z]{2})"'],
    'tiktok' => [
      r'"webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"([A-Za-z]{2})"',
    ],
    'gemini' => [r',2,1,200,"([A-Za-z]{2,3})"'],
    _ => <String>[],
  };
  var region = '';
  for (final pattern in patterns) {
    region =
        RegExp(
          pattern,
          caseSensitive: false,
        ).firstMatch(body)?.group(1)?.toUpperCase() ??
        '';
    if (region.isNotEmpty) break;
  }
  if (name == 'spotify') {
    final segments = Uri.tryParse(url)?.pathSegments ?? [];
    if (segments.isNotEmpty &&
        RegExp(
          r'^[a-z]{2}-[a-z]{2}$',
          caseSensitive: false,
        ).hasMatch(segments.first)) {
      region = segments.first.split('-').last.toUpperCase();
    }
  }
  return (
    region: region,
    unsupported:
        name == 'prime-video' &&
            RegExp(r'"isServiceRestricted"\s*:\s*true').hasMatch(body) ||
        name == 'disney-plus' &&
            RegExp(r'"inSupportedLocation"\s*:\s*false').hasMatch(body),
  );
}

Future<String> _bilibiliStatus(ProbeResult result) async {
  if (result.error != null || result.statusCode != 200) {
    return classifyServiceResponse(result);
  }
  final body = result.body;
  return Isolate.run(
    () => switch (RegExp(
      r'^\s*\{\s*"code"\s*:\s*(-?\d+)',
    ).firstMatch(body)?.group(1)) {
      '0' => 'available',
      '-10403' => 'unsupported-region',
      _ => 'failed',
    },
  );
}
