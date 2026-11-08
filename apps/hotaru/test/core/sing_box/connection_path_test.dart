import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/connection_path.dart';
import 'package:hotaru/core/telemetry.dart';

import 'support/telemetry_fixture.dart';

Map<String, dynamic> _call(
  int id, {
  String tag = 'exit',
  String parent = '',
  int root = 1,
  bool dns = false,
  int sourcePort = 20000,
}) => {
  'id': id,
  'root_id': root,
  'parent': parent,
  'outbound': tag,
  'outbound_type': 'http',
  'dial_destination': 'example.org:443',
  'dns': dns,
  'succeeded': true,
  'origin': {
    'inbound': 'mixed',
    'network': 'tcp',
    'source_ip': '127.0.0.1',
    'source_port': sourcePort,
    'destination': 'example.org',
    'destination_port': 443,
    'host': 'example.org',
  },
  'started_at': '2026-11-06T11:59:00.001Z',
  'completed_at': '2026-11-06T11:59:00.002Z',
};

CoreTelemetrySnapshot _sample(List<Map<String, dynamic>> calls) =>
    CoreTelemetrySnapshot.fromJson(
      telemetryFixture()
        ..['active'] = [observedConnectionFixture()]
        ..['dials'] = {
          'capacity': 4096,
          'first_id': calls.isEmpty ? 0 : calls.first['id'],
          'last_id': calls.isEmpty ? 0 : calls.last['id'],
          'entries': calls,
        },
    );

const _nodes = [
  CoreNodeSpec(tag: 'exit', protocol: CoreNodeProtocol.http, detour: 'relay'),
  CoreNodeSpec(tag: 'relay', protocol: CoreNodeProtocol.http),
];

void main() {
  test(
    'native direct observation is complete without inventing a user node',
    () {
      final call = {
        ..._call(1),
        'outbound': 'owned-direct',
        'outbound_type': 'direct',
      };
      final raw = telemetryFixture()
        ..['active'] = [
          {...observedConnectionFixture(), 'outbound': 'owned-direct'},
        ]
        ..['dials'] = {
          'capacity': 4096,
          'first_id': 1,
          'last_id': 1,
          'entries': [call],
        };
      final sample = CoreTelemetrySnapshot.fromJson(raw);
      final path = CoreConnectionPaths(
        sample,
        [],
      ).resolve(sample.active.single)!;
      expect(path.hops, ['owned-direct']);
      expect(path.complete, isTrue);
    },
  );

  test(
    'assembles observed physical entry to exit; configured order is not evidence',
    () {
      final sample = _sample([
        _call(1),
        _call(2, tag: 'relay', parent: 'exit'),
      ]);
      final path = CoreConnectionPaths(
        sample,
        _nodes,
      ).resolve(sample.active.single)!;
      expect(path.hops, ['relay', 'exit']);
      expect(path.complete, isTrue);
      final missing = _sample([_call(1)]);
      final partial = CoreConnectionPaths(
        missing,
        _nodes,
      ).resolve(missing.active.single)!;
      expect(partial.hops, ['exit']);
      expect(partial.complete, isFalse);
    },
  );

  test(
    'does not attach DNS, background, competing or evicted calls to a connection',
    () {
      for (final calls in [
        [_call(1), _call(2, tag: 'relay', parent: 'exit', dns: true)],
        [
          _call(1),
          _call(2, tag: 'relay', parent: 'exit', root: 2, sourcePort: 0),
        ],
        [
          _call(1),
          _call(2, tag: 'relay', parent: 'exit'),
          _call(3, tag: 'other', parent: 'exit'),
        ],
        [_call(2, tag: 'relay', parent: 'exit')],
        [_call(1), _call(2, root: 2)],
      ]) {
        final sample = _sample(calls);
        final path = CoreConnectionPaths(
          sample,
          _nodes,
        ).resolve(sample.active.single)!;
        expect(path.complete, isFalse);
      }
    },
  );

  test(
    'retained complete root remains usable after earlier history was evicted',
    () {
      final sample = _sample([
        _call(4000, root: 4000),
        _call(4001, root: 4000, tag: 'relay', parent: 'exit'),
      ]);
      expect(
        CoreConnectionPaths(
          sample,
          _nodes,
        ).resolve(sample.active.single)!.complete,
        isTrue,
      );
    },
  );

  test(
    'legacy snapshots remain compatible and malformed observations fail closed',
    () {
      final sample = CoreTelemetrySnapshot.fromJson(
        telemetryFixture()..['active'] = [observedConnectionFixture()],
      );
      expect(
        CoreConnectionPaths(sample, _nodes).resolve(sample.active.single),
        isNull,
      );
      for (final call in [
        {..._call(1), 'root_id': 2},
        {..._call(1), 'outbound': 'bad\u0000tag'},
        {..._call(1), 'started_at': '2026-11-06T11:59:00'},
        {..._call(1), 'succeeded': 'true'},
      ]) {
        expect(() => _sample([call]), throwsFormatException);
      }
    },
  );
}
