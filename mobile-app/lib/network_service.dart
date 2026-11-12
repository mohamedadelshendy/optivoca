import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Represents a discovered or manually configured Laptop Receiver on the LAN.
class LaptopEndpoint {
  final String ip;
  final int tcpPort;
  final String deviceName;
  final bool isManual;
  final DateTime lastSeen;

  const LaptopEndpoint({
    required this.ip,
    required this.tcpPort,
    required this.deviceName,
    this.isManual = false,
    required this.lastSeen,
  });

  LaptopEndpoint copyWith({
    String? ip,
    int? tcpPort,
    String? deviceName,
    bool? isManual,
    DateTime? lastSeen,
  }) {
    return LaptopEndpoint(
      ip: ip ?? this.ip,
      tcpPort: tcpPort ?? this.tcpPort,
      deviceName: deviceName ?? this.deviceName,
      isManual: isManual ?? this.isManual,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// Result of a single binary photo transfer over TCP.
class TransferResult {
  final bool success;
  final int elapsedMs;
  final int fileSizeBytes;
  final String? errorMessage;

  const TransferResult({
    required this.success,
    required this.elapsedMs,
    required this.fileSizeBytes,
    this.errorMessage,
  });
}

/// Manages UDP port 45454 auto-discovery and raw TCP binary streaming transfers.
class NetworkService extends ChangeNotifier {
  static const int udpDiscoveryPort = 45454;
  static const int defaultTcpPort = 45455;
  static const String beaconPrefix = 'INSTANT_DROP_DISCOVER:';
  static const Duration beaconTimeout = Duration(seconds: 7);

  RawDatagramSocket? _udpSocket;
  Timer? _stalenessTimer;
  LaptopEndpoint? _activeEndpoint;
  bool _isDisposed = false;

  LaptopEndpoint? get activeEndpoint => _activeEndpoint;
  bool get isConnected => _activeEndpoint != null;

  /// Starts listening for UDP discovery beacons on port 45454.
  Future<void> startDiscovery() async {
    await stopDiscovery();

    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpDiscoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows && !Platform.isAndroid,
      );
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = _udpSocket?.receive();
            if (datagram != null) {
              _handleIncomingDatagram(datagram);
            }
          }
        },
        onError: (Object error) {
          debugPrint('[NetworkService] UDP socket error: $error');
        },
      );

      // Periodically check if an auto-discovered laptop stopped sending beacons
      _stalenessTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _checkBeaconStaleness();
      });
    } catch (e) {
      debugPrint('[NetworkService] Failed to bind UDP port $udpDiscoveryPort: $e');
    }
  }

  /// Parses `INSTANT_DROP_DISCOVER:<TCP_PORT>:<DEVICE_NAME>` beacon packets.
  void _handleIncomingDatagram(Datagram datagram) {
    try {
      final message = utf8.decode(datagram.data, allowMalformed: true).trim();
      if (!message.startsWith(beaconPrefix)) return;

      final payload = message.substring(beaconPrefix.length);
      final separatorIndex = payload.indexOf(':');
      if (separatorIndex <= 0) return;

      final portStr = payload.substring(0, separatorIndex).trim();
      final deviceName = payload.substring(separatorIndex + 1).trim();
      final tcpPort = int.tryParse(portStr);
      if (tcpPort == null || tcpPort <= 0 || tcpPort > 65535) return;

      final senderIp = datagram.address.address;

      // Do not overwrite an active manual IP override unless the user clears it,
      // or if the manual IP matches the discovered IP.
      if (_activeEndpoint != null &&
          _activeEndpoint!.isManual &&
          _activeEndpoint!.ip != senderIp) {
        return;
      }

      final previous = _activeEndpoint;
      _activeEndpoint = LaptopEndpoint(
        ip: senderIp,
        tcpPort: tcpPort,
        deviceName: deviceName.isEmpty ? 'Laptop ($senderIp)' : deviceName,
        isManual: false,
        lastSeen: DateTime.now(),
      );

      if (previous == null ||
          previous.ip != _activeEndpoint!.ip ||
          previous.tcpPort != _activeEndpoint!.tcpPort ||
          previous.deviceName != _activeEndpoint!.deviceName ||
          previous.isManual != _activeEndpoint!.isManual) {
        if (!_isDisposed) notifyListeners();
      }
    } catch (e) {
      debugPrint('[NetworkService] Malformed UDP beacon: $e');
    }
  }

  void _checkBeaconStaleness() {
    final current = _activeEndpoint;
    if (current == null || current.isManual) return;

    if (DateTime.now().difference(current.lastSeen) > beaconTimeout) {
      _activeEndpoint = null;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// Allows manual IP & port configuration as a fallback when UDP broadcast is blocked.
  void setManualEndpoint({
    required String ip,
    int tcpPort = defaultTcpPort,
    String? customName,
  }) {
    final cleanedIp = ip.trim();
    if (cleanedIp.isEmpty) return;

    _activeEndpoint = LaptopEndpoint(
      ip: cleanedIp,
      tcpPort: tcpPort,
      deviceName: (customName != null && customName.trim().isNotEmpty)
          ? customName.trim()
          : 'Laptop ($cleanedIp)',
      isManual: true,
      lastSeen: DateTime.now(),
    );
    if (!_isDisposed) notifyListeners();
  }

  /// Clears manual IP override and returns to automatic UDP discovery.
  void clearManualEndpoint() {
    if (_activeEndpoint != null && _activeEndpoint!.isManual) {
      _activeEndpoint = null;
      if (!_isDisposed) notifyListeners();
    }
  }

  /// Sends a photo over raw TCP adhering strictly to the InstantDrop binary protocol:
  /// 1. 4 bytes (u32 Big-Endian): Length of UTF-8 filename in bytes (N)
  /// 2. N bytes (UTF-8): Exact filename
  /// 3. Remaining bytes until EOF: Raw binary file stream (zero Base64, zero re-compression)
  Future<TransferResult> sendPhotoFile({
    required File file,
    required String filename,
  }) async {
    final endpoint = _activeEndpoint;
    if (endpoint == null) {
      return const TransferResult(
        success: false,
        elapsedMs: 0,
        fileSizeBytes: 0,
        errorMessage: 'No laptop connected. Ensure receiver is running on LAN.',
      );
    }

    if (!await file.exists()) {
      return const TransferResult(
        success: false,
        elapsedMs: 0,
        fileSizeBytes: 0,
        errorMessage: 'Source photo file no longer exists on device.',
      );
    }

    final fileSize = await file.length();
    final stopwatch = Stopwatch()..start();
    Socket? socket;

    try {
      socket = await Socket.connect(
        endpoint.ip,
        endpoint.tcpPort,
        timeout: const Duration(seconds: 5),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);

      // Encode filename as UTF-8 and construct 4-byte Big-Endian length header
      final filenameBytes = utf8.encode(filename);
      final headerData = ByteData(4)..setUint32(0, filenameBytes.length, Endian.big);

      // Write header + filename bytes
      socket.add(headerData.buffer.asUint8List());
      socket.add(filenameBytes);

      // Stream raw file binary directly from disk to socket without loading full file into RAM
      await socket.addStream(file.openRead());
      await socket.flush();
      await socket.close();
      stopwatch.stop();

      return TransferResult(
        success: true,
        elapsedMs: stopwatch.elapsedMilliseconds,
        fileSizeBytes: fileSize,
      );
    } catch (e) {
      stopwatch.stop();
      try {
        socket?.destroy();
      } catch (_) {}
      return TransferResult(
        success: false,
        elapsedMs: stopwatch.elapsedMilliseconds,
        fileSizeBytes: fileSize,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> stopDiscovery() async {
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
  }

  @override
  void dispose() {
    _isDisposed = true;
    stopDiscovery();
    super.dispose();
  }
}

