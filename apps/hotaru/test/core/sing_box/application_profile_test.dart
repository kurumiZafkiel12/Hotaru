import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/application_settings.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/application_profile.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/enum/enum.dart';

const _source = '''
proxies:
  - {name: A, type: http, server: 127.0.0.1, port: 18080}
  - {name: B, type: http, server: 127.0.0.1, port: 18081}
proxy-groups:
  - {name: group, type: select, proxies: [A, B]}
rules: ["MATCH,group"]
ipv6: true
''';
const _params = SetupParams(
  selectedMap: {'group': 'B', 'Hotaru GLOBAL': 'B'},
  testUrl: 'https://example.com/',
);

void main() {
  late Directory directory;
  late File config;
  late List<List<CoreConfigIssue>> reports;
  late Future<bool> Function(List<CoreConfigIssue>) reviewer;
  late Future<CoreListenerSpec> Function(
    CoreProfileSpec,
    CoreApplicationSettings,
  )
  bind;
  late SingBoxApplicationProfilePreparer preparation;
  var resolutions = 0;
  Future<String> Function(CoreProxyProviderRequest)? resolve;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'hotaru-app-preparation-',
    );
    config = await File('${directory.path}/config.yaml').writeAsString(_source);
    reports = [];
    resolutions = 0;
    resolve = null;
    reviewer = (_) async => true;
    bind = (profile, settings) async => CoreListenerSpec(
      mixedPort: settings.mixedPort,
      controllerPort: 19090,
      secret: 'owned-controller',
      inbound: settings.inbound,
      tun: settings.tun,
      dnsPort: settings.dnsPort,
      dnsGroups: profile.dns?.groups.isNotEmpty == true
          ? CoreDnsGroupListeners({
              for (var i = 0; i < profile.dns!.groups.length; i++)
                profile.dns!.groups[i].tag: 19100 + i,
            })
          : null,
    );
    preparation = SingBoxApplicationProfilePreparer(
      configPath: config.path,
      importer: (settings) => ClashSubscriptionImporter(
        resolve: (request) async {
          resolutions++;
          return resolve == null
              ? throw StateError('Unexpected provider resolution')
              : resolve!(request);
        },
      ),
      listeners: (profile, settings) => bind(profile, settings),
      review: (issues) async {
        reports.add(issues);
        return reviewer(issues);
      },
    );
  });
  tearDown(() async {
    preparation.close();
    await directory.delete(recursive: true);
  });

  UpdateParams patch({int port = 17999, bool tun = false}) => UpdateParams(
    tun: Tun(enable: tun, stack: TunStack.system),
    mixedPort: port,
    allowLan: true,
    findProcessMode: FindProcessMode.always,
    mode: Mode.global,
    logLevel: LogLevel.warning,
    externalController: ExternalControllerStatus.close,
    authentication: ['alice:first:second'],
    skipCertVerify: true,
  );

  test(
    'runtime patches preserve routing data, live selections and private bindings',
    () async {
      final before = (await preparation.prepare(_params, 7))!;
      final updated = (await preparation.update(before, [
        const CoreOutbound(
          name: 'group',
          type: 'Selector',
          members: ['A', 'B'],
          selected: 'A',
        ),
        const CoreOutbound(
          name: 'Hotaru GLOBAL',
          type: 'Selector',
          members: ['A', 'B'],
          selected: 'A',
        ),
      ], patch(tun: true)))!;
      expect(updated.profileId, 7);
      expect(
        updated.profile.nodes.map(
          (node) => (node.tag, node.server, node.port, node.protocol),
        ),
        before.profile.nodes.map(
          (node) => (node.tag, node.server, node.port, node.protocol),
        ),
      );
      expect(
        updated.profile.rules.map(
          (rule) => (rule.kind, rule.value, rule.outbound),
        ),
        before.profile.rules.map(
          (rule) => (rule.kind, rule.value, rule.outbound),
        ),
      );
      expect(updated.profile.selectors.single.selected, 'A');
      expect(updated.listeners.globalSelection, 'A');
      expect(updated.listeners.initialMode, CoreRoutingMode.global);
      expect(updated.listeners.controllerPort, 19090);
      expect(updated.listeners.secret, 'owned-controller');
      expect(updated.listeners.mixedPort, 17999);
      expect(updated.listeners.inbound!.users.single.password, 'first:second');
      expect(updated.listeners.inbound!.listen, '0.0.0.0');
      expect(updated.listeners.tun, isNotNull);
      expect(updated.profile.runtime.findProcess, isTrue);
      expect(updated.profile.runtime.resolveIpv6, isTrue);
      expect(updated.profile.runtime.skipCertVerify, isTrue);
      expect(updated.profile.runtime.logLevel, 'warning');
      expect(await config.readAsString(), _source);
      expect(resolutions, 0);
    },
  );

  test(
    'runtime cancellation and rejected ports leave the accepted profile unchanged',
    () async {
      final before = (await preparation.prepare(_params, 7))!;
      reviewer = (_) async => false;
      expect(
        await preparation.update(
          before,
          [],
          patch().copyWith(tcpConcurrent: true),
        ),
        isNull,
      );
      expect(before.listeners.mixedPort, 7890);
      reviewer = (_) async => true;
      expect(await preparation.update(before, [], patch(port: 0)), isNull);
      expect(reports.last.single.path, 'mixed-port');
      expect(before.profile.runtime.skipCertVerify, isFalse);
    },
  );

  test(
    'a later profile preparation supersedes a pending runtime review',
    () async {
      final before = (await preparation.prepare(_params, 7))!;
      final entered = Completer<void>();
      final response = Completer<bool>();
      reviewer = (_) {
        entered.complete();
        return response.future;
      };
      final pending = preparation.update(
        before,
        [],
        patch().copyWith(tcpConcurrent: true),
      );
      await entered.future;
      reviewer = (_) async => true;
      final newer = await preparation.prepare(_params, 8);
      expect(await pending.timeout(const Duration(seconds: 2)), isNull);
      response.complete(true);
      expect(newer!.profileId, 8);
    },
  );

  test(
    'terminal close releases a blocked runtime review without waiting for a dialog reply',
    () async {
      final before = (await preparation.prepare(_params, 7))!;
      final entered = Completer<void>();
      final response = Completer<bool>();
      reviewer = (_) {
        entered.complete();
        return response.future;
      };
      final pending = preparation.update(
        before,
        [],
        patch().copyWith(tcpConcurrent: true),
      );
      await entered.future;
      preparation.close();
      expect(await pending.timeout(const Duration(seconds: 2)), isNull);
      response.complete(true);
    },
  );

  test(
    'actual source files prepare selected nodes and keep private controls outside source settings',
    () async {
      await config.writeAsString(
        '$_source\nsecret: untrusted-source\nexternal-controller: "0.0.0.0:9090"\n',
      );
      final before = await config.readAsBytes();
      final accepted = (await preparation.prepare(
        _params.copyWith(skipCertVerify: true),
        7,
      ))!;
      expect(accepted.profileId, 7);
      expect(accepted.profile.selectors.single.selected, 'B');
      expect(accepted.listeners.globalSelection, 'B');
      expect(accepted.listeners.secret, 'owned-controller');
      expect(accepted.listeners.controllerPort, 19090);
      expect(accepted.profile.runtime.skipCertVerify, isTrue);
      expect(accepted.applicationData, isA<CoreApplicationSettings>());
      expect(await config.readAsBytes(), before);
      expect(
        reports.single.map((issue) => issue.code),
        contains('app_owned_setting_replaced'),
      );
    },
  );

  test('overlay source is merged without rewriting either file', () async {
    final accepted = await preparation.prepare(
      _params.copyWith(
        base: SetupBase(
          path: config.path,
          overlay:
              'mixed-port: 17999\nipv6: true\nrules: ["DOMAIN,local.example,DIRECT"]',
        ),
      ),
      8,
    );
    expect(accepted!.listeners.mixedPort, 17999);
    expect(accepted.profile.nodes.any((node) => node.tag == 'A'), isTrue);
    expect(accepted.profile.rules.single.value, 'local.example');
    expect(accepted.profile.finalOutbound, 'group');
    expect(await config.readAsString(), _source);
  });

  test('review cancellation never returns an accepted configuration', () async {
    await config.writeAsString('$_source\ntcp-concurrent: true');
    reviewer = (_) async => false;
    expect(await preparation.prepare(_params, 7), isNull);
    expect(
      reports.single.map((issue) => issue.code),
      contains('native_dial_semantics_changed'),
    );
  });

  test(
    'blocking conversion errors cannot be approved by a true review result',
    () async {
      await config.writeAsString('$_source\nredir-port: 1234');
      expect(await preparation.prepare(_params, 7), isNull);
      expect(
        reports.single.any(
          (issue) => issue.severity == CoreConfigIssueSeverity.error,
        ),
        isTrue,
      );
      expect(resolutions, 0);
    },
  );

  test(
    'stale saved node choices fall back to actual source membership',
    () async {
      final accepted = await preparation.prepare(
        _params.copyWith(
          selectedMap: {'group': 'missing', 'Hotaru GLOBAL': 'missing'},
        ),
        7,
      );
      expect(accepted!.profile.selectors.single.selected, isNull);
      expect(accepted.listeners.globalSelection, isNull);
    },
  );

  test(
    'newer preparation invalidates an old open review before activation',
    () async {
      await config.writeAsString('$_source\ntcp-concurrent: true');
      final entered = Completer<void>();
      final answer = Completer<bool>();
      reviewer = (_) {
        entered.complete();
        return answer.future;
      };
      final old = preparation.prepare(_params, 7);
      await entered.future;
      await config.writeAsString(_source);
      final newer = await preparation.prepare(_params, 8);
      expect(newer!.profileId, 8);
      answer.complete(true);
      expect(await old, isNull);
    },
  );

  test(
    'closing while a review is open prevents late acceptance and is terminal',
    () async {
      await config.writeAsString('$_source\ntcp-concurrent: true');
      final entered = Completer<void>();
      final answer = Completer<bool>();
      reviewer = (_) {
        entered.complete();
        return answer.future;
      };
      final pending = preparation.prepare(_params, 7);
      await entered.future;
      preparation.close();
      answer.complete(true);
      expect(await pending, isNull);
      await expectLater(preparation.prepare(_params, 8), throwsStateError);
    },
  );

  test(
    'late provider responses do not open a review or bind listeners for superseded profiles',
    () async {
      await config.writeAsString('''
proxy-providers:
  remote: {type: http, url: https://example.com/provider}
proxy-groups:
  - {name: group, type: select, use: [remote]}
rules: ["MATCH,group"]
ipv6: true
''');
      final entered = Completer<void>();
      final payload = Completer<String>();
      resolve = (_) {
        entered.complete();
        return payload.future;
      };
      var bindings = 0;
      final oldBind = bind;
      bind = (profile, settings) {
        bindings++;
        return oldBind(profile, settings);
      };
      final old = preparation.prepare(_params, 7);
      await entered.future;
      await config.writeAsString(_source);
      expect((await preparation.prepare(_params, 8))!.profileId, 8);
      payload.complete(
        'proxies: [{name: remote-node, type: http, server: 127.0.0.1, port: 18082}]',
      );
      expect(await old, isNull);
      expect(bindings, 1);
      expect(reports, isEmpty);
    },
  );

  test(
    'invalid native listener binding is reviewed and never accepted',
    () async {
      bind = (_, settings) async => const CoreListenerSpec(
        mixedPort: 19090,
        controllerPort: 19090,
        secret: 'owned',
      );
      expect(await preparation.prepare(_params, 7), isNull);
      expect(
        reports.single.map((issue) => issue.code),
        contains('invalid_listener_ports'),
      );
    },
  );

  test(
    'review failures propagate once without a second misleading report',
    () async {
      await config.writeAsString('$_source\ntcp-concurrent: true');
      reviewer = (_) => throw StateError('Review unavailable');
      await expectLater(preparation.prepare(_params, 7), throwsStateError);
      expect(reports, hasLength(1));
    },
  );

  test(
    'missing files and negative profile identity fail without leaking source text',
    () async {
      await config.delete();
      expect(await preparation.prepare(_params, 7), isNull);
      expect(reports.single.single.code, 'configuration_preparation_failed');
      reports.clear();
      expect(await preparation.prepare(_params, -1), isNull);
      expect(reports.single.single.code, 'invalid_profile_identity');
      expect(
        jsonEncode(reports.single.map((issue) => issue.code).toList()),
        isNot(contains(directory.path)),
      );
    },
  );
}
