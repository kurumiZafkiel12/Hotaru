import 'dart:async';

import 'package:hotaru/common/ice_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mocktail/mocktail.dart';

class _Channel extends Fake implements RTCDataChannel {}

class _Peer extends Fake implements RTCPeerConnection {
  @override
  Function(RTCIceCandidate)? onIceCandidate;
  @override
  Function(RTCIceGatheringState)? onIceGatheringState;
  Completer<RTCSessionDescription>? pendingOffer;
  bool failDisposal = false;
  int disposals = 0;

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit options,
  ) async => _Channel();

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => pendingOffer == null
      ? RTCSessionDescription('diagnostic-offer', 'offer')
      : await pendingOffer!.future;

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    onIceCandidate?.call(
      RTCIceCandidate('candidate:1 1 UDP 1 8.8.8.8 3478 typ srflx', '0', 0),
    );
    onIceGatheringState?.call(
      RTCIceGatheringState.RTCIceGatheringStateComplete,
    );
  }

  @override
  Future<void> dispose() async {
    disposals++;
    if (failDisposal) throw StateError('native plugin unavailable');
  }
}

void main() {
  test(
    'ICE timeout includes native peer creation and cleans up a late peer',
    () async {
      final pending = Completer<RTCPeerConnection>();
      final peer = _Peer();
      final probe = IceProbe(createPeer: (_) => pending.future);
      final result = await probe.run(timeout: const Duration(milliseconds: 10));
      expect(result.error, 'timeout');
      expect(result.verdict(['8.8.8.8']), IceVerdict.inconclusive);
      pending.complete(peer);
      await Future<void>.delayed(Duration.zero);
      expect(peer.disposals, 1);
    },
  );

  test(
    'hung SDP setup times out and a late plugin error is consumed',
    () async {
      final peer = _Peer()..pendingOffer = Completer<RTCSessionDescription>();
      final probe = IceProbe(createPeer: (_) async => peer);
      final result = await probe.run(timeout: const Duration(milliseconds: 10));
      expect(result.error, 'timeout');
      expect(peer.disposals, 1);
      peer.pendingOffer!.completeError(StateError('late native error'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'cancelling before peer creation returns promptly and disposes the late peer',
    () async {
      final pending = Completer<RTCPeerConnection>();
      final probe = IceProbe(createPeer: (_) => pending.future);
      final running = probe.run();
      await probe.cancel();
      expect((await running).error, 'cancelled');
      final peer = _Peer();
      pending.complete(peer);
      await Future<void>.delayed(Duration.zero);
      expect(peer.disposals, 1);
      expect((await probe.run()).completed, isFalse);
    },
  );

  test(
    'successful candidates survive native disposal failure without an uncaught error',
    () async {
      final peer = _Peer()..failDisposal = true;
      final probe = IceProbe(createPeer: (_) async => peer);
      final result = await probe.run();
      expect(result.completed, isTrue);
      expect(result.error, isNull);
      expect(result.verdict(['8.8.8.8']), IceVerdict.matching);
      await Future<void>.delayed(Duration.zero);
      expect(peer.disposals, 1);
      peer.onIceCandidate?.call(
        RTCIceCandidate('candidate:2 1 UDP 1 1.1.1.1 3478 typ srflx', '0', 0),
      );
      expect(result.candidates.single.address, '8.8.8.8');
    },
  );
}
