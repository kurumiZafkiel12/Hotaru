import 'profile.dart';

final class CoreModeOutbounds {
  final CoreNodeSpec direct;
  final CoreSelectorSpec global;

  CoreModeOutbounds(CoreProfileSpec profile)
    : this.fromOutbounds(
        profile.nodes,
        profile.selectors,
        profile.finalOutbound,
      );

  CoreModeOutbounds.fromOutbounds(
    List<CoreNodeSpec> nodes,
    List<CoreSelectorSpec> selectors,
    String finalOutbound,
  ) : this._({
        for (final node in nodes) node.tag,
        for (final group in selectors) group.tag,
      }, finalOutbound);

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
