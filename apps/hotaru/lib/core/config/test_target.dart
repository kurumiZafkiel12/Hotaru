bool isCoreTestTarget(Uri? target) {
  if (target == null) return false;
  try {
    return const ['http', 'https'].contains(target.scheme) &&
        target.hasAuthority &&
        target.host.isNotEmpty &&
        target.userInfo.isEmpty &&
        !target.hasFragment &&
        target.port > 0 &&
        target.port <= 65535;
  } on FormatException {
    return false;
  }
}
