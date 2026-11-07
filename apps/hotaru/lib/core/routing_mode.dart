enum CoreRoutingMode { rule, global, direct }

abstract interface class CoreRoutingModes {
  Future<CoreRoutingMode> routingMode();
  Future<void> setRoutingMode(CoreRoutingMode mode);
}
