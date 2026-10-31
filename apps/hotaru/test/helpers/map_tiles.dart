import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';

class FixtureMapTiles extends TileProvider {
  bool failing = false;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(
        failing
            ? Uint8List(0)
            : File('assets/images/icon.png').readAsBytesSync(),
      );
}
