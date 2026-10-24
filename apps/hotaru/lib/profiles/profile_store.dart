import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../storage/atomic_file.dart';
import 'importer.dart';

/// A saved subscription / node collection. [config] is the parsed Mihomo
/// config exactly as imported (raw import and user selection stay separate:
/// selection lives on the store, not inside the config).
class StoredProfile {
  final String id;
  final String name;
  final ImportMode mode;
  final String source; // 'paste' | 'url'
  final DateTime createdAt;
  final Map<String, dynamic> config;
  final String? sourceUrl;
  final DateTime? updatedAt;
  final int updateHours;
  final String? userInfo;
  final Map<String, dynamic> merge;
  final String script;

  StoredProfile({
    required this.id,
    required this.name,
    required this.mode,
    required this.source,
    required this.createdAt,
    required this.config,
    this.sourceUrl,
    this.updatedAt,
    this.updateHours = 24,
    this.userInfo,
    this.merge = const {},
    this.script = '',
  });

  List<Map<String, dynamic>> get nodes => [
    for (final p in (config['proxies'] as List? ?? const []))
      if (p is Map<String, dynamic>) p,
  ];

  List<String> get nodeNames => [for (final n in nodes) n['name'] as String];
  int get providerCount => (config['proxy-providers'] as Map?)?.length ?? 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'config': config,
    'sourceUrl': sourceUrl,
    'updatedAt': updatedAt?.toIso8601String(),
    'updateHours': updateHours,
    'userInfo': userInfo,
    'merge': merge,
    'script': script,
  };

  factory StoredProfile.fromJson(Map<String, dynamic> json) {
    final config = json['config'];
    if (json['id'] is! String ||
        json['name'] is! String ||
        config is! Map<String, dynamic> ||
        !((config['proxies'] is List &&
                (config['proxies'] as List).isNotEmpty) ||
            (config['proxy-providers'] is Map &&
                (config['proxy-providers'] as Map).isNotEmpty))) {
      throw const FormatException('Invalid stored profile');
    }
    return StoredProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      mode: json['mode'] == 'fullConfig'
          ? ImportMode.fullConfig
          : ImportMode.nodesOnly,
      source: json['source'] as String? ?? 'paste',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      config: config,
      sourceUrl: json['sourceUrl'] as String?,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      updateHours: (json['updateHours'] as int? ?? 24).clamp(0, 720),
      userInfo: json['userInfo'] as String?,
      merge: json['merge'] as Map<String, dynamic>? ?? {},
      script: json['script'] as String? ?? '',
    );
  }
}

/// Persistent store for saved profiles plus the user's current selection.
///
/// Failure rule: a failed import never touches this store, and a failed
/// write leaves the previous file intact (atomic replace), so the user
/// always keeps their last working profile list.
class ProfileStore {
  final File file;
  final List<StoredProfile> profiles;
  String? selectedProfileId;
  String? selectedNode;
  bool loadWarning = false;
  Future<void> _writes = Future.value();

  Future<T> _change<T>(T Function() action) {
    final next = _writes.then<T>((_) async {
      final before = jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>;
      try {
        final value = action();
        await save();
        return value;
      } catch (_) {
        profiles
          ..clear()
          ..addAll(
            (before['profiles'] as List).map(
              (p) => StoredProfile.fromJson(p as Map<String, dynamic>),
            ),
          );
        selectedProfileId = before['selectedProfileId'] as String?;
        selectedNode = before['selectedNode'] as String?;
        rethrow;
      }
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  ProfileStore(
    this.file, {
    List<StoredProfile>? profiles,
    this.selectedProfileId,
    this.selectedNode,
  }) : profiles = profiles ?? [];

  static File? defaultFile() => userDataFile('profiles-v1.json');

  static Future<ProfileStore> load(File file) async {
    final store = ProfileStore(file);
    try {
      if (!await file.exists()) return store;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['profiles'] is! List ||
          decoded['version'] != 1) {
        throw const FormatException('Unknown profile store format');
      }
      for (final entry in decoded['profiles'] as List) {
        if (entry is Map<String, dynamic>) {
          store.profiles.add(StoredProfile.fromJson(entry));
        }
      }
      final selId = decoded['selectedProfileId'];
      final selNode = decoded['selectedNode'];
      if (selId is String &&
          store.profiles.any((p) => p.id == selId) &&
          (selNode == null || selNode is String)) {
        store.selectedProfileId = selId;
        store.selectedNode = selNode;
      } else if (store.profiles.isNotEmpty) {
        // Keep a usable default selection rather than none at all.
        store.selectedProfileId = store.profiles.first.id;
        store.selectedNode = store.profiles.first.nodeNames.firstOrNull;
      }
    } catch (_) {
      store.profiles.clear();
      store.selectedProfileId = null;
      store.selectedNode = null;
      store.loadWarning = true;
    }
    return store;
  }

  StoredProfile? byId(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  StoredProfile? get selectedProfile =>
      selectedProfileId == null ? null : byId(selectedProfileId!);

  Future<StoredProfile> add({
    required String name,
    required ImportMode mode,
    required String source,
    required Map<String, dynamic> config,
    String? sourceUrl,
    String? userInfo,
  }) => _change(() {
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    final profile = StoredProfile(
      id: '${DateTime.now().microsecondsSinceEpoch}-$random',
      name: name.trim().isEmpty ? '未命名订阅' : name.trim(),
      mode: mode,
      source: source,
      createdAt: DateTime.now(),
      config: config,
      sourceUrl: sourceUrl,
      userInfo: userInfo,
      updatedAt: DateTime.now(),
    );
    profiles.add(profile);
    selectedProfileId = profile.id;
    selectedNode = profile.nodeNames.firstOrNull;
    return profile;
  });

  Future<void> remove(String id) => _change<void>(() {
    profiles.removeWhere((p) => p.id == id);
    if (selectedProfileId == id) {
      selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
      selectedNode = profiles.isEmpty
          ? null
          : profiles.first.nodeNames.firstOrNull;
    }
  });

  Future<void> select(String profileId, String nodeName) => _change<void>(() {
    final profile = byId(profileId);
    if (profile == null ||
        (nodeName.isNotEmpty && !profile.nodeNames.contains(nodeName))) {
      throw ArgumentError('Unknown profile or node');
    }
    selectedProfileId = profileId;
    selectedNode = nodeName;
  });

  Future<void> replace(StoredProfile profile) => _change<void>(() {
    final i = profiles.indexWhere((p) => p.id == profile.id);
    if (i < 0) throw ArgumentError('Unknown profile');
    profiles[i] = profile;
    if (selectedProfileId == profile.id &&
        !profile.nodeNames.contains(selectedNode)) {
      selectedNode = profile.nodeNames.firstOrNull;
    }
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'profiles': [for (final p in profiles) p.toJson()],
    'selectedProfileId': selectedProfileId,
    'selectedNode': selectedNode,
  };

  Future<void> save() => writeJsonAtomically(file, toJson());
}
