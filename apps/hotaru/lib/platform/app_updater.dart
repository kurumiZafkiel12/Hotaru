import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'network_client.dart';

class AppUpdate {
  final String tag;
  final Uri download;
  final Uri checksums;
  final String name;
  final int size;
  const AppUpdate(
    this.tag,
    this.download,
    this.checksums,
    this.name,
    this.size,
  );
}

class AppUpdater {
  static const currentTag = String.fromEnvironment(
    'HOTARU_RELEASE_TAG',
    defaultValue: 'v0.4.1-preview.0',
  );
  static List<int> version(String tag) =>
      RegExp(r'\d+').allMatches(tag).map((m) => int.parse(m[0]!)).toList();
  static bool newer(String tag, String current) {
    final a = version(tag), b = version(current);
    for (var i = 0; i < 3; i++) {
      final result = (i < a.length ? a[i] : 0).compareTo(
        i < b.length ? b[i] : 0,
      );
      if (result != 0) return result > 0;
    }
    if (a.length == 3 && b.length > 3) return true;
    if (a.length > 3 && b.length == 3) return false;
    for (var i = 0; i < a.length || i < b.length; i++) {
      final result = (i < a.length ? a[i] : 0).compareTo(
        i < b.length ? b[i] : 0,
      );
      if (result != 0) return result > 0;
    }
    return false;
  }

  static Uri _trusted(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/kurumiZafkiel12/Hotaru/releases/download/')) {
      throw const FormatException('更新地址不可信');
    }
    return uri;
  }

  static Future<AppUpdate?> check({int? proxyPort}) async {
    final client = networkClient(proxyPort: proxyPort);
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.parse(
            'https://api.github.com/repos/kurumiZafkiel12/Hotaru/releases?per_page=20',
          ),
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'Hotaru/0.4.1');
        final response = await request.close();
        if (response.statusCode != 200) throw const HttpException('更新检查失败');
        final releases =
            jsonDecode(await response.transform(utf8.decoder).join()) as List;
        for (final release in releases) {
          final tag = release['tag_name'] as String;
          if (release['draft'] == true ||
              !RegExp(r'^v\d+\.\d+\.\d+(-preview\.\d+)?$').hasMatch(tag) ||
              !newer(tag, currentTag)) {
            continue;
          }
          final assets = (release['assets'] as List).cast<Map>();
          final installer = assets
              .where(
                (a) => (a['name'] as String).endsWith('-windows-x64-setup.exe'),
              )
              .firstOrNull;
          final sums = assets
              .where((a) => a['name'] == 'SHA256SUMS.txt')
              .firstOrNull;
          if (installer != null && sums != null) {
            return AppUpdate(
              tag,
              _trusted(installer['browser_download_url'] as String),
              _trusted(sums['browser_download_url'] as String),
              installer['name'] as String,
              installer['size'] as int,
            );
          }
        }
        return null;
      })().timeout(const Duration(seconds: 25));
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> download(AppUpdate update, {int? proxyPort}) async {
    final client = networkClient(proxyPort: proxyPort);
    final dir = await Directory.systemTemp.createTemp('hotaru-update-');
    final file = File('${dir.path}/setup.exe');
    try {
      return await (() async {
        final sumResponse = await (await client.getUrl(update.checksums))
            .close();
        if (sumResponse.statusCode != 200) {
          throw const HttpException('校验文件下载失败');
        }
        final sumText = await sumResponse.transform(utf8.decoder).join();
        final line = sumText
            .split('\n')
            .map((s) => s.trim().split(RegExp(r'\s+')))
            .where((p) => p.length == 2 && p[1] == update.name)
            .single;
        if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(line[0]) ||
            update.size <= 0 ||
            update.size > 512 * 1024 * 1024) {
          throw const FormatException();
        }
        final response = await (await client.getUrl(update.download)).close();
        if (response.statusCode != 200) throw const HttpException('安装包下载失败');
        var size = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in response) {
            size += chunk.length;
            if (size > update.size) throw const FormatException('安装包大小不匹配');
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (size != update.size ||
            (await sha256.bind(file.openRead()).first).toString() !=
                line[0].toLowerCase()) {
          throw const FormatException('安装包校验失败');
        }
        return file;
      })().timeout(const Duration(minutes: 10));
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
