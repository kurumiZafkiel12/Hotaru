abstract interface class CoreLogSource {
  Stream<CoreLogMessage> logs();
}

final class CoreLogMessage {
  final String level;
  final String payload;

  const CoreLogMessage({required this.level, required this.payload});
}
