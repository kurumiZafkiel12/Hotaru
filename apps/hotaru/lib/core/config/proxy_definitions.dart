import 'dart:isolate';

import 'clash_importer.dart';
import 'node_validation.dart';
import 'profile.dart';

final class CoreProxyDefinitions {
  static Future<List<String>> validate(
    List<Map<String, dynamic>> definitions,
  ) => Isolate.run(() async {
    final parsed = await ClashProfileImporter().importNodes(definitions);
    return [
      for (var index = 0; index < parsed.length; index++)
        _message(parsed[index], index),
    ];
  });

  static String _message(CoreNodeImportResult parsed, int index) {
    final path = 'proxies.$index';
    final node = parsed.node;
    final issues = [
      ...parsed.issues,
      if (node != null && node.tag.isEmpty)
        CoreConfigIssue('invalid_node_name', '$path.name'),
      if (node != null) ...validateCoreNodeFields(node, path: path),
    ];
    return issues.map((issue) => '${issue.code} (${issue.path})').join('\n');
  }
}
