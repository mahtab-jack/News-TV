import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing room-based remote control connection
class RoomService {
  final String serverBase;
  String? _roomCode;
  Timer? _commandPollTimer;
  Timer? _statePushTimer;
  bool _isActive = false;
  int _remoteActivityCount = 0;

  /// Callback for when commands are received from remote
  void Function(String type, Map<String, dynamic> data)? onCommand;

  /// Function to get current TV state for pushing
  Map<String, dynamic> Function()? getState;

  /// Called when remote connection status changes
  void Function(bool connected)? onRemoteStatusChanged;

  RoomService({this.serverBase = 'http://127.0.0.1:8080'});

  String? get roomCode => _roomCode;
  bool get isActive => _isActive;

  /// Create a new room and start polling for commands.
  /// Persists the room code so it stays the same across restarts.
  Future<String?> createRoom() async {
    // Try to load saved room code first
    final prefs = await SharedPreferences.getInstance();
    final savedCode = prefs.getString('room_code');

    if (savedCode != null && savedCode.isNotEmpty) {
      _roomCode = savedCode;
      _startPolling();
      // Register it with the server in the background
      http.post(
        Uri.parse('$serverBase/api/room/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': savedCode}),
      ).timeout(const Duration(seconds: 5)).then((response) {
        if (response.statusCode == 200) {
          debugPrint('[RoomService] Room restored: $_roomCode');
        }
      }).catchError((e) {
        debugPrint('[RoomService] Failed to register restored room in background: $e');
      });
      return _roomCode;
    }

    // Create a new room if none exists
    try {
      final response = await http.post(
        Uri.parse('$serverBase/api/room/create'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _roomCode = data['code'];
        await prefs.setString('room_code', _roomCode!);
        _startPolling();
        debugPrint('[RoomService] Room created: $_roomCode');
        return _roomCode;
      }
    } catch (e) {
      debugPrint('[RoomService] Failed to create room: $e');
    }
    return null;
  }

  /// Get the LAN IP address
  Future<String> getLanIp() async {
    try {
      final response = await http.get(
        Uri.parse('$serverBase/api/network-info'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['ip'] ?? '127.0.0.1';
      }
    } catch (_) {}

    // Fallback: get local IP
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}

    return '127.0.0.1';
  }

  /// Generate QR code data as JSON string
  Future<String> getQrData() async {
    final ip = await getLanIp();
    return jsonEncode({
      'ip': ip,
      'port': 8080,
      'code': _roomCode,
    });
  }

  void _startPolling() {
    _isActive = true;

    // Poll for commands every 400ms
    _commandPollTimer?.cancel();
    _commandPollTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _pollCommands(),
    );

    // Push state every 1 second
    _statePushTimer?.cancel();
    _statePushTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pushState(),
    );
  }

  Future<void> _pollCommands() async {
    if (_roomCode == null || onCommand == null) return;

    try {
      final response = await http.get(
        Uri.parse('$serverBase/api/room/$_roomCode/commands'),
      ).timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final List<dynamic> commands = jsonDecode(response.body);
        if (commands.isNotEmpty) {
          _remoteActivityCount++;
          if (_remoteActivityCount == 1) {
            onRemoteStatusChanged?.call(true);
          }
        }
        for (final cmd in commands) {
          final type = cmd['type'] as String;
          final data = cmd['data'] is Map<String, dynamic>
              ? cmd['data'] as Map<String, dynamic>
              : <String, dynamic>{};
          onCommand?.call(type, data);
        }
      }
    } catch (_) {}
  }

  Future<void> _pushState() async {
    if (_roomCode == null || getState == null) return;

    try {
      final state = getState!();
      await http.post(
        Uri.parse('$serverBase/api/room/$_roomCode/state'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(state),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Regenerate room code (only when user explicitly requests)
  Future<String?> regenerateRoom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('room_code');
    stop();
    return createRoom();
  }

  /// Stop polling
  void stop() {
    _commandPollTimer?.cancel();
    _statePushTimer?.cancel();
    _isActive = false;
    _roomCode = null;
    _remoteActivityCount = 0;
  }
}
