import 'profile.dart';

final class CoreModeOutbounds {
  final CoreNodeSpec direct;
  final CoreSelectorSpec global;

  CoreModeOutbounds(CoreProfileSpec profile)
    : this._({
        for (final node in profile.nodes) node.tag,
        for (final group in profile.selectors) group.tag,
      }, profile.finalOutbound);

  CoreModeOutbounds._(Set<String> tags, String finalOutbound)
    : direct = CoreNodeSpec(
        tag: _unused(tags, 'Hotaru DIRECT'),
        protocol: CoreNodeProtocol.direct,
      ),
      global = CoreSelectorSpec(
        tag: _unused(tags, 'Hotaru GLOBAL'),
        members: tags.toList(),
        selected: finalOutbound,
      );

  static String _unused(Set<String> tags, String base) {
    var tag = base;
    var suffix = 0;
    while (tags.contains(tag)) {
      tag = '$base (${++suffix})';
    }
    return tag;
  }
}
