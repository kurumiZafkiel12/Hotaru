import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../config/encoding.dart';

final class SingBoxBootstrap {
  final Uint8List _bytes;

  SingBoxBootstrap._(Uint8List bytes) : _bytes = bytes.asUnmodifiableView();

  Uint8List get bytes => _bytes;
  int get length => _bytes.length;

  static Future<SingBoxBootstrap> prepare(String configuration) =>
      Isolate.run(() {
        if (configuration.length > CoreConfigEncoding.maxBytes) {
          throw const CoreConfigSizeException();
        }
        final decoded = jsonDecode(configuration);
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        return SingBoxBootstrap._(
          CoreConfigEncoding.encode({
            'protocol': 'hotaru-bootstrap-v1',
            'config': decoded,
          }),
        );
      });
}
