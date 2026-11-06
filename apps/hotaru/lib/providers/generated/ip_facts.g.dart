// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../ip_facts.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ipFacts)
final ipFactsProvider = IpFactsFamily._();

final class IpFactsProvider
    extends $FunctionalProvider<AsyncValue<IpFacts>, IpFacts, FutureOr<IpFacts>>
    with $FutureModifier<IpFacts>, $FutureProvider<IpFacts> {
  IpFactsProvider._({
    required IpFactsFamily super.from,
    required String super.argument,
  }) : super(
         retry: _noRetry,
         name: r'ipFactsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$ipFactsHash();

  @override
  String toString() {
    return r'ipFactsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<IpFacts> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<IpFacts> create(Ref ref) {
    final argument = this.argument as String;
    return ipFacts(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is IpFactsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$ipFactsHash() => r'023377b65b6dcc3bbf0b981db96ee55f5d119816';

final class IpFactsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<IpFacts>, String> {
  IpFactsFamily._()
    : super(
        retry: _noRetry,
        name: r'ipFactsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  IpFactsProvider call(String ip) =>
      IpFactsProvider._(argument: ip, from: this);

  @override
  String toString() => r'ipFactsProvider';
}
