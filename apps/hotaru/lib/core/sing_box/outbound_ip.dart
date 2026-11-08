import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../common/constant.dart' show browserUa;
import '../../common/network_diagnostics.dart' show isPublicProbeAddress;
import '../../models/models.dart';
import '../adapter.dart';
import 'probe_evidence.dart';

Future<OutboundIpResult> lookupSingBoxOutboundIp(
  OutboundIpParams params,
  ServiceProbeSender send,
) async {
  if (params.urls.isEmpty ||
      params.urls.length > 16 ||
      params.timeout > 120000) {
    throw const CoreAdapterException('invalid_probe_bounds');
  }
  final cancelled = Completer<void>();
  final answer = Completer<OutboundIpResult>();
  final budget = Duration(
    milliseconds: params.timeout <= 0 ? 10000 : params.timeout,
  );
  final watch = Stopwatch()..start();
  var next = 0;
  var active = 0;
  Future<void> worker() async {
    active++;
    try {
      while (!answer.isCompleted && next < params.urls.length) {
        final url = params.urls[next++];
        final remaining = budget - watch.elapsed;
        if (remaining <= Duration.zero) break;
        final observed = await send(
          ProbeParams(
            url: url,
            proxyName: params.proxyName,
            timeout: remaining.inMilliseconds,
            maxBody: 16384,
            headers: const {'User-Agent': browserUa},
          ),
          cancelled.future,
        );
        final result = observed.result;
        if (result.error != null ||
            result.statusCode != 200 ||
            !await mentionsPublicIp(result.body)) {
          continue;
        }
        if (!answer.isCompleted) {
          answer.complete(
            OutboundIpResult(
              url: url,
              body: result.body,
              delay: result.delay,
              chains: result.chains,
              coreEpoch: observed.snapshot.coreEpoch,
              routeVersion: observed.snapshot.routeVersion,
              hits: observed.hits,
              nodeHits: params.proxyName.isEmpty ? const [] : observed.hits,
            ),
          );
        }
      }
    } catch (error, trace) {
      if (!answer.isCompleted) answer.completeError(error, trace);
    } finally {
      active--;
      if (active == 0 && !answer.isCompleted) {
        answer.complete(const OutboundIpResult(error: 'failed'));
      }
    }
  }

  final workers = [
    for (var index = 0; index < 3 && index < params.urls.length; index++)
      worker(),
  ];
  try {
    return await answer.future.timeout(
      budget,
      onTimeout: () => const OutboundIpResult(error: 'timeout'),
    );
  } finally {
    cancelled.complete();
    await Future.wait(workers);
  }
}

Future<bool> mentionsPublicIp(String body) => Isolate.run(() {
  if (body.length > 65536) return false;
  for (final token in body.split(RegExp(r'[^.\:0-9a-zA-Z]+'))) {
    final address = InternetAddress.tryParse(token);
    if (address != null && isPublicProbeAddress(address)) return true;
  }
  return false;
});
