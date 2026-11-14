import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/core/method.dart';
import 'package:hotaru/core/profile_documents.dart';
import 'package:hotaru/core/spill.dart';
import 'package:hotaru/models/models.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/app_paths.dart';

class _Handler extends Mock implements CoreHandlerInterface {}

class _TextHandler extends Mock
    implements CoreHandlerInterface, CoreProfileTextBuilder {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File profile;
  const source = '''
x-node: &node {type: http, server: 127.0.0.1, port: 8080}
proxies: [{<<: *node, name: A}]
proxy-groups: [{name: selected, type: select, proxies: [A]}]
rules: ['DOMAIN,example.org,selected', ' match ,selected']
sub-rules: {extra: ['MATCH,selected']}
dns: {enable: false}
''';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hotaru-profile-doc-');
    profile = await File('${directory.path}/input.yaml').writeAsString(source);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'summary hashes original bytes and omits bulk sections without writing',
    () async {
      final base = await CoreProfileDocuments.base(profile.path);
      expect(base.digest, sha256.convert(utf8.encode(source)).toString());
      expect((base.proxies, base.proxyGroups, base.rules), (1, 1, 2));
      expect(base.matchRules, [' match ,selected']);
      expect(base.config.keys, unorderedEquals(['x-node', 'dns']));
      expect(await profile.readAsString(), source);
      final nodes = await CoreProfileDocuments.outbounds(profile.path);
      expect(nodes, {
        'proxies': [
          {'name': 'A', 'type': 'http'},
        ],
        'proxy-groups': [
          {'name': 'selected', 'type': 'select'},
        ],
      });
    },
  );

  test(
    'overlay owns settings, original owns nodes and overlay rules precede original rules',
    () async {
      final text = await CoreProfileDocuments.build(
        SetupBase(
          path: profile.path,
          overlay: '''
proxies: [{name: wrong}]
proxy-groups: []
sub-rules: {}
rules: ['DOMAIN,local.test,DIRECT']
dns: {enable: true, nameserver: [system]}
''',
        ),
      );
      final built = jsonDecode(text) as Map;
      expect(built['proxies'].single['name'], 'A');
      expect(built['proxy-groups'].single['name'], 'selected');
      expect(built['sub-rules'], {
        'extra': ['MATCH,selected'],
      });
      expect(built['rules'], [
        'DOMAIN,local.test,DIRECT',
        'DOMAIN,example.org,selected',
        ' match ,selected',
      ]);
      expect(built['dns'], {
        'enable': true,
        'nameserver': ['system'],
      });
      expect(built.containsKey('x-node'), isFalse);
      expect(await profile.readAsString(), source);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'absent source sections keep the overlay while explicit empty sections replace it',
    () async {
      const overlay = '{proxies: [{name: kept}], rules: ["MATCH,DIRECT"]}';
      await profile.writeAsString('{}');
      var result = jsonDecode(
        await CoreProfileDocuments.build(
          SetupBase(path: profile.path, overlay: overlay),
        ),
      );
      expect(result['proxies'].single['name'], 'kept');
      expect(result['rules'], ['MATCH,DIRECT']);
      await profile.writeAsString('{proxies: [], rules: []}');
      result = jsonDecode(
        await CoreProfileDocuments.build(
          SetupBase(path: profile.path, overlay: overlay),
        ),
      );
      expect(result['proxies'], isEmpty);
      expect(result['rules'], ['MATCH,DIRECT']);
    },
  );

  test(
    'non mappings, malformed sections, invalid UTF-8 and encrypted input fail without rewriting',
    () async {
      for (final text in [
        '[A]',
        '{proxies: [1]}',
        '{rules: [1]}',
        'age-encryption.org/v1\nfixture',
        '-----BEGIN AGE ENCRYPTED FILE-----\nfixture',
      ]) {
        await profile.writeAsString(text);
        await expectLater(
          CoreProfileDocuments.base(profile.path),
          throwsFormatException,
        );
        expect(await profile.readAsString(), text);
      }
      await profile.writeAsBytes([0xff, 0xfe]);
      await expectLater(
        CoreProfileDocuments.read(profile.path),
        throwsFormatException,
      );
      await profile.writeAsString('{proxies: [{name: A, type: 5}]}');
      await expectLater(
        CoreProfileDocuments.outbounds(profile.path),
        throwsFormatException,
      );
    },
  );

  test(
    'streamed file reads reject oversized inputs and missing files',
    () async {
      await profile.writeAsBytes(
        List.filled(CoreConfigEncoding.maxBytes + 1, 32),
      );
      await expectLater(
        CoreProfileDocuments.read(profile.path),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await profile.delete();
      await expectLater(
        CoreProfileDocuments.read(profile.path),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'controller keeps native Dart rules and supports the old RPC rule field',
    () async {
      await useAppPaths(directory);
      final path = await appPath.getProfilePath('1');
      final handler = _Handler();
      final controller = CoreController.scoped(handler);
      when(() => handler.getConfig(path)).thenAnswer(
        (_) async => {
          'rules': ['MATCH,DIRECT'],
        },
      );
      expect(await controller.getConfig(1), {
        'rules': ['MATCH,DIRECT'],
      });
      when(() => handler.getConfig(path)).thenAnswer(
        (_) async => {
          'rule': ['MATCH,DIRECT'],
        },
      );
      expect(await controller.getConfig(1), {
        'rules': ['MATCH,DIRECT'],
      });
    },
  );

  test(
    'in-process build returns text without accepting it as a spill path',
    () async {
      final base = SetupBase(path: profile.path, overlay: '{}');
      final handler = _TextHandler();
      final controller = CoreController.scoped(handler);
      when(
        () => handler.buildProfileText(base),
      ).thenAnswer((_) => CoreProfileDocuments.build(base));
      final text = await controller.buildProfile(base);
      expect(jsonDecode(text)['proxies'].single['name'], 'A');
      verifyNever(() => handler.buildProfile(base));
    },
  );

  test(
    'legacy builds still validate their spill directory and delete only the returned spill',
    () async {
      await useAppPaths(directory);
      final base = SetupBase(path: profile.path, overlay: '{}');
      final handler = _Handler();
      final controller = CoreController.scoped(handler);
      when(
        () => handler.buildProfile(base),
      ).thenAnswer((_) async => profile.path);
      await expectLater(
        controller.buildProfile(base),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'spill_error',
          ),
        ),
      );
      expect(await profile.exists(), isTrue);
      final home = await appPath.homeDirPath;
      final responseDirectory = await Directory(
        '$home/$coreSpillDirectoryName',
      ).create(recursive: true);
      final response = await File(
        '${responseDirectory.path}/profile.yaml',
      ).writeAsString(source);
      when(
        () => handler.buildProfile(base),
      ).thenAnswer((_) async => response.path);
      expect(await controller.buildProfile(base), source);
      expect(await response.exists(), isFalse);
      expect(await profile.readAsString(), source);
    },
  );
}
