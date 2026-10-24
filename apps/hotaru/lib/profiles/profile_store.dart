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

  StoredProfile({
    required this.id,
    required this.name,
    required this.mode,
    required this.source,
    required this.createdAt,
    required this.config,
  });

  List<Map<String, dynamic>> get nodes => [
    for (final p in (config['proxies'] as List? ?? const []))
      if (p is Map<String, dynamic>) p,
  ];

  List<String> get nodeNames => [for (final n in nodes) n['name'] as String];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'config': config,
  };

  factory StoredProfile.fromJson(Map<String, dynamic> json) {
    final config = json['config'];
    if (json['id'] is! String ||
        json['name'] is! String ||
        config is! Map<String, dynamic> ||
        (config['proxies'] is! List) ||
        (config['proxies'] as List).isEmpty) {
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
          selNode is String &&
          store.byId(selId)!.nodeNames.contains(selNode)) {
        store.selectedProfileId = selId;
        store.selectedNode = selNode;
      } else if (store.profiles.isNotEmpty) {
        // Keep a usable default selection rather than none at all.
        store.selectedProfileId = store.profiles.first.id;
        store.selectedNode = store.profiles.first.nodeNames.first;
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
  }) async {
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    final profile = StoredProfile(
      id: '${DateTime.now().microsecondsSinceEpoch}-$random',
      name: name.trim().isEmpty ? '未命名订阅' : name.trim(),
      mode: mode,
      source: source,
      createdAt: DateTime.now(),
      config: config,
    );
    profiles.add(profile);
    selectedProfileId = profile.id;
    selectedNode = profile.nodeNames.first;
    await save();
    return profile;
  }

  Future<void> remove(String id) async {
    profiles.removeWhere((p) => p.id == id);
    if (selectedProfileId == id) {
      selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
      selectedNode = profiles.isEmpty ? null : profiles.first.nodeNames.first;
    }
    await save();
  }

  Future<void> select(String profileId, String nodeName) async {
    final profile = byId(profileId);
    if (profile == null || !profile.nodeNames.contains(nodeName)) {
      throw ArgumentError('Unknown profile or node');
    }
    selectedProfileId = profileId;
    selectedNode = nodeName;
    await save();
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'profiles': [for (final p in profiles) p.toJson()],
    'selectedProfileId': selectedProfileId,
    'selectedNode': selectedNode,
  };

  Future<void> save() => writeJsonAtomically(file, toJson());
}
