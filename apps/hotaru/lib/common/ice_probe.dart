import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'network_diagnostics.dart';

enum IceVerdict { matching, risk, inconclusive }

class IceAddress {
  const IceAddress({
    required this.address,
    required this.port,
    required this.kind,
    required this.protocol,
  });

  final String address;
  final int port;
  final String kind;
  final String protocol;

  static IceAddress? parse(String candidate) {
    final fields = candidate.trim().split(RegExp(r'\s+'));
    if (fields.length < 8 ||
        !fields.first.startsWith('candidate:') ||
        fields[6] != 'typ') {
      return null;
    }
    final port = int.tryParse(fields[5]);
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        !const {'host', 'srflx', 'prflx', 'relay'}.contains(fields[7])) {
      return null;
    }
    final address = fields[4];
    if (InternetAddress.tryParse(address) == null &&
        !address.endsWith('.local')) {
      return null;
    }
    return IceAddress(
      address: address,
      port: port,
      kind: fields[7],
      protocol: fields[2].toLowerCase(),
    );
  }

  bool get isPublic {
    final ip = InternetAddress.tryParse(address);
    return ip != null && isPublicProbeAddress(ip);
  }

  String get identity => '$address:$port/$protocol/$kind';
}

class IceProbeResult {
  const IceProbeResult({
    required this.candidates,
    required this.completed,
    this.error,
  });

  final List<IceAddress> candidates;
  final bool completed;
  final String? error;

  IceVerdict verdict(Iterable<String> expected) {
    final exits = {
      for (final value in expected)
        if (InternetAddress.tryParse(value) case final address?)
          address.address,
    };
    final observed = candidates.where(
      (candidate) => candidate.isPublic && candidate.kind != 'relay',
    );
    if (exits.isEmpty || observed.isEmpty) return IceVerdict.inconclusive;
    if (observed.any(
      (candidate) =>
          !exits.contains(InternetAddress(candidate.address).address),
    )) {
      return IceVerdict.risk;
    }
    return completed ? IceVerdict.matching : IceVerdict.inconclusive;
  }
}

class IceProbe {
  RTCPeerConnection? _peer;
  Completer<void>? _done;
  bool _cancelled = false;

  Future<void> cancel() async {
    _cancelled = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
    await _release();
  }

  Future<void> _release() async {
    final peer = _peer;
    _peer = null;
    if (peer != null) await peer.dispose();
  }

  Future<IceProbeResult> run({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_cancelled) {
      return const IceProbeResult(
        candidates: [],
        completed: false,
        error: 'cancelled',
      );
    }
    final candidates = <String, IceAddress>{};
    final done = _done = Completer<void>();
    var completed = false;
    try {
      final peer = await createPeerConnection({
        'iceServers': [
          {
            'urls': [
              'stun:stun.cloudflare.com:3478',
              'stun:stun.l.google.com:19302',
            ],
          },
        ],
        'iceTransportPolicy': 'all',
      });
      _peer = peer;
      if (_cancelled) {
        return const IceProbeResult(
          candidates: [],
          completed: false,
          error: 'cancelled',
        );
      }
      peer.onIceCandidate = (candidate) {
        if (_cancelled) return;
        final address = IceAddress.parse(candidate.candidate ?? '');
        if (address != null) candidates[address.identity] = address;
      };
      peer.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          completed = true;
          if (!done.isCompleted) done.complete();
        }
      };
      await peer.createDataChannel('hotaru-diagnostics', RTCDataChannelInit());
      await peer.setLocalDescription(await peer.createOffer());
      await done.future.timeout(timeout);
      return IceProbeResult(
        candidates: List.unmodifiable(candidates.values),
        completed: completed && !_cancelled,
        error: _cancelled ? 'cancelled' : null,
      );
    } on TimeoutException {
      return IceProbeResult(
        candidates: List.unmodifiable(candidates.values),
        completed: false,
        error: 'timeout',
      );
    } catch (_) {
      return IceProbeResult(
        candidates: List.unmodifiable(candidates.values),
        completed: false,
        error: 'unavailable',
      );
    } finally {
      await _release();
      _done = null;
    }
  }
}
