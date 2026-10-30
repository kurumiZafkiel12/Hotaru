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

typedef IcePeerFactory =
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration);

class IceProbe {
  IceProbe({IcePeerFactory? createPeer})
    : _createPeer = createPeer ?? createPeerConnection;

  final IcePeerFactory _createPeer;
  RTCPeerConnection? _peer;
  Completer<String>? _done;
  bool _cancelled = false;
  bool _running = false;

  Future<void> cancel() async {
    _cancelled = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete('cancelled');
    await _release();
  }

  Future<void> _disposePeer(RTCPeerConnection peer) async {
    try {
      await peer.dispose().timeout(const Duration(seconds: 1));
    } catch (_) {
      // An unavailable native plugin must not replace the diagnostic outcome.
    }
  }

  Future<void> _release() async {
    final peer = _peer;
    _peer = null;
    if (peer != null) await _disposePeer(peer);
  }

  Future<IceProbeResult> run({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_cancelled || _running) {
      return IceProbeResult(
        candidates: const [],
        completed: false,
        error: _cancelled ? 'cancelled' : 'unavailable',
      );
    }
    _running = true;
    final candidates = <String, IceAddress>{};
    final done = _done = Completer<String>();
    void finish(String outcome) {
      if (!done.isCompleted) done.complete(outcome);
    }

    final timer = Timer(timeout, () => finish('timeout'));
    Future<void> gather() async {
      final peer = await _createPeer({
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
      if (done.isCompleted) {
        unawaited(_disposePeer(peer));
        return;
      }
      _peer = peer;
      peer.onIceCandidate = (candidate) {
        if (done.isCompleted) return;
        final address = IceAddress.parse(candidate.candidate ?? '');
        if (address != null) candidates[address.identity] = address;
      };
      peer.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          finish('completed');
        }
      };
      await peer.createDataChannel('hotaru-diagnostics', RTCDataChannelInit());
      if (done.isCompleted) return;
      final offer = await peer.createOffer();
      if (done.isCompleted) return;
      await peer.setLocalDescription(offer);
    }

    unawaited(gather().catchError((Object _) => finish('unavailable')));
    try {
      final outcome = await done.future;
      return IceProbeResult(
        candidates: List.unmodifiable(candidates.values),
        completed: outcome == 'completed',
        error: outcome == 'completed' ? null : outcome,
      );
    } finally {
      timer.cancel();
      _done = null;
      _running = false;
      unawaited(_release());
    }
  }
}
