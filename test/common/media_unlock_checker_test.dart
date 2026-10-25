import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hotaru/common/media_unlock_checker.dart';
import 'package:hotaru/models/media_unlock.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, {this.fail = false, this.pending});
  final int status;
  final bool fail;
  final Completer<ResponseBody>? pending;
  int closed = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (fail) throw const SocketException('offline');
    if (pending != null) return pending!.future;
    return ResponseBody.fromString(
      '{"country":"US","country_code":"US","region":"US","code":0,"data":{"country":"US","region":"US"},"message":"success"}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'x-github-edge-region': ['us'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed++;
}

void main() {
  test(
    'GitHub fixture distinguishes available, blocked and transport failure',
    () async {
      for (final (status, fail, expected) in [
        (200, false, MediaUnlockStatus.unlocked),
        (403, false, MediaUnlockStatus.blocked),
        (500, false, MediaUnlockStatus.failed),
        (200, true, MediaUnlockStatus.failed),
      ]) {
        final adapter = _Adapter(status, fail: fail);
        final checker = MediaUnlockChecker(adapterFactory: () => adapter);
        final result = await checker.checkAll(
          platforms: [MediaPlatform.github],
        );
        expect(result[MediaPlatform.github]!.status, expected);
        expect(adapter.closed, greaterThan(0));
      }
    },
  );

  test(
    'all upstream services handle bounded fixtures without real requests',
    () async {
      for (final status in [200, 403, 500]) {
        final checker = MediaUnlockChecker(
          adapterFactory: () => _Adapter(status),
          unifiedDelay: true,
        );
        final results = await checker.checkAll();
        expect(results.keys.toSet(), MediaPlatform.values.toSet());
        expect(
          results.values.every(
            (result) => result.status != MediaUnlockStatus.testing,
          ),
          isTrue,
        );
      }
    },
  );

  test('cancelled batch publishes no late result', () async {
    final pending = Completer<ResponseBody>();
    final started = Completer<void>();
    final checker = MediaUnlockChecker(
      adapterFactory: () {
        if (!started.isCompleted) started.complete();
        return _Adapter(200, pending: pending);
      },
    );
    var progress = 0;
    final batch = checker.checkAll(
      platforms: [MediaPlatform.github],
      onProgress: (_) => progress++,
    );
    await started.future;
    checker.cancel();
    pending.complete(ResponseBody.fromString('', 200));
    expect(await batch, isEmpty);
    expect(progress, 0);
  });
}
