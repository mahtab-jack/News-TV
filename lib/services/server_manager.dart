import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class RoomData {
  final String code;
  Map<String, dynamic>? tvState;
  int lastActivity;
  RoomData({required this.code, this.tvState, required this.lastActivity});
}

class CommandData {
  final int id;
  final String roomCode;
  final String type;
  final Map<String, dynamic> data;
  bool processed;
  final int createdAt;

  CommandData({
    required this.id,
    required this.roomCode,
    required this.type,
    required this.data,
    this.processed = false,
    required this.createdAt,
  });
}

class CacheEntry {
  final String data;
  final int timestamp;
  CacheEntry(this.data, this.timestamp);
}

/// Manages the built-in Dart HTTP server for remote control communication
class ServerManager {
  static final ServerManager _instance = ServerManager._internal();
  factory ServerManager() => _instance;
  ServerManager._internal();

  HttpServer? _server;
  bool _isRunning = false;
  final int port = 8080;

  final Map<String, RoomData> _rooms = {};
  final List<CommandData> _commands = [];
  int _nextCommandId = 1;
  Timer? _cleanupTimer;

  final Map<String, CacheEntry> _playlistCache = {};
  static const int _cacheTtl = 60 * 60 * 1000; // 1 hour

  static const Map<String, String> _playlistUrls = {
    'india': 'https://iptv-org.github.io/iptv/countries/in.m3u',
    'news': 'https://iptv-org.github.io/iptv/categories/news.m3u',
    'business': 'https://iptv-org.github.io/iptv/categories/business.m3u',
    'movies': 'https://iptv-org.github.io/iptv/categories/movies.m3u',
    'music': 'https://iptv-org.github.io/iptv/categories/music.m3u',
    'sports': 'https://iptv-org.github.io/iptv/categories/sports.m3u'
  };

  bool get isRunning => _isRunning;

  /// Start the built-in HTTP server
  Future<bool> start() async {
    if (_isRunning) return true;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;
      debugPrint('[ServerManager] Built-in Dart Server running on port $port');

      _server!.listen((HttpRequest request) {
        _handleRequest(request);
      }, onError: (e) {
        debugPrint('[ServerManager] Server error: $e');
      });

      // Start stale rooms cleanup timer (every 10 minutes)
      _cleanupTimer?.cancel();
      _cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) => _cleanupStaleRooms());

      return true;
    } catch (e) {
      debugPrint('[ServerManager] Failed to start server: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Stop the server
  void stop() {
    _cleanupTimer?.cancel();
    _server?.close(force: true);
    _server = null;
    _isRunning = false;
    debugPrint('[ServerManager] Built-in Server stopped.');
  }

  String _generateRoomCode() {
    final rand = Random();
    String code = '';
    for (int i = 0; i < 6; i++) {
      code += rand.nextInt(10).toString();
    }
    return code;
  }

  Future<String> _getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  void _handleRequest(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    final method = request.method;

    // CORS Headers
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');

    if (method == 'OPTIONS') {
      response.statusCode = HttpStatus.ok;
      await response.close();
      return;
    }

    try {
      // POST /api/room/create
      if (path == '/api/room/create' && method == 'POST') {
        String code;
        try {
          final body = await _readRequestBody(request);
          if (body.isNotEmpty) {
            final data = jsonDecode(body) as Map<String, dynamic>;
            code = data['code'] as String? ?? _generateRoomCode();
          } else {
            code = _generateRoomCode();
          }
        } catch (_) {
          code = _generateRoomCode();
        }
        _rooms[code] = RoomData(code: code, lastActivity: DateTime.now().millisecondsSinceEpoch);
        _sendJsonResponse(response, {'code': code});
        return;
      }

      // GET /api/network-info
      if (path == '/api/network-info' && method == 'GET') {
        final ip = await _getLanIp();
        _sendJsonResponse(response, {'ip': ip, 'port': port});
        return;
      }

      // GET /api/room/:code/verify
      final verifyMatch = RegExp(r'^/api/room/([0-9]+)/verify$').firstMatch(path);
      if (verifyMatch != null && method == 'GET') {
        final code = verifyMatch.group(1)!;
        _sendJsonResponse(response, {'exists': _rooms.containsKey(code)});
        return;
      }

      // GET /api/room/:code/commands
      final getCmdsMatch = RegExp(r'^/api/room/([0-9]+)/commands$').firstMatch(path);
      if (getCmdsMatch != null && method == 'GET') {
        final code = getCmdsMatch.group(1)!;
        final list = <Map<String, dynamic>>[];
        for (final cmd in _commands) {
          if (cmd.roomCode == code && !cmd.processed) {
            list.add({
              'id': cmd.id,
              'type': cmd.type,
              'data': cmd.data,
            });
            cmd.processed = true;
          }
        }
        _sendJsonResponse(response, list);
        return;
      }

      // POST /api/room/:code/command
      final postCmdMatch = RegExp(r'^/api/room/([0-9]+)/command$').firstMatch(path);
      if (postCmdMatch != null && method == 'POST') {
        final code = postCmdMatch.group(1)!;
        if (!_rooms.containsKey(code)) {
          _sendErrorResponse(response, HttpStatus.notFound, 'Room not found');
          return;
        }

        final body = await _readRequestBody(request);
        final data = jsonDecode(body) as Map<String, dynamic>;

        _commands.add(CommandData(
          id: _nextCommandId++,
          roomCode: code,
          type: data['type'] ?? '',
          data: data['data'] is Map<String, dynamic> ? data['data'] as Map<String, dynamic> : {},
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));

        _rooms[code]!.lastActivity = DateTime.now().millisecondsSinceEpoch;
        _sendJsonResponse(response, {'success': true});
        return;
      }

      // GET /api/room/:code/state
      final getStateMatch = RegExp(r'^/api/room/([0-9]+)/state$').firstMatch(path);
      if (getStateMatch != null && method == 'GET') {
        final code = getStateMatch.group(1)!;
        if (!_rooms.containsKey(code)) {
          _sendErrorResponse(response, HttpStatus.notFound, 'Room not found');
          return;
        }
        _sendJsonResponse(response, _rooms[code]!.tvState ?? {});
        return;
      }

      // POST /api/room/:code/state
      final postStateMatch = RegExp(r'^/api/room/([0-9]+)/state$').firstMatch(path);
      if (postStateMatch != null && method == 'POST') {
        final code = postStateMatch.group(1)!;
        if (!_rooms.containsKey(code)) {
          _sendErrorResponse(response, HttpStatus.notFound, 'Room not found');
          return;
        }

        final body = await _readRequestBody(request);
        final data = jsonDecode(body) as Map<String, dynamic>;
        _rooms[code]!.tvState = data;
        _rooms[code]!.lastActivity = DateTime.now().millisecondsSinceEpoch;
        _sendJsonResponse(response, {'success': true});
        return;
      }

      // GET /api/playlist/:type
      final playlistMatch = RegExp(r'^/api/playlist/([a-zA-Z0-9]+)$').firstMatch(path);
      if (playlistMatch != null && method == 'GET') {
        final type = playlistMatch.group(1)!;
        final url = _playlistUrls[type];
        if (url == null) {
          _sendErrorResponse(response, HttpStatus.badRequest, 'Invalid playlist type');
          return;
        }

        final cached = _playlistCache[type];
        final now = DateTime.now().millisecondsSinceEpoch;
        if (cached != null && (now - cached.timestamp) < _cacheTtl) {
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType.text;
          response.write(cached.data);
          await response.close();
          return;
        }

        try {
          final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
          if (res.statusCode == HttpStatus.ok) {
            _playlistCache[type] = CacheEntry(res.body, now);
            response.statusCode = HttpStatus.ok;
            response.headers.contentType = ContentType.text;
            response.write(res.body);
          } else {
            response.statusCode = res.statusCode;
          }
        } catch (e) {
          response.statusCode = HttpStatus.badGateway;
        }
        await response.close();
        return;
      }

      // Default 404
      _sendErrorResponse(response, HttpStatus.notFound, 'Not Found');
    } catch (e) {
      debugPrint('[ServerManager] Error handling request: $e');
      _sendErrorResponse(response, HttpStatus.internalServerError, 'Internal Server Error');
    }
  }

  Future<String> _readRequestBody(HttpRequest request) async {
    return await utf8.decoder.bind(request).join();
  }

  void _sendJsonResponse(HttpResponse response, dynamic data) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }

  void _sendErrorResponse(HttpResponse response, int status, String msg) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'error': msg}));
    await response.close();
  }

  void _cleanupStaleRooms() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 24 * 60 * 60 * 1000; // 24 hours
    final toRemove = <String>[];

    for (final entry in _rooms.entries) {
      if (entry.value.lastActivity < cutoff) {
        toRemove.add(entry.key);
      }
    }

    for (final code in toRemove) {
      _rooms.remove(code);
      _commands.removeWhere((c) => c.roomCode == code);
    }

    if (toRemove.isNotEmpty) {
      debugPrint('[ServerManager] Cleaned up ${toRemove.length} stale rooms.');
    }
  }
}
