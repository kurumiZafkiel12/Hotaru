// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../routing_config.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$RoutingConfig {

 int get id; String get name; String get url; DateTime get updatedAt; String get digest; int get ruleCount;
/// Create a copy of RoutingConfig
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RoutingConfigCopyWith<RoutingConfig> get copyWith => _$RoutingConfigCopyWithImpl<RoutingConfig>(this as RoutingConfig, _$identity);

  /// Serializes this RoutingConfig to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as RoutingConfig;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RoutingConfig&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.url, _this.url) || other.url == _this.url)&&(identical(other.updatedAt, _this.updatedAt) || other.updatedAt == _this.updatedAt)&&(identical(other.digest, _this.digest) || other.digest == _this.digest)&&(identical(other.ruleCount, _this.ruleCount) || other.ruleCount == _this.ruleCount));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as RoutingConfig;
  return Object.hash(runtimeType,_this.id,_this.name,_this.url,_this.updatedAt,_this.digest,_this.ruleCount);
}

@override
String toString() {
  final _this = this as RoutingConfig;
  return 'RoutingConfig(id: ${_this.id}, name: ${_this.name}, url: ${_this.url}, updatedAt: ${_this.updatedAt}, digest: ${_this.digest}, ruleCount: ${_this.ruleCount})';
}


}

/// @nodoc
abstract mixin class $RoutingConfigCopyWith<$Res>  {
  factory $RoutingConfigCopyWith(RoutingConfig value, $Res Function(RoutingConfig) _then) = _$RoutingConfigCopyWithImpl;
@useResult
$Res call({
 int id, String name, String url, DateTime updatedAt, String digest, int ruleCount
});




}
/// @nodoc
class _$RoutingConfigCopyWithImpl<$Res>
    implements $RoutingConfigCopyWith<$Res> {
  _$RoutingConfigCopyWithImpl(this._self, this._then);

  final RoutingConfig _self;
  final $Res Function(RoutingConfig) _then;

/// Create a copy of RoutingConfig
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? url = null,Object? updatedAt = null,Object? digest = null,Object? ruleCount = null,}) {
  return _then(RoutingConfig(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,digest: null == digest ? _self.digest : digest // ignore: cast_nullable_to_non_nullable
as String,ruleCount: null == ruleCount ? _self.ruleCount : ruleCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [RoutingConfig].
extension RoutingConfigPatterns on RoutingConfig {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RoutingConfig value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RoutingConfig() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RoutingConfig value)  $default,){
final _that = this;
switch (_that) {
case _RoutingConfig():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RoutingConfig value)?  $default,){
final _that = this;
switch (_that) {
case _RoutingConfig() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int id,  String name,  String url,  DateTime updatedAt,  String digest,  int ruleCount)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RoutingConfig() when $default != null:
return $default(_that.id,_that.name,_that.url,_that.updatedAt,_that.digest,_that.ruleCount);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int id,  String name,  String url,  DateTime updatedAt,  String digest,  int ruleCount)  $default,) {final _that = this;
switch (_that) {
case _RoutingConfig():
return $default(_that.id,_that.name,_that.url,_that.updatedAt,_that.digest,_that.ruleCount);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int id,  String name,  String url,  DateTime updatedAt,  String digest,  int ruleCount)?  $default,) {final _that = this;
switch (_that) {
case _RoutingConfig() when $default != null:
return $default(_that.id,_that.name,_that.url,_that.updatedAt,_that.digest,_that.ruleCount);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _RoutingConfig implements RoutingConfig {
  const _RoutingConfig({required this.id, required this.name, required this.url, required this.updatedAt, required this.digest, required this.ruleCount});
  factory _RoutingConfig.fromJson(Map<String, dynamic> json) => _$RoutingConfigFromJson(json);

@override final  int id;
@override final  String name;
@override final  String url;
@override final  DateTime updatedAt;
@override final  String digest;
@override final  int ruleCount;

/// Create a copy of RoutingConfig
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RoutingConfigCopyWith<_RoutingConfig> get copyWith => __$RoutingConfigCopyWithImpl<_RoutingConfig>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RoutingConfigToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _RoutingConfig&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.url, url) || other.url == url)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.digest, digest) || other.digest == digest)&&(identical(other.ruleCount, ruleCount) || other.ruleCount == ruleCount));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,url,updatedAt,digest,ruleCount);
}

@override
String toString() {
    return 'RoutingConfig(id: $id, name: $name, url: $url, updatedAt: $updatedAt, digest: $digest, ruleCount: $ruleCount)';
}


}

/// @nodoc
abstract mixin class _$RoutingConfigCopyWith<$Res> implements $RoutingConfigCopyWith<$Res> {
  factory _$RoutingConfigCopyWith(_RoutingConfig value, $Res Function(_RoutingConfig) _then) = __$RoutingConfigCopyWithImpl;
@override @useResult
$Res call({
 int id, String name, String url, DateTime updatedAt, String digest, int ruleCount
});




}
/// @nodoc
class __$RoutingConfigCopyWithImpl<$Res>
    implements _$RoutingConfigCopyWith<$Res> {
  __$RoutingConfigCopyWithImpl(this._self, this._then);

  final _RoutingConfig _self;
  final $Res Function(_RoutingConfig) _then;

/// Create a copy of RoutingConfig
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? url = null,Object? updatedAt = null,Object? digest = null,Object? ruleCount = null,}) {
  return _then(_RoutingConfig(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,digest: null == digest ? _self.digest : digest // ignore: cast_nullable_to_non_nullable
as String,ruleCount: null == ruleCount ? _self.ruleCount : ruleCount // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
