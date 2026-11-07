enum CoreRoutingMode { rule, global, direct }

abstract interface class CoreRoutingModes {
  Future<CoreRoutingMode> routingMode();
  Future<void> setRoutingMode(CoreRoutingMode mode);
}

abstract interface class CoreGlobalOutbound {
  Future<String> globalOutbound();
}
