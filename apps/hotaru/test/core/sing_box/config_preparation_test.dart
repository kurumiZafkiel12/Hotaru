import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/bootstrap.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';

const listeners = CoreListenerSpec(
  mixedPort: 17890,
  controllerPort: 19090,
  secret: 'fixture',
);
CoreConfigImportResult imported({
  String name = 'direct',
  List<CoreConfigIssue> issues = const [],
}) => CoreConfigImportResult(
  profile: CoreProfileSpec(
    nodes: [CoreNodeSpec(tag: name, protocol: CoreNodeProtocol.direct)],
    selectors: [],
    finalOutbound: name,
  ),
  issues: issues,
);
Map<String, dynamic> decoded(AcceptedSingBoxConfig accepted) =>
    jsonDecode(utf8.decode(accepted.bootstrap.bytes)) as Map<String, dynamic>;

final class _ManyReferences extends ListBase<Object?> {
  int reads = 0;
  @override
  int get length => 1000000;
  @override
  set length(int value) => throw UnimplementedError();
  @override
  Object? operator [](int index) {
    reads++;
    return 'x' * 1024;
  }

  @override
  void operator []=(int index, Object? value) => throw UnimplementedError();
}

void main() {
  test(
    'bounded encoder measures UTF-8 and escaping without traversing huge fan-out',
    () {
      final value = {'v': '中文😀\\\n"'};
      final expected = utf8.encode(jsonEncode(value));
      expect(
        CoreConfigEncoding.encode(value, byteLimit: expected.length),
        expected,
      );
      expect(
        () => CoreConfigEncoding.encode(value, byteLimit: expected.length - 1),
        throwsA(isA<CoreConfigSizeException>()),
      );
      for (final limit in [0, CoreConfigEncoding.maxBytes + 1]) {
        expect(
          () => CoreConfigEncoding.encode(value, byteLimit: limit),
          throwsArgumentError,
        );
      }
      final repeated = _ManyReferences();
      expect(
        () => CoreConfigEncoding.encode(repeated, byteLimit: 128),
        throwsA(isA<CoreConfigSizeException>()),
      );
      expect(repeated.reads, lessThan(10));
    },
  );

  test('bootstrap is immutable including derived buffer views', () async {
    final bootstrap = await SingBoxBootstrap.prepare('{"fixture":true}');
    expect(
      jsonDecode(utf8.decode(bootstrap.bytes))['protocol'],
      'hotaru-bootstrap-v1',
    );
    expect(() => bootstrap.bytes[0] = 0, throwsUnsupportedError);
    expect(
      () => bootstrap.bytes.buffer.asUint8List()[0] = 0,
      throwsUnsupportedError,
    );
    for (final source in ['[]', 'null', '{broken']) {
      await expectLater(
        SingBoxBootstrap.prepare(source),
        throwsFormatException,
      );
    }
  });

  test(
    'bootstrap accounts for the complete envelope at the exact frame boundary',
    () async {
      final overhead = CoreConfigEncoding.encode({
        'protocol': 'hotaru-bootstrap-v1',
        'config': {'v': ''},
      }).length;
      final text = 'a' * (CoreConfigEncoding.maxBytes - overhead);
      final valid = await SingBoxBootstrap.prepare(jsonEncode({'v': text}));
      expect(valid.length, CoreConfigEncoding.maxBytes);
      await expectLater(
        SingBoxBootstrap.prepare(jsonEncode({'v': '${text}a'})),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await expectLater(
        SingBoxBootstrap.prepare('x' * (CoreConfigEncoding.maxBytes + 1)),
        throwsA(isA<CoreConfigSizeException>()),
      );
    },
  );

  test(
    'ready configuration must be explicitly approved and contains matching listeners',
    () async {
      final prep = SingBoxConfigPreparer();
      final result = await prep.prepare(
        import: () async => imported(),
        listeners: listeners,
      );
      expect(result.status, SingBoxPreparationStatus.ready);
      expect(result.issues, isEmpty);
      final candidate = result.candidate!;
      expect(candidate.bootstrapBytes, lessThan(CoreConfigEncoding.maxBytes));
      final accepted = prep.approve(candidate);
      expect(accepted.listeners, same(listeners));
      expect(accepted.profile.finalOutbound, 'direct');
      expect(candidate.nodeCount, 1);
      expect(candidate.ruleCount, 0);
      expect(() => accepted.profile.nodes.clear(), throwsUnsupportedError);
      expect(
        decoded(accepted)['config']['experimental']['clash_api']['secret'],
        listeners.secret,
      );
      expect(
        () => candidate.warnings.add(const CoreConfigIssue('x', 'x')),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'real conversion warnings require acknowledgment for this exact candidate',
    () async {
      final prep = SingBoxConfigPreparer();
      Future<CoreConfigImportResult> source() => ClashProfileImporter().import(
        'mixed-port: 12345\nrules: ["MATCH,DIRECT"]',
      );
      final first = (await prep.prepare(
        import: source,
        listeners: listeners,
      )).candidate!;
      expect(first.warnings.single.code, 'app_owned_setting_replaced');
      expect(() => prep.approve(first), throwsStateError);
      final acknowledgment = prep.acknowledge(first);
      final accepted = prep.approve(first, acknowledgment: acknowledgment);
      final second = (await prep.prepare(
        import: source,
        listeners: listeners,
      )).candidate!;
      expect(
        () => prep.approve(first, acknowledgment: acknowledgment),
        throwsStateError,
      );
      expect(
        () => prep.approve(second, acknowledgment: acknowledgment),
        throwsStateError,
      );
      expect(() => prep.acknowledge(first), throwsStateError);
      expect(
        prep.approve(second, acknowledgment: prep.acknowledge(second)),
        isA<AcceptedSingBoxConfig>(),
      );
      expect(decoded(accepted)['config']['route']['final'], 'DIRECT');
      final other = SingBoxConfigPreparer();
      expect(() => other.approve(second), throwsStateError);
    },
  );

  test('import and build errors cannot yield a reviewable candidate', () async {
    final prep = SingBoxConfigPreparer();
    final invalidImport = await prep.prepare(
      import: () async => imported(
        issues: [const CoreConfigIssue('fixture_error', 'document')],
      ),
      listeners: listeners,
    );
    expect(invalidImport.status, SingBoxPreparationStatus.invalid);
    expect(invalidImport.candidate, isNull);
    expect(invalidImport.issues.single.code, 'fixture_error');
    final missing = await prep.prepare(
      import: () async => CoreConfigImportResult(issues: const []),
      listeners: listeners,
    );
    expect(missing.issues.single.code, 'missing_profile');
    final invalidBuild = await prep.prepare(
      import: () async => CoreConfigImportResult(
        profile: CoreProfileSpec(
          nodes: [],
          selectors: [],
          finalOutbound: 'missing',
        ),
        issues: const [],
      ),
      listeners: listeners,
    );
    expect(invalidBuild.status, SingBoxPreparationStatus.invalid);
    expect(invalidBuild.candidate, isNull);
    expect(
      invalidBuild.issues.map((issue) => issue.code),
      contains('unknown_final_outbound'),
    );
  });

  test(
    'import exceptions are sanitized rather than exposing source credentials',
    () async {
      final result = await SingBoxConfigPreparer().prepare(
        import: () async => throw StateError('fixture-password'),
        listeners: listeners,
      );
      expect(result.status, SingBoxPreparationStatus.invalid);
      expect(result.issues.single.code, 'configuration_preparation_failed');
      expect(result.issues.single.path, 'document');
    },
  );

  test(
    'out-of-order import completion cannot replace the latest review',
    () async {
      final first = Completer<CoreConfigImportResult>();
      final prep = SingBoxConfigPreparer();
      final old = prep.prepare(
        import: () => first.future,
        listeners: listeners,
      );
      final latest = await prep.prepare(
        import: () async => imported(name: 'latest'),
        listeners: listeners,
      );
      first.complete(imported(name: 'old'));
      expect((await old).status, SingBoxPreparationStatus.superseded);
      expect(
        decoded(prep.approve(latest.candidate!))['config']['route']['final'],
        'latest',
      );
    },
  );

  test(
    'cancel and subsequent failure do not mutate an already accepted snapshot',
    () async {
      final prep = SingBoxConfigPreparer();
      final initial = await prep.prepare(
        import: () async => imported(),
        listeners: listeners,
      );
      final accepted = prep.approve(initial.candidate!);
      final waiting = Completer<CoreConfigImportResult>();
      final pending = prep.prepare(
        import: () => waiting.future,
        listeners: listeners,
      );
      expect(() => prep.approve(initial.candidate!), throwsStateError);
      prep.cancel();
      waiting.completeError(StateError('old import failed'));
      final result = await pending;
      expect(result.status, SingBoxPreparationStatus.superseded);
      expect(result.issues, isEmpty);
      expect(decoded(accepted)['config']['route']['final'], 'direct');
    },
  );

  test(
    'preparation isolates do not capture importer native resources',
    () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final result = await SingBoxConfigPreparer().prepare(
        import: () async {
          expect(port.sendPort, isNotNull);
          return imported();
        },
        listeners: listeners,
      );
      expect(result.status, SingBoxPreparationStatus.ready);
    },
  );

  test(
    'large repeated rule targets fail during bounded generation before bootstrap',
    () async {
      final name = 'n' * 32768;
      final spec = CoreProfileSpec(
        nodes: [CoreNodeSpec(tag: name, protocol: CoreNodeProtocol.direct)],
        selectors: [],
        finalOutbound: name,
        dns: CoreDnsSpec(
          servers: const [
            CoreDnsServerSpec(tag: 'dns', protocol: CoreDnsProtocol.local),
          ],
          finalServer: 'dns',
        ),
        rules: List.generate(
          600,
          (i) => CoreRouteRule(
            kind: CoreRuleKind.domain,
            value: 'r$i.invalid',
            outbound: name,
          ),
        ),
      );
      for (final binding in [
        listeners,
        CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
          tun: CoreTunSpec(
            interfaceName: 'HotaruFixture',
            addresses: ['198.18.8.1/30'],
            autoRoute: false,
            hijackDns: true,
          ),
        ),
      ]) {
        final built = await SingBoxConfigBuilder().build(spec, binding);
        expect(built.json, isNull);
        expect(built.issues.single.code, 'compiled_config_too_large');
        final prepared = await SingBoxConfigPreparer().prepare(
          import: () async =>
              CoreConfigImportResult(profile: spec, issues: const []),
          listeners: binding,
        );
        expect(prepared.status, SingBoxPreparationStatus.invalid);
        expect(prepared.candidate, isNull);
        expect(prepared.issues.single.code, 'compiled_config_too_large');
      }
    },
  );

  test(
    'rule-set text fan-out is bounded before allocating its output',
    () async {
      final name = 'n' * 32768;
      final result =
          await ClashSubscriptionImporter(
            resolve: (_) async => throw StateError('Inline only'),
          ).import(
            jsonEncode({
              'proxies': [
                {'name': name, 'type': 'direct'},
              ],
              'rule-providers': {
                'domains': {
                  'type': 'inline',
                  'behavior': 'domain',
                  'payload': List.filled(600, 'exact.invalid'),
                },
              },
              'rules': ['RULE-SET,domains,$name', 'MATCH,DIRECT'],
            }),
          );
      expect(result.profile, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('expanded_rule_size_exceeded'),
      );
    },
  );
}
