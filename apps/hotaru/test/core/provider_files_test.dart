import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/application_settings.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/provider_files.dart';
import 'package:hotaru/core/sing_box/application_profile.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/models/core.dart';

void main() {
  late Directory directory;
  late Directory root;
  late File provider;
  late File outside;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'hotaru-provider-grants-',
    );
    root = await Directory('${directory.path}/profiles').create();
    provider = await File('${root.path}/nodes.yaml').writeAsString(
      'proxies: [{name: permitted, type: http, server: 127.0.0.1, port: 18080}]',
    );
    outside = await File(
      '${directory.path}/outside.yaml',
    ).writeAsString('private-content');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'file read authority requires an explicit token and a canonical file inside the owned root',
    () async {
      final access = await CoreProviderFileAccess.authorize(
        root: root.path,
        files: {'hotaru-files/nodes': provider.path},
      );
      expect(access.paths, {'hotaru-files/nodes': provider.path});
      expect(
        await access.read(
          'hotaru-files/nodes',
          maxBytes: 1024,
          timeout: const Duration(seconds: 2),
        ),
        await provider.readAsString(),
      );
      for (final token in [
        provider.path,
        outside.path,
        '../outside.yaml',
        'hotaru-files/unknown',
      ]) {
        await expectLater(
          access.read(
            token,
            maxBytes: 1024,
            timeout: const Duration(seconds: 2),
          ),
          throwsFormatException,
        );
      }
      expect(() => access.paths.clear(), throwsUnsupportedError);
    },
  );

  test(
    'outside files, directories, duplicate aliases and unsafe tokens cannot be granted',
    () async {
      for (final files in [
        {'hotaru-files/outside': outside.path},
        {'hotaru-files/dir': root.path},
        {'../unsafe': provider.path},
        {'hotaru-files/one': provider.path, 'hotaru-files/two': provider.path},
      ]) {
        await expectLater(
          CoreProviderFileAccess.authorize(root: root.path, files: files),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'oversized and non-UTF8 payloads fail before returning provider text',
    () async {
      final access = await CoreProviderFileAccess.authorize(
        root: root.path,
        files: {'hotaru-files/nodes': provider.path},
      );
      await expectLater(
        access.read(
          'hotaru-files/nodes',
          maxBytes: 1,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await provider.writeAsBytes([255, 254, 253]);
      await expectLater(
        access.read(
          'hotaru-files/nodes',
          maxBytes: 1024,
          timeout: const Duration(seconds: 2),
        ),
        throwsFormatException,
      );
      expect(
        () => access.read(
          'hotaru-files/nodes',
          maxBytes: 0,
          timeout: const Duration(seconds: 2),
        ),
        throwsArgumentError,
      );
      expect(
        () => access.read(
          'hotaru-files/nodes',
          maxBytes: 1024,
          timeout: Duration.zero,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'symlinks outside the root and aliases changed after approval do not expose their target',
    () async {
      final link = Link('${root.path}/alias.yaml');
      await link.create(outside.path);
      await expectLater(
        CoreProviderFileAccess.authorize(
          root: root.path,
          files: {'hotaru-files/link': link.path},
        ),
        throwsFormatException,
      );
      final access = await CoreProviderFileAccess.authorize(
        root: root.path,
        files: {'hotaru-files/nodes': provider.path},
      );
      await provider.delete();
      await Link(provider.path).create(outside.path);
      await expectLater(
        access.read(
          'hotaru-files/nodes',
          maxBytes: 1024,
          timeout: const Duration(seconds: 2),
        ),
        throwsFormatException,
      );
    },
    skip: Platform.isWindows
        ? 'Creating test symlinks requires Windows developer mode or administrator rights'
        : false,
  );

  test(
    'application source paths turn into explicit grants without relaxing the generic parser',
    () async {
      final access = await CoreProviderFileAccess.authorize(
        root: root.path,
        files: {'hotaru-files/nodes': provider.path},
      );
      final source = jsonEncode({
        'ipv6': true,
        'proxy-providers': {
          'local': {'type': 'file', 'path': provider.path},
        },
        'proxy-groups': [
          {
            'name': 'selected',
            'type': 'select',
            'use': ['local'],
          },
        ],
        'rules': ['MATCH,selected'],
      });
      var reads = 0;
      final importer = ClashSubscriptionImporter(
        resolve: (request) async {
          reads++;
          return access.read(
            request.path!,
            maxBytes: request.maxBytes,
            timeout: request.timeout,
          );
        },
      );
      expect((await importer.import(source)).profile, isNull);
      expect(reads, 0);
      final projected = await CoreApplicationSettings.parse(
        source,
        skipCertVerify: false,
        authorizedProviderFiles: access.paths,
      );
      expect(
        jsonDecode(
          projected.settings!.source,
        )['proxy-providers']['local']['path'],
        'hotaru-files/nodes',
      );
      final accepted = await importer.import(projected.settings!.source);
      expect(
        accepted.profile!.nodes.any((node) => node.tag == 'permitted'),
        isTrue,
      );
      expect(reads, 1);
      expect(
        () => projected.settings!.providerFiles.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'file-backed UI preparation consumes the granted payload and leaves source files untouched',
    () async {
      final access = await CoreProviderFileAccess.authorize(
        root: root.path,
        files: {'hotaru-files/nodes': provider.path},
      );
      final config = await File('${root.path}/application.yaml').writeAsString(
        jsonEncode({
          'ipv6': true,
          'proxy-providers': {
            'local': {'type': 'file', 'path': provider.path},
          },
          'proxy-groups': [
            {
              'name': 'selected',
              'type': 'select',
              'use': ['local'],
            },
          ],
          'rules': ['MATCH,selected'],
        }),
      );
      final before = await config.readAsBytes();
      final preparer = SingBoxApplicationProfilePreparer(
        configPath: config.path,
        providerFiles: access.paths,
        importer: (_) => ClashSubscriptionImporter(
          resolve: (request) => access.read(
            request.path!,
            maxBytes: request.maxBytes,
            timeout: request.timeout,
          ),
        ),
        listeners: (profile, settings) async => CoreListenerSpec(
          mixedPort: settings.mixedPort,
          controllerPort: 19090,
          secret: 'owned',
        ),
        review: (_) async => true,
      );
      try {
        final accepted = await preparer.prepare(
          const SetupParams(selectedMap: {}, testUrl: 'https://example.com/'),
          7,
        );
        expect(accepted!.profileId, 7);
        expect(accepted.profile.selectors.single.members, ['permitted']);
        expect(await config.readAsBytes(), before);
        expect(await provider.readAsString(), contains('permitted'));
      } finally {
        preparer.close();
      }
    },
  );

  test(
    'HTTP provider cache filenames are ignored with a warning and cannot grant local file reads',
    () async {
      final projected = await CoreApplicationSettings.parse(
        jsonEncode({
          'proxy-providers': {
            'remote': {
              'type': 'http',
              'url': 'https://example.com/nodes',
              'path': outside.path,
            },
          },
          'rule-providers': {
            'remote': {
              'type': 'http',
              'url': 'https://example.com/rules',
              'behavior': 'domain',
              'path': outside.path,
            },
          },
        }),
        skipCertVerify: false,
      );
      final document = jsonDecode(projected.settings!.source) as Map;
      expect(document['proxy-providers']['remote'], isNot(contains('path')));
      expect(document['rule-providers']['remote'], isNot(contains('path')));
      expect(projected.settings!.providerFiles, isEmpty);
      expect(
        projected.issues.where(
          (issue) => issue.code == 'provider_cache_path_client_owned',
        ),
        hasLength(2),
      );
      expect(await outside.readAsString(), 'private-content');
    },
  );
}
