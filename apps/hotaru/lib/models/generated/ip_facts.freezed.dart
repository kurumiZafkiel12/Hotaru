// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../ip_facts.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$IpFacts {

 String get ip; DateTime get checkedAt; DateTime? get locationCheckedAt; DateTime? get registryCheckedAt; DateTime? get scoreCheckedAt; String? get geoCountry; String? get registeredCountry; IpAttribute get attribute; int? get riskScore; String? get organization; int? get asn; IpFactStatus get locationStatus; IpFactStatus get registryStatus; IpFactStatus get scoreStatus;
/// Create a copy of IpFacts
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IpFactsCopyWith<IpFacts> get copyWith => _$IpFactsCopyWithImpl<IpFacts>(this as IpFacts, _$identity);

  /// Serializes this IpFacts to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as IpFacts;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IpFacts&&(identical(other.ip, _this.ip) || other.ip == _this.ip)&&(identical(other.checkedAt, _this.checkedAt) || other.checkedAt == _this.checkedAt)&&(identical(other.locationCheckedAt, _this.locationCheckedAt) || other.locationCheckedAt == _this.locationCheckedAt)&&(identical(other.registryCheckedAt, _this.registryCheckedAt) || other.registryCheckedAt == _this.registryCheckedAt)&&(identical(other.scoreCheckedAt, _this.scoreCheckedAt) || other.scoreCheckedAt == _this.scoreCheckedAt)&&(identical(other.geoCountry, _this.geoCountry) || other.geoCountry == _this.geoCountry)&&(identical(other.registeredCountry, _this.registeredCountry) || other.registeredCountry == _this.registeredCountry)&&(identical(other.attribute, _this.attribute) || other.attribute == _this.attribute)&&(identical(other.riskScore, _this.riskScore) || other.riskScore == _this.riskScore)&&(identical(other.organization, _this.organization) || other.organization == _this.organization)&&(identical(other.asn, _this.asn) || other.asn == _this.asn)&&(identical(other.locationStatus, _this.locationStatus) || other.locationStatus == _this.locationStatus)&&(identical(other.registryStatus, _this.registryStatus) || other.registryStatus == _this.registryStatus)&&(identical(other.scoreStatus, _this.scoreStatus) || other.scoreStatus == _this.scoreStatus));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as IpFacts;
  return Object.hash(runtimeType,_this.ip,_this.checkedAt,_this.locationCheckedAt,_this.registryCheckedAt,_this.scoreCheckedAt,_this.geoCountry,_this.registeredCountry,_this.attribute,_this.riskScore,_this.organization,_this.asn,_this.locationStatus,_this.registryStatus,_this.scoreStatus);
}

@override
String toString() {
  final _this = this as IpFacts;
  return 'IpFacts(ip: ${_this.ip}, checkedAt: ${_this.checkedAt}, locationCheckedAt: ${_this.locationCheckedAt}, registryCheckedAt: ${_this.registryCheckedAt}, scoreCheckedAt: ${_this.scoreCheckedAt}, geoCountry: ${_this.geoCountry}, registeredCountry: ${_this.registeredCountry}, attribute: ${_this.attribute}, riskScore: ${_this.riskScore}, organization: ${_this.organization}, asn: ${_this.asn}, locationStatus: ${_this.locationStatus}, registryStatus: ${_this.registryStatus}, scoreStatus: ${_this.scoreStatus})';
}


}

/// @nodoc
abstract mixin class $IpFactsCopyWith<$Res>  {
  factory $IpFactsCopyWith(IpFacts value, $Res Function(IpFacts) _then) = _$IpFactsCopyWithImpl;
@useResult
$Res call({
 String ip, DateTime checkedAt, DateTime? locationCheckedAt, DateTime? registryCheckedAt, DateTime? scoreCheckedAt, String? geoCountry, String? registeredCountry, IpAttribute attribute, int? riskScore, String? organization, int? asn, IpFactStatus locationStatus, IpFactStatus registryStatus, IpFactStatus scoreStatus
});




}
/// @nodoc
class _$IpFactsCopyWithImpl<$Res>
    implements $IpFactsCopyWith<$Res> {
  _$IpFactsCopyWithImpl(this._self, this._then);

  final IpFacts _self;
  final $Res Function(IpFacts) _then;

/// Create a copy of IpFacts
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? ip = null,Object? checkedAt = null,Object? locationCheckedAt = freezed,Object? registryCheckedAt = freezed,Object? scoreCheckedAt = freezed,Object? geoCountry = freezed,Object? registeredCountry = freezed,Object? attribute = null,Object? riskScore = freezed,Object? organization = freezed,Object? asn = freezed,Object? locationStatus = null,Object? registryStatus = null,Object? scoreStatus = null,}) {
  return _then(IpFacts(
ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,checkedAt: null == checkedAt ? _self.checkedAt : checkedAt // ignore: cast_nullable_to_non_nullable
as DateTime,locationCheckedAt: freezed == locationCheckedAt ? _self.locationCheckedAt : locationCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,registryCheckedAt: freezed == registryCheckedAt ? _self.registryCheckedAt : registryCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,scoreCheckedAt: freezed == scoreCheckedAt ? _self.scoreCheckedAt : scoreCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,geoCountry: freezed == geoCountry ? _self.geoCountry : geoCountry // ignore: cast_nullable_to_non_nullable
as String?,registeredCountry: freezed == registeredCountry ? _self.registeredCountry : registeredCountry // ignore: cast_nullable_to_non_nullable
as String?,attribute: null == attribute ? _self.attribute : attribute // ignore: cast_nullable_to_non_nullable
as IpAttribute,riskScore: freezed == riskScore ? _self.riskScore : riskScore // ignore: cast_nullable_to_non_nullable
as int?,organization: freezed == organization ? _self.organization : organization // ignore: cast_nullable_to_non_nullable
as String?,asn: freezed == asn ? _self.asn : asn // ignore: cast_nullable_to_non_nullable
as int?,locationStatus: null == locationStatus ? _self.locationStatus : locationStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,registryStatus: null == registryStatus ? _self.registryStatus : registryStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,scoreStatus: null == scoreStatus ? _self.scoreStatus : scoreStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,
  ));
}

}


/// Adds pattern-matching-related methods to [IpFacts].
extension IpFactsPatterns on IpFacts {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _IpFacts value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _IpFacts() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _IpFacts value)  $default,){
final _that = this;
switch (_that) {
case _IpFacts():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _IpFacts value)?  $default,){
final _that = this;
switch (_that) {
case _IpFacts() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String ip,  DateTime checkedAt,  DateTime? locationCheckedAt,  DateTime? registryCheckedAt,  DateTime? scoreCheckedAt,  String? geoCountry,  String? registeredCountry,  IpAttribute attribute,  int? riskScore,  String? organization,  int? asn,  IpFactStatus locationStatus,  IpFactStatus registryStatus,  IpFactStatus scoreStatus)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _IpFacts() when $default != null:
return $default(_that.ip,_that.checkedAt,_that.locationCheckedAt,_that.registryCheckedAt,_that.scoreCheckedAt,_that.geoCountry,_that.registeredCountry,_that.attribute,_that.riskScore,_that.organization,_that.asn,_that.locationStatus,_that.registryStatus,_that.scoreStatus);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String ip,  DateTime checkedAt,  DateTime? locationCheckedAt,  DateTime? registryCheckedAt,  DateTime? scoreCheckedAt,  String? geoCountry,  String? registeredCountry,  IpAttribute attribute,  int? riskScore,  String? organization,  int? asn,  IpFactStatus locationStatus,  IpFactStatus registryStatus,  IpFactStatus scoreStatus)  $default,) {final _that = this;
switch (_that) {
case _IpFacts():
return $default(_that.ip,_that.checkedAt,_that.locationCheckedAt,_that.registryCheckedAt,_that.scoreCheckedAt,_that.geoCountry,_that.registeredCountry,_that.attribute,_that.riskScore,_that.organization,_that.asn,_that.locationStatus,_that.registryStatus,_that.scoreStatus);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String ip,  DateTime checkedAt,  DateTime? locationCheckedAt,  DateTime? registryCheckedAt,  DateTime? scoreCheckedAt,  String? geoCountry,  String? registeredCountry,  IpAttribute attribute,  int? riskScore,  String? organization,  int? asn,  IpFactStatus locationStatus,  IpFactStatus registryStatus,  IpFactStatus scoreStatus)?  $default,) {final _that = this;
switch (_that) {
case _IpFacts() when $default != null:
return $default(_that.ip,_that.checkedAt,_that.locationCheckedAt,_that.registryCheckedAt,_that.scoreCheckedAt,_that.geoCountry,_that.registeredCountry,_that.attribute,_that.riskScore,_that.organization,_that.asn,_that.locationStatus,_that.registryStatus,_that.scoreStatus);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _IpFacts extends IpFacts {
  const _IpFacts({required this.ip, required this.checkedAt, this.locationCheckedAt, this.registryCheckedAt, this.scoreCheckedAt, this.geoCountry, this.registeredCountry, this.attribute = IpAttribute.unknown, this.riskScore, this.organization, this.asn, this.locationStatus = IpFactStatus.unavailable, this.registryStatus = IpFactStatus.unavailable, this.scoreStatus = IpFactStatus.unavailable}): super._();
  factory _IpFacts.fromJson(Map<String, dynamic> json) => _$IpFactsFromJson(json);

@override final  String ip;
@override final  DateTime checkedAt;
@override final  DateTime? locationCheckedAt;
@override final  DateTime? registryCheckedAt;
@override final  DateTime? scoreCheckedAt;
@override final  String? geoCountry;
@override final  String? registeredCountry;
@override@JsonKey() final  IpAttribute attribute;
@override final  int? riskScore;
@override final  String? organization;
@override final  int? asn;
@override@JsonKey() final  IpFactStatus locationStatus;
@override@JsonKey() final  IpFactStatus registryStatus;
@override@JsonKey() final  IpFactStatus scoreStatus;

/// Create a copy of IpFacts
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$IpFactsCopyWith<_IpFacts> get copyWith => __$IpFactsCopyWithImpl<_IpFacts>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$IpFactsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _IpFacts&&(identical(other.ip, ip) || other.ip == ip)&&(identical(other.checkedAt, checkedAt) || other.checkedAt == checkedAt)&&(identical(other.locationCheckedAt, locationCheckedAt) || other.locationCheckedAt == locationCheckedAt)&&(identical(other.registryCheckedAt, registryCheckedAt) || other.registryCheckedAt == registryCheckedAt)&&(identical(other.scoreCheckedAt, scoreCheckedAt) || other.scoreCheckedAt == scoreCheckedAt)&&(identical(other.geoCountry, geoCountry) || other.geoCountry == geoCountry)&&(identical(other.registeredCountry, registeredCountry) || other.registeredCountry == registeredCountry)&&(identical(other.attribute, attribute) || other.attribute == attribute)&&(identical(other.riskScore, riskScore) || other.riskScore == riskScore)&&(identical(other.organization, organization) || other.organization == organization)&&(identical(other.asn, asn) || other.asn == asn)&&(identical(other.locationStatus, locationStatus) || other.locationStatus == locationStatus)&&(identical(other.registryStatus, registryStatus) || other.registryStatus == registryStatus)&&(identical(other.scoreStatus, scoreStatus) || other.scoreStatus == scoreStatus));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,ip,checkedAt,locationCheckedAt,registryCheckedAt,scoreCheckedAt,geoCountry,registeredCountry,attribute,riskScore,organization,asn,locationStatus,registryStatus,scoreStatus);
}

@override
String toString() {
    return 'IpFacts(ip: $ip, checkedAt: $checkedAt, locationCheckedAt: $locationCheckedAt, registryCheckedAt: $registryCheckedAt, scoreCheckedAt: $scoreCheckedAt, geoCountry: $geoCountry, registeredCountry: $registeredCountry, attribute: $attribute, riskScore: $riskScore, organization: $organization, asn: $asn, locationStatus: $locationStatus, registryStatus: $registryStatus, scoreStatus: $scoreStatus)';
}


}

/// @nodoc
abstract mixin class _$IpFactsCopyWith<$Res> implements $IpFactsCopyWith<$Res> {
  factory _$IpFactsCopyWith(_IpFacts value, $Res Function(_IpFacts) _then) = __$IpFactsCopyWithImpl;
@override @useResult
$Res call({
 String ip, DateTime checkedAt, DateTime? locationCheckedAt, DateTime? registryCheckedAt, DateTime? scoreCheckedAt, String? geoCountry, String? registeredCountry, IpAttribute attribute, int? riskScore, String? organization, int? asn, IpFactStatus locationStatus, IpFactStatus registryStatus, IpFactStatus scoreStatus
});




}
/// @nodoc
class __$IpFactsCopyWithImpl<$Res>
    implements _$IpFactsCopyWith<$Res> {
  __$IpFactsCopyWithImpl(this._self, this._then);

  final _IpFacts _self;
  final $Res Function(_IpFacts) _then;

/// Create a copy of IpFacts
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? ip = null,Object? checkedAt = null,Object? locationCheckedAt = freezed,Object? registryCheckedAt = freezed,Object? scoreCheckedAt = freezed,Object? geoCountry = freezed,Object? registeredCountry = freezed,Object? attribute = null,Object? riskScore = freezed,Object? organization = freezed,Object? asn = freezed,Object? locationStatus = null,Object? registryStatus = null,Object? scoreStatus = null,}) {
  return _then(_IpFacts(
ip: null == ip ? _self.ip : ip // ignore: cast_nullable_to_non_nullable
as String,checkedAt: null == checkedAt ? _self.checkedAt : checkedAt // ignore: cast_nullable_to_non_nullable
as DateTime,locationCheckedAt: freezed == locationCheckedAt ? _self.locationCheckedAt : locationCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,registryCheckedAt: freezed == registryCheckedAt ? _self.registryCheckedAt : registryCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,scoreCheckedAt: freezed == scoreCheckedAt ? _self.scoreCheckedAt : scoreCheckedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,geoCountry: freezed == geoCountry ? _self.geoCountry : geoCountry // ignore: cast_nullable_to_non_nullable
as String?,registeredCountry: freezed == registeredCountry ? _self.registeredCountry : registeredCountry // ignore: cast_nullable_to_non_nullable
as String?,attribute: null == attribute ? _self.attribute : attribute // ignore: cast_nullable_to_non_nullable
as IpAttribute,riskScore: freezed == riskScore ? _self.riskScore : riskScore // ignore: cast_nullable_to_non_nullable
as int?,organization: freezed == organization ? _self.organization : organization // ignore: cast_nullable_to_non_nullable
as String?,asn: freezed == asn ? _self.asn : asn // ignore: cast_nullable_to_non_nullable
as int?,locationStatus: null == locationStatus ? _self.locationStatus : locationStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,registryStatus: null == registryStatus ? _self.registryStatus : registryStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,scoreStatus: null == scoreStatus ? _self.scoreStatus : scoreStatus // ignore: cast_nullable_to_non_nullable
as IpFactStatus,
  ));
}


}

// dart format on
