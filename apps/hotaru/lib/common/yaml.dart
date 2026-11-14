import 'package:hotaru/common/yaml_writer.dart';
import '../core/config/yaml_document.dart';

class Yaml {
  static Yaml? _instance;

  Yaml._internal();

  factory Yaml() {
    _instance ??= Yaml._internal();
    return _instance!;
  }

  String encode(Object? value) {
    return writeYaml(value);
  }
}

final yaml = Yaml();

Object? loadPlainYaml(String content) => decodeCoreYaml(content);
