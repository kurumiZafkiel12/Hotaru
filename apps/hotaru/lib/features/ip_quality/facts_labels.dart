import 'package:hotaru/common/common.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hotaru/ui/ui.dart';

extension IpOriginLabel on IpOrigin {
  String label(BuildContext context) => switch (this) {
    IpOrigin.native => context.appLocalizations.ipFactsNative,
    IpOrigin.broadcast => context.appLocalizations.ipFactsBroadcast,
    IpOrigin.unknown => context.appLocalizations.unknown,
  };
}

extension IpAttributeLabel on IpAttribute {
  String label(BuildContext context) => switch (this) {
    IpAttribute.hosting => context.appLocalizations.ipTypeHosting,
    IpAttribute.residential => context.appLocalizations.ipTypeResidential,
    IpAttribute.mobile => context.appLocalizations.ipTypeMobile,
    IpAttribute.business => context.appLocalizations.ipTypeBusiness,
    IpAttribute.unknown => context.appLocalizations.unknown,
  };
}

extension IpRiskLabel on IpRisk {
  String label(BuildContext context) => switch (this) {
    IpRisk.low => context.appLocalizations.ipFactsLow,
    IpRisk.medium => context.appLocalizations.ipFactsMedium,
    IpRisk.elevated => context.appLocalizations.ipFactsElevated,
    IpRisk.high => context.appLocalizations.ipFactsHigh,
    IpRisk.unknown => context.appLocalizations.unknown,
  };

  Color? color(BuildContext context) => switch (this) {
    IpRisk.low => context.colorScheme.success,
    IpRisk.medium => context.colorScheme.onSurface,
    IpRisk.elevated => context.colorScheme.tertiary,
    IpRisk.high => context.colorScheme.error,
    IpRisk.unknown => null,
  };
}

extension IpFactsLabel on IpFacts {
  String qualityLabel(BuildContext context) => risk == IpRisk.unknown
      ? context.appLocalizations.unknown
      : context.appLocalizations.ipFactsScore(risk.label(context), riskScore!);

  String originEvidence(BuildContext context) =>
      context.appLocalizations.ipFactsOriginEvidence(
        geoCountry ?? context.appLocalizations.unknown,
        registeredCountry ?? context.appLocalizations.unknown,
      );
}
