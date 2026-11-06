import 'dart:convert';
import 'dart:typed_data';

final class CoreConfigSizeException implements Exception {
  const CoreConfigSizeException();

  @override
  String toString() => 'Compiled configuration exceeds size limit';
}

final class CoreConfigEncoding {
  static const maxBytes = 16 * 1024 * 1024;

  static Uint8List encode(Object? value, {int byteLimit = maxBytes}) {
    if (byteLimit < 1 || byteLimit > maxBytes) {
      throw ArgumentError.value(byteLimit, 'byteLimit');
    }
    final sink = _LimitedBytes(byteLimit);
    final encoder = JsonUtf8Encoder().startChunkedConversion(sink);
    encoder.add(value);
    encoder.close();
    return sink.builder.takeBytes();
  }
}

final class _LimitedBytes implements Sink<List<int>> {
  final int limit;
  final BytesBuilder builder = BytesBuilder();
  int length = 0;

  _LimitedBytes(this.limit);

  @override
  void add(List<int> bytes) {
    if (bytes.length > limit - length) {
      throw const CoreConfigSizeException();
    }
    length += bytes.length;
    builder.add(bytes);
  }

  @override
  void close() {}
}
