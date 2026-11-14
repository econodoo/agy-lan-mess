import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';

class DiscoveryBroadcaster {
  final int discoveryPort;
  final int httpPort;
  final String serverName;

  RawDatagramSocket? _socket;
  Timer? _periodicBeacon;

  DiscoveryBroadcaster({
    required this.discoveryPort,
    required this.httpPort,
    String? serverName,
  }) : serverName = serverName ?? Platform.localHostname;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            try {
              final dg = _socket?.receive();
              if (dg == null) return;
              final msg = utf8.decode(dg.data, allowMalformed: true).trim();
              if (msg.startsWith(DiscoveryBeacon.magicProbe)) {
                _sendBeaconTo(dg.address, dg.port);
              }
            } catch (_) {}
          }
        },
        onError: (Object _, StackTrace _) {
          // Ignore transient OS network/Wi-Fi roaming errors (e.g. errno 101).
        },
      );

      _periodicBeacon = Timer.periodic(const Duration(seconds: 4), (_) {
        _broadcastBeacon();
      });
    } catch (e) {
      stderr.writeln(
        '[Discovery] Could not bind UDP port $discoveryPort ($e). Manual IP connection still works.',
      );
    }
  }

  void _sendBeaconTo(InternetAddress address, int port) {
    final socket = _socket;
    if (socket == null) return;
    final beacon = DiscoveryBeacon(
      serverName: serverName,
      port: httpPort,
    );
    final bytes = utf8.encode(jsonEncode(beacon.toJson()));
    try {
      socket.send(bytes, address, port);
    } catch (_) {}
  }

  void _broadcastBeacon() {
    final socket = _socket;
    if (socket == null) return;
    final beacon = DiscoveryBeacon(
      serverName: serverName,
      port: httpPort,
    );
    final bytes = utf8.encode(jsonEncode(beacon.toJson()));
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  Future<void> stop() async {
    _periodicBeacon?.cancel();
    _periodicBeacon = null;
    _socket?.close();
    _socket = null;
  }

  /// Helper to list non-loopback IPv4 LAN addresses for startup banner & stamping.
  static Future<List<String>> detectLanIpv4Addresses() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (_) {}
    return ips;
  }
}
