abstract interface class CoreRuntimeMaintenance {
  Future<void> collectMemory();
  Future<void> resetDnsConnections();
}

abstract interface class CoreConnectionMaintenance {
  Future<void> closeConnections();
  Future<void> clearDnsCache();
}
