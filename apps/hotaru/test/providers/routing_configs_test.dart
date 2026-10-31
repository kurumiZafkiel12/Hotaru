import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

class _RealHttpOverrides extends HttpOverrides {}

class _Setup extends SetupAction {
  final List<bool> applied = [];
  @override
  void build() {}
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    applied.add(ref.read(appSettingProvider).routingRulesEnabled);
    return applied.length > 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ProviderContainer container;
  late _Core core;
  const profile = Profile(
    id: 1,
    label: 'Subscription',
    currentGroupName: 'Selected',
    autoUpdateDuration: Duration.zero,
  );
  final metadata = RoutingConfig(
    id: 101,
    name: 'Independent',
    url: 'https://example.com/rules.yaml',
    updatedAt: DateTime.utc(2026),
    digest: 'test',
    ruleCount: 2,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hotaru_routing_');
    await useAppPaths(directory);
    globalState.packageInfo = PackageInfo(
      appName: 'Hotaru',
      packageName: 'dev.hotaru.hotaru',
      version: '0.0.6',
      buildNumber: '18',
    );
    core = _Core();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
    container.listen(appSettingProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'link import validates with Core, persists rules separately and rejects a bad update',
    () async {
      var source = 'rules: ["DOMAIN-SUFFIX,example.cn,DIRECT", "MATCH,Proxy"]';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.write(source);
        request.response.close();
      });
      final checkedRules = <List<String>>[];
      when(() => core.validateConfig(any())).thenAnswer((invocation) async {
        final document =
            loadYaml(
                  await File(
                    invocation.positionalArguments.single as String,
                  ).readAsString(),
                )
                as YamlMap;
        checkedRules.add(List<String>.from(document['rules'] as List));
        return '';
      });
      final action = container.read(routingConfigsActionProvider.notifier);
      final imported = await HttpOverrides.runWithHttpOverrides(
        () => action.importLink(
          'http://127.0.0.1:${server.port}/rules.yaml',
          name: 'Independent',
        ),
        _RealHttpOverrides(),
      );
      expect(checkedRules.single, [
        'DOMAIN-SUFFIX,example.cn,DIRECT',
        'MATCH,HOTARU-VALIDATE',
      ]);
      expect(container.read(appSettingProvider).routingRulesEnabled, isFalse);
      expect(
        container.read(appSettingProvider).activeRoutingConfigId,
        imported.id,
      );
      final cached = File(
        join(
          await appPath.profilesPath,
          'routing-configs',
          '${imported.id}.yaml',
        ),
      );
      expect(await cached.readAsString(), source);
      final stored = AppSettingProps.fromJson(
        jsonDecode(jsonEncode(container.read(appSettingProvider)))
            as Map<String, dynamic>,
      );
      expect(stored.routingConfigs.single, imported);
      source = 'rules: [bad]';
      await expectLater(action.update(imported), throwsFormatException);
      expect(await cached.readAsString(), isNot(source));
      expect(
        container.read(appSettingProvider).routingConfigs.single,
        imported,
      );
      expect(container.read(routingConfigsActionProvider), isFalse);
    },
  );

  test(
    'failed source switch restores previous routing state and mode through the existing setup owner',
    () async {
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => 1),
          setupActionProvider.overrideWith(_Setup.new),
        ],
      );
      addTearDown(scoped.dispose);
      scoped.listen(appSettingProvider, (_, _) {});
      scoped.read(appSettingProvider.notifier).value = AppSettingProps(
        routingConfigs: [metadata],
        activeRoutingConfigId: metadata.id,
      );
      scoped.read(patchClashConfigProvider.notifier).value =
          const PatchClashConfig(mode: Mode.global);
      await expectLater(
        scoped.read(routingConfigsActionProvider.notifier).useSource(true),
        throwsFormatException,
      );
      expect(scoped.read(appSettingProvider).routingRulesEnabled, isFalse);
      expect(scoped.read(patchClashConfigProvider).mode, Mode.global);
      expect((scoped.read(setupActionProvider.notifier) as _Setup).applied, [
        true,
        false,
      ]);
    },
  );

  test(
    'profile builder uses imported rules exclusively and retains the selected subscription group',
    () async {
      final cached = File(
        join(
          await appPath.profilesPath,
          'routing-configs',
          '${metadata.id}.yaml',
        ),
      );
      await cached.parent.create(recursive: true);
      await cached.writeAsString(
        'rules: ["DOMAIN-SUFFIX,example.cn,DIRECT", "MATCH,Proxy"]',
      );
      when(() => core.getConfig(any())).thenAnswer(
        (_) async => {
          'proxies': [
            {'name': 'Node', 'type': 'direct'},
          ],
          'proxy-groups': [
            {
              'name': 'Selected',
              'type': 'select',
              'proxies': ['Node'],
            },
          ],
          'rules': ['DOMAIN,old-subscription.test,REJECT', 'MATCH,Selected'],
        },
      );
      final built = await container
          .read(setupActionProvider.notifier)
          .getProfile(
            setupState: SetupState(
              profileId: 1,
              profileLastUpdateDate: null,
              profileType: ProfileType.file,
              extendType: ExtendType.standard,
              rules: const [],
              proxyGroups: const [],
              addedRules: [Rule.parse('DOMAIN,old-added.test,REJECT', id: 1)],
              script: null,
              overrides: const ProfileOverrides(),
              routingConfig: metadata,
              routingOutbound: 'Selected',
            ),
            patchConfig: const PatchClashConfig(),
          );
      final result = loadYaml(built.yaml) as YamlMap;
      expect(result['rules'], [
        'DOMAIN-SUFFIX,example.cn,DIRECT',
        'MATCH,Selected',
      ]);
      expect((result['proxies'] as YamlList).single['name'], 'Node');
      expect((result['proxy-groups'] as YamlList).first['name'], 'Selected');
      expect(built.base, isNull);
      expect(built.counts.rules, 2);
      verifyNever(() => core.getProfileBase(any()));
    },
  );
}
