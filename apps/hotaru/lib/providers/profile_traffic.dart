import 'dart:async';

import 'package:hotaru/database/database.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/profile_traffic.g.dart';

typedef ProfileTrafficValue = ({int upload, int download});

@riverpod
Stream<ProfileTrafficValue?> profileTraffic(Ref ref, int profileId) => database
    .profileTrafficDao
    .query(profileId)
    .watchSingleOrNull()
    .map(
      (row) =>
          row == null ? null : (upload: row.upload, download: row.download),
    );
