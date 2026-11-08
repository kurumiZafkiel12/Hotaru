import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'config/geodata.dart';

final class CoreGeoDataFiles {
  final String? geoIpPath;
  final String? geoSitePath;

  const CoreGeoDataFiles({this.geoIpPath, this.geoSitePath});

  Future<Map<String, CoreGeoMatchData>> resolve(List<CoreGeoRequest> requests) {
    final paths = {CoreGeoKind.ip: geoIpPath, CoreGeoKind.site: geoSitePath};
    final snapshot = List<CoreGeoRequest>.unmodifiable(requests);
    return Isolate.run(() async {
      if (snapshot.length > 1024) {
        throw const FormatException('geo_request_limit');
      }
      final result = <String, CoreGeoMatchData>{
        for (final request in snapshot)
          request.key: ?builtinCoreGeoMatch(request),
      };
      for (final kind in CoreGeoKind.values) {
        final selected = snapshot
            .where(
              (request) =>
                  request.kind == kind && !result.containsKey(request.key),
            )
            .toList();
        if (selected.isEmpty) continue;
        final path = paths[kind];
        if (path == null) throw const FormatException('geo_data_unavailable');
        final buffer = BytesBuilder(copy: false);
        var size = 0;
        await for (final chunk in File(path).openRead()) {
          size += chunk.length;
          if (size > CoreGeoDecoder.maxBytes) {
            throw const FormatException('geo_data_limit');
          }
          buffer.add(chunk);
        }
        result.addAll(
          CoreGeoDecoder.decodeInWorker(
            bytes: buffer.takeBytes(),
            requests: selected,
          ),
        );
      }
      return Map<String, CoreGeoMatchData>.unmodifiable(result);
    });
  }
}
