// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../profile_traffic.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(profileTraffic)
final profileTrafficProvider = ProfileTrafficFamily._();

final class ProfileTrafficProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProfileTrafficValue?>,
          ProfileTrafficValue?,
          Stream<ProfileTrafficValue?>
        >
    with
        $FutureModifier<ProfileTrafficValue?>,
        $StreamProvider<ProfileTrafficValue?> {
  ProfileTrafficProvider._({
    required ProfileTrafficFamily super.from,
    required int super.argument,
  }) : super(
         retry: null,
         name: r'profileTrafficProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$profileTrafficHash();

  @override
  String toString() {
    return r'profileTrafficProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<ProfileTrafficValue?> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<ProfileTrafficValue?> create(Ref ref) {
    final argument = this.argument as int;
    return profileTraffic(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProfileTrafficProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$profileTrafficHash() => r'65ddf0e07d69b5ecce4e120e97d542a2bf7b0403';

final class ProfileTrafficFamily extends $Family
    with $FunctionalFamilyOverride<Stream<ProfileTrafficValue?>, int> {
  ProfileTrafficFamily._()
    : super(
        retry: null,
        name: r'profileTrafficProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ProfileTrafficProvider call(int profileId) =>
      ProfileTrafficProvider._(argument: profileId, from: this);

  @override
  String toString() => r'profileTrafficProvider';
}
