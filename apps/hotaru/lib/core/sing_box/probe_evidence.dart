import '../../models/models.dart';

typedef ObservedServiceProbe = ({
  ProbeResult result,
  RouteSnapshot snapshot,
  List<RouteHit> hits,
});
typedef ServiceProbeSender =
    Future<ObservedServiceProbe> Function(ProbeParams, Future<void>);
