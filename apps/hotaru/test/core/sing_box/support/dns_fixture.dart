import 'dart:async';
import 'dart:convert';
import 'dart:io';

List<int> question(String name, {int type = 1}) => [
  0x12,
  0x34,
  1,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  for (final part in name.split('.')) ...[part.length, ...ascii.encode(part)],
  0,
  0,
  type,
  0,
  1,
];

List<int> answer(List<int> query) {
  var end = 12;
  while (query[end] != 0) {
    end += query[end] + 1;
  }
  end += 5;
  final ipv4 = query[end - 3] == 1;
  return [
    ...query.take(2),
    0x81,
    0x80,
    0,
    1,
    0,
    ipv4 ? 1 : 0,
    0,
    0,
    0,
    0,
    ...query.sublist(12, end),
    if (ipv4) ...[0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 45],
  ];
}

Future<List<int>> udpQuery(
  int port,
  List<int> query, {
  InternetAddress? address,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    final response = Completer<List<int>>();
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = socket.receive();
        if (packet != null && !response.isCompleted) {
          response.complete(packet.data);
        }
      }
    });
    socket.send(query, address ?? InternetAddress.loopbackIPv4, port);
    return await response.future.timeout(const Duration(seconds: 3));
  } finally {
    socket.close();
  }
}
