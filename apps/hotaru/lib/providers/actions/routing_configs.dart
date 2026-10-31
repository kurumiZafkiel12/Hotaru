part of '../action.dart';

Future<File> _routingConfigFile(int id) async =>
    File(join(await appPath.profilesPath, 'routing-configs', '$id.yaml'));

@Riverpod(keepAlive: true)
class RoutingConfigsAction extends _$RoutingConfigsAction {
  @override
  bool build() => false;

  Future<T> _run<T>(Future<T> Function() operation) async {
    if (state) throw StateError('routing operation in progress');
    state = true;
    try {
      return await operation();
    } finally {
      if (ref.mounted) state = false;
    }
  }

  Future<RoutingConfig> importLink(
    String url, {
    String name = '',
  }) => _run(() async {
    final (source, rules) = await _download(url);
    final config = RoutingConfig(
      id: snowflake.id,
      name: name.trim().isEmpty ? Uri.parse(url).host : name.trim(),
      url: url,
      updatedAt: DateTime.now(),
      digest: source.toMd5(),
      ruleCount: rules.rules.length,
    );
    await (await _routingConfigFile(config.id)).writeAsStringAtomically(source);
    ref
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            routingConfigs: [...settings.routingConfigs, config],
            activeRoutingConfigId: settings.activeRoutingConfigId ?? config.id,
          ),
        );
    return config;
  });

  Future<(String, RoutingRules)> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('invalid configuration URL');
    }
    final response = await request.getTextResponseForUrl(url);
    final source = response.data;
    if (source == null) {
      throw const FormatException('empty routing configuration');
    }
    final rules = await compute(RoutingRules.parse, source);
    final validation = rules.apply({
      'proxy-groups': [
        {
          'name': 'HOTARU-VALIDATE',
          'type': 'select',
          'proxies': ['DIRECT'],
        },
      ],
    }, 'HOTARU-VALIDATE');
    final message = await ref
        .read(coreHandlerProvider)
        .validateConfigWithData(utf8.encode(await encodeYamlTask(validation)));
    if (message.isNotEmpty) throw FormatException(message);
    return (source, rules);
  }

  Future<void> update(RoutingConfig config) => _run(() async {
    final (source, rules) = await _download(config.url);
    final file = await _routingConfigFile(config.id);
    final oldSource = await file.readAsString();
    final updated = config.copyWith(
      updatedAt: DateTime.now(),
      digest: source.toMd5(),
      ruleCount: rules.rules.length,
    );
    await file.writeAsStringAtomically(source);
    void replace(RoutingConfig value) => ref
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            routingConfigs: [
              for (final item in settings.routingConfigs)
                item.id == value.id ? value : item,
            ],
          ),
        );
    replace(updated);
    try {
      final settings = ref.read(appSettingProvider);
      if (settings.routingRulesEnabled &&
          settings.activeRoutingConfigId == config.id) {
        await _applySource(true);
      }
    } catch (_) {
      await file.writeAsStringAtomically(oldSource);
      replace(config);
      await ref.read(setupActionProvider.notifier).applyProfile(force: true);
      rethrow;
    }
  });

  void followSelection(String groupName, String proxyName) {
    final settings = ref.read(appSettingProvider);
    final target = groupName == GroupName.GLOBAL.name ? proxyName : groupName;
    final profileId = ref.read(currentProfileIdProvider);
    if (!settings.routingRulesEnabled ||
        (settings.routingSubscriptionId == profileId &&
            settings.routingOutbound == target)) {
      return;
    }
    ref
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            routingSubscriptionId: profileId,
            routingOutbound: target,
          ),
        );
    ref
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(silence: true, force: true);
  }

  Future<void> select(int id) => _run(() async {
    final settings = ref.read(appSettingProvider);
    if (!settings.routingConfigs.any((config) => config.id == id)) {
      throw const FormatException('routing configuration missing');
    }
    if (settings.routingRulesEnabled) {
      await _applySource(true, id: id);
    } else {
      ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(activeRoutingConfigId: id));
    }
  });

  Future<void> useSource(bool enabled) => _run(() => _applySource(enabled));

  Future<void> _applySource(bool enabled, {int? id}) async {
    final previous = ref.read(appSettingProvider);
    final selected = id ?? previous.activeRoutingConfigId;
    if (enabled &&
        !previous.routingConfigs.any((config) => config.id == selected)) {
      throw const FormatException('routing configuration missing');
    }
    final profile = ref.read(currentProfileProvider);
    if (enabled && profile == null) {
      throw const FormatException('node subscription missing');
    }
    final oldMode = ref.read(patchClashConfigProvider).mode;
    final setup = ref.read(setupActionProvider.notifier);
    ref
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            activeRoutingConfigId: selected,
            routingRulesEnabled: enabled,
            routingSubscriptionId: profile?.id,
            routingOutbound: profile?.currentGroupName ?? '',
          ),
        );
    setup.changeMode(Mode.rule);
    (Object, StackTrace)? failure;
    try {
      if (profile == null || await setup.applyProfile(force: true)) return;
    } catch (error, stack) {
      failure = (error, stack);
    }
    final current = ref.read(appSettingProvider);
    if (current.activeRoutingConfigId == selected &&
        current.routingRulesEnabled == enabled) {
      ref
          .read(appSettingProvider.notifier)
          .update(
            (settings) => settings.copyWith(
              activeRoutingConfigId: previous.activeRoutingConfigId,
              routingRulesEnabled: previous.routingRulesEnabled,
              routingSubscriptionId: previous.routingSubscriptionId,
              routingOutbound: previous.routingOutbound,
            ),
          );
      if (ref.read(patchClashConfigProvider).mode == Mode.rule) {
        setup.changeMode(oldMode);
      }
      await setup.applyProfile(force: true);
    }
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
    throw const FormatException('routing configuration could not be applied');
  }

  Future<void> remove(RoutingConfig config) => _run(() async {
    final settings = ref.read(appSettingProvider);
    if (settings.activeRoutingConfigId == config.id &&
        settings.routingRulesEnabled) {
      await _applySource(false);
    }
    ref
        .read(appSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            routingConfigs: settings.routingConfigs
                .where((item) => item.id != config.id)
                .toList(),
            activeRoutingConfigId: settings.activeRoutingConfigId == config.id
                ? null
                : settings.activeRoutingConfigId,
          ),
        );
    final file = await _routingConfigFile(config.id);
    if (await file.exists()) await file.delete();
  });
}
