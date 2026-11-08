import 'config/profile.dart';
import 'dial_observations.dart';
import 'telemetry.dart';

final class CoreConnectionPath {
  final List<String> hops;
  final bool complete;

  CoreConnectionPath(Iterable<String> hops, {required this.complete})
    : hops = List.unmodifiable(hops);
}

final class CoreConnectionPaths {
  final CoreTelemetrySnapshot sample;
  final Map<String, CoreNodeSpec> _nodes;
  final Map<(String, int, String, String, int), List<CoreDialObservation>>
  _roots = {};
  final Map<int, List<CoreDialObservation>> _calls = {};

  CoreConnectionPaths(this.sample, Iterable<CoreNodeSpec> nodes)
    : _nodes = {for (final node in nodes) node.tag: node} {
    for (final call in sample.dials?.entries ?? <CoreDialObservation>[]) {
      if (call.dns) continue;
      (_calls[call.rootId] ??= []).add(call);
      if (call.id == call.rootId &&
          call.parent.isEmpty &&
          call.sourcePort != 0) {
        (_roots[_key(
                  call.sourceIp,
                  call.sourcePort,
                  call.inbound,
                  call.network,
                  call.destinationPort,
                )] ??=
                [])
            .add(call);
      }
    }
  }

  CoreConnectionPath? resolve(CoreObservedConnection connection) {
    if (sample.dials == null) return null;
    final end = connection.closedAt ?? sample.sampledAt;
    bool inLifetime(CoreDialObservation call) =>
        !call.startedAt.isBefore(connection.createdAt) &&
        !call.startedAt.isAfter(end);
    final roots =
        (_roots[_key(
                  connection.sourceIp,
                  connection.sourcePort,
                  connection.inbound,
                  connection.network,
                  connection.destinationPort,
                )] ??
                [])
            .where(
              (call) =>
                  call.succeeded &&
                  inLifetime(call) &&
                  call.outbound == connection.outbound &&
                  (call.originalDestination.isNotEmpty &&
                          call.originalDestination ==
                              connection.destinationIp ||
                      call.originalDestination.isNotEmpty &&
                          call.originalDestination == connection.host ||
                      call.host.isNotEmpty && call.host == connection.host),
            )
            .toList();
    if (roots.length != 1) {
      return CoreConnectionPath(
        connection.outbound.isEmpty ? [] : [connection.outbound],
        complete: false,
      );
    }
    final root = roots.single;
    final children = <String, Set<String>>{};
    for (final call in _calls[root.id] ?? <CoreDialObservation>[]) {
      if (call.parent.isEmpty || !call.succeeded || !inLifetime(call)) continue;
      (children[call.parent] ??= {}).add(call.outbound);
    }
    final hops = <String>[];
    var tag = root.outbound;
    var complete = false;
    while (!hops.contains(tag)) {
      hops.add(tag);
      final next = children[tag] ?? const <String>{};
      if (next.isEmpty) {
        final node = _nodes[tag];
        complete =
            node != null && node.detour == null ||
            hops.length == 1 && root.outboundType == 'direct';
        break;
      }
      if (next.length != 1) break;
      tag = next.single;
    }
    return CoreConnectionPath(hops.reversed, complete: complete);
  }
}

(String, int, String, String, int) _key(
  String ip,
  int port,
  String inbound,
  String network,
  int destinationPort,
) => (ip, port, inbound, network, destinationPort);
