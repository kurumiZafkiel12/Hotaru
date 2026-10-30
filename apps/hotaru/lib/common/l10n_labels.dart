import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/ui/color.dart';
import 'package:material_ui/material_ui.dart';

import 'app_localizations.dart';
import 'network_diagnostics.dart';
import 'network_quality.dart';
import 'service_probe.dart';

extension PageLabelL10n on PageLabel {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      PageLabel.dashboard => appLocalizations.dashboard,
      PageLabel.proxies => appLocalizations.proxies,
      PageLabel.profiles => appLocalizations.profiles,
      PageLabel.tools => appLocalizations.tools,
      PageLabel.settings => appLocalizations.settings,
      PageLabel.logs => appLocalizations.logs,
      PageLabel.requests => appLocalizations.recentRequests,
      PageLabel.resources => appLocalizations.resources,
      PageLabel.connections => appLocalizations.liveConnections,
      PageLabel.dns => appLocalizations.dnsQueries,
    };
  }
}

extension DnsQueryInitiatorL10n on DnsQueryInitiator {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      DnsQueryInitiator.app => appLocalizations.app,
      DnsQueryInitiator.rule => appLocalizations.rule,
      DnsQueryInitiator.direct => appLocalizations.direct,
      DnsQueryInitiator.proxy => appLocalizations.proxies,
      DnsQueryInitiator.other => appLocalizations.other,
    };
  }
}

extension ModeL10n on Mode {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      Mode.rule => appLocalizations.rule,
      Mode.global => appLocalizations.global,
      Mode.direct => appLocalizations.direct,
    };
  }
}

extension ProxiesTypeL10n on ProxiesType {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      ProxiesType.tab => appLocalizations.tab,
      ProxiesType.list => appLocalizations.list,
    };
  }
}

extension ProxyCardTypeL10n on ProxyCardType {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      ProxyCardType.loose => appLocalizations.loose,
      ProxyCardType.standard => appLocalizations.standard,
      ProxyCardType.compact => appLocalizations.compact,
    };
  }
}

extension HotActionL10n on HotAction {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      HotAction.start => appLocalizations.actionStart,
      HotAction.view => appLocalizations.actionView,
      HotAction.mode => appLocalizations.actionMode,
      HotAction.proxy => appLocalizations.actionProxy,
      HotAction.tun => appLocalizations.actionTun,
      HotAction.ruleMode => appLocalizations.actionRuleMode,
      HotAction.globalMode => appLocalizations.actionGlobalMode,
      HotAction.directMode => appLocalizations.actionDirectMode,
      HotAction.delayTest => appLocalizations.actionDelayTest,
      HotAction.updateProfiles => appLocalizations.actionUpdateProfiles,
      HotAction.copyEnv => appLocalizations.copyEnvVar,
      HotAction.exit => appLocalizations.exit,
    };
  }
}

extension RestoreStrategyL10n on RestoreStrategy {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      RestoreStrategy.compatible => appLocalizations.restoreStrategyCompatible,
      RestoreStrategy.override => appLocalizations.restoreStrategyOverride,
    };
  }
}

extension ColorStyleL10n on ColorStyle {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (this) {
      ColorStyle.vivid => appLocalizations.vividStyle,
      ColorStyle.tinted => appLocalizations.tintedStyle,
      ColorStyle.soft => appLocalizations.softStyle,
      ColorStyle.monochrome => appLocalizations.monochromeScheme,
    };
  }
}

extension LocaleL10n on Locale {
  String get label {
    final appLocalizations = currentAppLocalizations;
    return switch (toString()) {
      'en' => appLocalizations.en,
      'es' => appLocalizations.es,
      'fr' => appLocalizations.fr,
      'ja' => appLocalizations.ja,
      'ko' => appLocalizations.ko,
      'ru' => appLocalizations.ru,
      'zh_CN' => appLocalizations.zhCN,
      final code => code,
    };
  }
}

extension DiagnosticVerdictL10n on DiagnosticVerdict {
  String get label {
    final l10n = currentAppLocalizations;
    return switch (this) {
      DiagnosticVerdict.notTested => l10n.servicePending,
      DiagnosticVerdict.running => l10n.loading,
      DiagnosticVerdict.matching => l10n.diagnosticsNoMismatch,
      DiagnosticVerdict.risk => l10n.diagnosticsRisk,
      DiagnosticVerdict.inconclusive => l10n.diagnosticsInsufficient,
      DiagnosticVerdict.completed => l10n.diagnosticsCompleted,
      DiagnosticVerdict.failed => l10n.diagnosticsFailed,
    };
  }
}

extension ServiceOutcomeL10n on ServiceOutcome {
  String get label {
    final l10n = currentAppLocalizations;
    return switch (this) {
      ServiceOutcome.unlocked => l10n.auditUnlocked,
      ServiceOutcome.partial => l10n.auditPartial,
      ServiceOutcome.locked => l10n.auditLocked,
      ServiceOutcome.unsupported => l10n.auditRegionUnsupported,
      ServiceOutcome.verification => l10n.auditVerification,
      ServiceOutcome.failed => l10n.auditRequestFailed,
      ServiceOutcome.unknown => l10n.auditUnknown,
    };
  }
}

extension NetworkQualityGradeL10n on NetworkQualityGrade {
  String get label {
    final l10n = currentAppLocalizations;
    return switch (this) {
      NetworkQualityGrade.excellent => l10n.qualityExcellent,
      NetworkQualityGrade.good => l10n.qualityGood,
      NetworkQualityGrade.poor => l10n.qualityPoor,
      NetworkQualityGrade.unknown => l10n.unknown,
    };
  }
}
