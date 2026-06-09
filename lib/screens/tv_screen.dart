import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/channel.dart';
import '../services/channel_service.dart';
import '../services/room_service.dart';
import '../services/server_manager.dart';
import '../utils/constants.dart';
import '../widgets/channel_banner.dart';
import '../widgets/loading_overlay.dart';
import '../widgets/window_title_bar.dart';

/// Main TV viewing screen with video player, controls, and overlays
class TvScreen extends StatefulWidget {
  final VoidCallback? onReady;
  const TvScreen({super.key, this.onReady});

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> with TickerProviderStateMixin {
  // Services
  final ServerManager _serverManager = ServerManager();
  final ChannelService _channelService = ChannelService();
  final RoomService _roomService = RoomService(serverBase: 'http://127.0.0.1:8080');

  // Media player
  late final Player _player;
  late final VideoController _videoController;

  // State
  Channel? _currentChannel;
  bool _isBuffering = true;
  bool _showTitleBar = false;
  bool _isMiniPlayer = false;
  Size _preMiniSize = const Size(1280, 720);
  bool _isFullscreen = false;
  bool _hasError = false;
  String _errorMsg = 'Failed to load stream';
  bool _isPlaying = false;
  bool _isUserPaused = false;
  bool _isMuted = false;
  int _volume = 100;
  bool _showControls = false;
  bool _showBanner = false;
  bool _showVolume = false;
  bool _showGuide = false;
  bool _showSearch = false;
  bool _showFavorites = false;
  bool _hasRemoteConnected = false;
  bool _isChangingChannel = false;
  bool _isRemoteAction = false;
  bool _showSettings = false;
  bool _showChannelInTaskbar = true;
  bool _autoRetry = true;
  bool _showMiniBadge = true;
  bool _showNumberWithName = true;
  Timer? _controlsTimer;
  Timer? _bannerTimer;
  Timer? _volumeTimer;
  Timer? _retryTimer;
  String _searchQuery = '';
  String _guideSearchQuery = '';
  String _selectedCategory = 'all';

  // Favorites
  Set<String> _favorites = {};

  // Number input accumulator
  String _numberBuffer = '';
  Timer? _numberTimer;

  // Feedback overlay state
  IconData? _feedbackIcon;
  String? _feedbackLabel;
  Timer? _feedbackTimer;

  // Focus
  final FocusNode _mainFocus = FocusNode();
  final ScrollController _categoryScrollController = ScrollController();
  final ScrollController _guideScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _setupPlayerListeners();
    _loadFavorites();
    _loadSettings();
    _initializeApp();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showChannelInTaskbar = prefs.getBool('settings_taskbar_name') ?? true;
      _autoRetry = prefs.getBool('settings_auto_retry') ?? true;
      _showMiniBadge = prefs.getBool('settings_mini_badge') ?? true;
      _showNumberWithName = prefs.getBool('settings_number_name') ?? true;
    });
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    if (key == 'settings_taskbar_name') {
      _updateWindowTitle();
    }
  }

  void _updateWindowTitle() {
    if (_showChannelInTaskbar && _currentChannel != null) {
      final title = _showNumberWithName 
        ? 'CH ${_currentChannel!.number.toString().padLeft(2, '0')} ${_currentChannel!.name} - TV'
        : '${_currentChannel!.name} - TV';
      windowManager.setTitle(title);
    } else {
      windowManager.setTitle('News TV');
    }
  }

  void _setupPlayerListeners() {
    // Optimization: Low-latency configuration for faster channel zapping
    if (_player.platform is NativePlayer) {
      (_player.platform as NativePlayer).setProperty('network-timeout', '10');
      (_player.platform as NativePlayer).setProperty('demuxer-lavf-o', 'protocol_whitelist=[file,rtp,tcp,udp,http,https,tls,rtsp,rtmp]');
      (_player.platform as NativePlayer).setProperty('cache-pause', 'no');
      // Set a very small initial buffer for instant start
      (_player.platform as NativePlayer).setProperty('buffer-size', '1M');
    }

    _player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          if (playing) {
            _hasError = false; // Fix: Stream is playing, clear error
          }
        });
        if (playing) {
          widget.onReady?.call();
          _retryTimer?.cancel();
        }
        // Only show feedback if not in the middle of a channel change
        if (!_isChangingChannel) {
          _showFeedback(playing ? Icons.play_arrow_rounded : Icons.pause_rounded, playing ? 'PLAY' : 'PAUSE');
        }
      }
    });
    _player.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() => _isBuffering = buffering);
        if (buffering && _autoRetry) {
          _startRetryTimer();
        } else {
          _retryTimer?.cancel();
        }
      }
    });
    _player.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        setState(() {
          _hasError = true;
          _errorMsg = 'Currently stream unavailable...';
        });
        if (_autoRetry) _startRetryTimer();
      }
    });
    _player.stream.completed.listen((completed) {
      if (completed && _currentChannel != null) {
        // Stream ended, try to restart
        _playChannel(_currentChannel!);
      }
    });
  }

  Future<void> _initializeApp() async {
    // Start server
    await _serverManager.start();
    await Future.delayed(const Duration(milliseconds: 500));

    // Initialize channels
    _channelService.initPredefined();
    await _channelService.loadAllPlaylists();

    // Setup room for remote control
    await _roomService.createRoom();
    _roomService.onCommand = _handleRemoteCommand;
    _roomService.getState = _getCurrentState;
    _roomService.onRemoteStatusChanged = (connected) {
      if (mounted) setState(() => _hasRemoteConnected = connected);
    };

    // Auto-play first available channel
    final available = _channelService.availableChannels;
    if (available.isNotEmpty) {
      // Try to load last watched
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString('last_channel');
      Channel? startChannel;
      if (lastId != null) {
        startChannel = _channelService.findById(lastId);
        if (startChannel != null && !startChannel.hasStream) startChannel = null;
      }
      startChannel ??= available.first;
      _switchChannel(startChannel);
    }
  }

  void _startRetryTimer() {
    _retryTimer?.cancel();
    // Use 2 seconds for quick retry if there's an error (not found)
    // or 10 seconds if it's just slow buffering.
    final retrySeconds = _hasError ? 2 : 10;
    
    _retryTimer = Timer(Duration(seconds: retrySeconds), () {
      if (mounted && _currentChannel != null) {
        // Only retry if the user hasn't manually paused the stream
        // and we are currently stuck or in error state.
        if (!_isUserPaused && (_hasError || _isBuffering)) {
          debugPrint('[AutoRetry] Stream stuck/errored, refreshing...');
          _playChannel(_currentChannel!);
        }
      }
    });
  }

  void _showFeedback(IconData icon, String label) {
    if (!_isRemoteAction) return;
    setState(() {
      _feedbackIcon = icon;
      _feedbackLabel = label;
    });
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _feedbackIcon = null;
          _feedbackLabel = null;
        });
      }
    });
  }

  Map<String, dynamic> _getCurrentState() {
    return TvState(
      channelId: _currentChannel?.id,
      channelName: _currentChannel?.name,
      channelNumber: _currentChannel?.number,
      channelLogo: _currentChannel?.logo,
      playing: _isPlaying,
      muted: _isMuted,
      volume: _volume,
      favorites: _favorites.toList(),
    ).toJson();
  }

  void _typeDigit(String digit) {
    setState(() {
      _numberBuffer += digit;
    });
    _numberTimer?.cancel();
    _numberTimer = Timer(const Duration(seconds: 2), () {
      final num = int.tryParse(_numberBuffer);
      if (num != null) _goToChannel(num);
      setState(() {
        _numberBuffer = '';
      });
    });
  }

  void _handleRemoteCommand(String type, Map<String, dynamic> data) {
    if (!_hasRemoteConnected) {
      setState(() => _hasRemoteConnected = true);
    }
    _isRemoteAction = true;
    switch (type) {
      case 'channel_digit':
        final digit = data['digit'];
        if (digit != null) {
          _typeDigit(digit.toString());
        }
        break;
      case 'channel_next':
      case 'next_channel':
        _nextChannel();
        break;
      case 'channel_prev':
      case 'prev_channel':
        _prevChannel();
        break;
      case 'channel_number':
        final num = data['number'];
        if (num != null) _goToChannel(num is int ? num : int.tryParse(num.toString()) ?? 0);
        break;
      case 'channel_change':
        final id = data['channelId'];
        if (id != null) {
          final ch = _channelService.findById(id.toString());
          if (ch != null) _switchChannel(ch);
        }
        break;
      case 'volume_up':
        _adjustVolume(5);
        break;
      case 'volume_down':
        _adjustVolume(-5);
        break;
      case 'mute_toggle':
        _toggleMute();
        break;
      case 'play_pause':
        _togglePlayPause();
        break;
      case 'fullscreen_toggle':
        _toggleFullscreen();
        break;
      case 'pip_toggle':
        _toggleMiniPlayer();
        break;
      case 'power_toggle':
        () async {
          final minimized = await windowManager.isMinimized();
          if (minimized) {
            await windowManager.restore();
            await windowManager.focus();
          } else {
            await windowManager.minimize();
          }
          _showFeedback(Icons.power_settings_new_rounded, 'POWER');
        }();
        break;
      case 'guide_toggle':
        setState(() => _showGuide = !_showGuide);
        _showFeedback(Icons.menu_rounded, 'GUIDE');
        break;
    }
  }

  // Channel switching
  void _switchChannel(Channel channel) async {
    setState(() {
      _currentChannel = channel;
      _isUserPaused = false;
      _isBuffering = channel.hasStream;
      _hasError = !channel.hasStream;
      _errorMsg = 'Currently stream unavailable...';
      _showBanner = false; // Toast/Banner removed as requested
      _isChangingChannel = true;
    });

    _updateWindowTitle();

    // Save last watched
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_channel', channel.id);

    // Reset channel change flag after a delay to allow feedback again
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _isChangingChannel = false);
    });

    // Play stream
    _playChannel(channel);
  }

  void _playChannel(Channel channel) {
    if (channel.streamUrl == null || channel.streamUrl!.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMsg = 'Currently stream unavailable...';
      });
      return;
    }
    try {
      // Use low-latency media configuration
      _player.open(
        Media(
          channel.streamUrl!,
          httpHeaders: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) NewsTV/2.0',
          },
        ),
        play: true,
      );
      _player.setVolume(_isMuted ? 0 : _volume.toDouble());
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMsg = 'Currently stream unavailable...';
      });
    }
  }

  void _nextChannel() {
    final available = _channelService.availableChannels;
    if (available.isEmpty) return;
    final idx = _currentChannel != null
        ? available.indexWhere((c) => c.id == _currentChannel!.id)
        : -1;
    final next = (idx + 1) % available.length;
    _switchChannel(available[next]);
    _showFeedback(Icons.skip_next_rounded, 'NEXT CH');
  }

  void _prevChannel() {
    final available = _channelService.availableChannels;
    if (available.isEmpty) return;
    final idx = _currentChannel != null
        ? available.indexWhere((c) => c.id == _currentChannel!.id)
        : 0;
    final prev = (idx - 1 + available.length) % available.length;
    _switchChannel(available[prev]);
    _showFeedback(Icons.skip_previous_rounded, 'PREV CH');
  }

  void _goToChannel(int number) {
    final ch = _channelService.findByNumber(number);
    if (ch != null) _switchChannel(ch);
  }

  // Volume
  void _adjustVolume(int delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0, 100);
      _showVolume = true;
    });
    _player.setVolume(_isMuted ? 0 : _volume.toDouble());
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolume = false);
    });
    _showFeedback(delta > 0 ? Icons.volume_up_rounded : Icons.volume_down_rounded, delta > 0 ? 'VOL +' : 'VOL -');
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _showVolume = true;
    });
    _player.setVolume(_isMuted ? 0 : _volume.toDouble());
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolume = false);
    });
    _showFeedback(_isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded, _isMuted ? 'MUTE' : 'UNMUTE');
  }

  void _togglePlayPause() {
    setState(() => _isUserPaused = !_isUserPaused);
    _player.playOrPause();
  }

  // Controls visibility
  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(AppDurations.controlsAutoHide, () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // Favorites
  void _toggleFavoritesPopup() {
    _showCenteredPopup(_buildFavoritesPanel());
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favs = prefs.getStringList('favorites') ?? [];
    setState(() => _favorites = favs.toSet());
  }

  Future<void> _toggleFavorite(String channelId) async {
    setState(() {
      if (_favorites.contains(channelId)) {
        _favorites.remove(channelId);
      } else {
        _favorites.add(channelId);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', _favorites.toList());
  }

  // Keyboard handling
  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    
    // Disable shortcuts while searching to allow typing
    if (_showSearch) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _showSearch = false;
          _searchQuery = '';
        });
      }
      return;
    }

    _isRemoteAction = false;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _nextChannel();
      case LogicalKeyboardKey.arrowDown:
        _prevChannel();
      case LogicalKeyboardKey.arrowRight:
        _adjustVolume(5);
      case LogicalKeyboardKey.arrowLeft:
        _adjustVolume(-5);
      case LogicalKeyboardKey.space || LogicalKeyboardKey.enter:
        _togglePlayPause();
      case LogicalKeyboardKey.keyM:
        _toggleMute();
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
      case LogicalKeyboardKey.keyG:
        if (!_showSearch) {
          setState(() => _showGuide = !_showGuide);
          if (!_showGuide) _mainFocus.requestFocus();
        }
      case LogicalKeyboardKey.keyS:
        if (!_showSearch) _showSearchPopup();
      case LogicalKeyboardKey.keyI:
        if (!_showSearch) {
          _showSettings = true;
          _showCenteredPopup(_buildSettingsPanel());
        }
      case LogicalKeyboardKey.escape:
        if (_showGuide) {
          setState(() => _showGuide = false);
          _mainFocus.requestFocus();
        } else if (_showSearch) {
          Navigator.of(context).pop();
        }
      default:
        // Number keys (keyboard row or Numpad keys)
        final keyLabel = event.logicalKey.keyLabel;
        final char = event.character;
        if (char != null && RegExp(r'^[0-9]$').hasMatch(char)) {
          _typeDigit(char);
        } else {
          // Fallback to matching digit in logical key label (e.g. Numpad 1)
          final match = RegExp(r'[0-9]').firstMatch(keyLabel);
          if (match != null) {
            _typeDigit(match.group(0)!);
          }
        }
    }
  }

  // QR Dialog
  void _showQrDialog() async {
    if (_roomService.roomCode == null) {
      await _roomService.createRoom();
    }
    final qrData = await _roomService.getQrData();
    final lanIp = await _roomService.getLanIp();
    if (!mounted) return;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'RemoteQR',
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return Transform.scale(
          scale: Curves.easeOutCubic.transform(anim1.value),
          child: FadeTransition(
            opacity: anim1,
            child: Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                width: 400,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(color: AppColors.borderSubtle),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accentCyan.withOpacity(0.05),
                      blurRadius: 40,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.phonelink_rounded, color: AppColors.accentCyan, size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Mobile Remote Control',
                              style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Scan this QR code with the News TV Remote app\nServer IP: $lanIp',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                      ),
                      child: QrImageView(
                        data: qrData,
                        version: QrVersions.auto,
                        size: 200,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(color: Color(0xFF0A0D14), eyeShape: QrEyeShape.circle),
                        dataModuleStyle: const QrDataModuleStyle(color: Color(0xFF0A0D14), dataModuleShape: QrDataModuleShape.circle),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('CONNECTION CODE',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 2)),
                    const SizedBox(height: 8),
                    Text(
                      _roomService.roomCode ?? '------',
                      style: const TextStyle(
                        color: AppColors.accentCyan, fontSize: 28, fontWeight: FontWeight.w800,
                        letterSpacing: 8, fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () async {
                        await _roomService.regenerateRoom();
                        if (!ctx.mounted) return;
                        Navigator.of(ctx).pop();
                        if (!mounted) return;
                        _showQrDialog();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Generate New Code'),
                      style: TextButton.styleFrom(foregroundColor: AppColors.accentCyan),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggleMiniPlayer() async {
    if (_isMiniPlayer) {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSize(_preMiniSize);
      setState(() {
        _isMiniPlayer = false;
      });
      _showFeedback(Icons.open_in_new_rounded, 'PiP OFF');
    } else {
      _preMiniSize = await windowManager.getSize();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(384, 216));
      setState(() {
        _isMiniPlayer = true;
      });
      _showFeedback(Icons.picture_in_picture_rounded, 'PiP ON');
    }
  }

  void _toggleFullscreen() async {
    final fs = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!fs);
    setState(() {
      _isFullscreen = !fs;
    });
    _showFeedback(!fs ? Icons.fullscreen_rounded : Icons.fullscreen_exit_rounded, !fs ? 'FULLSCREEN' : 'WINDOWED');
  }

  String _formatDuration(Duration d) {
    final hh = d.inHours.toString().padLeft(2, '0');
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$hh:$mm:$ss' : '$mm:$ss';
  }

  void _showCreditDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'AuthorCredits',
      barrierColor: Colors.black.withOpacity(0.7),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return Transform.scale(
          scale: Curves.easeOutCubic.transform(anim1.value),
          child: FadeTransition(
            opacity: anim1,
            child: Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                width: 380,
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(AppRadius.xxl),
                  border: Border.all(color: AppColors.borderSubtle, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accentCyan.withOpacity(0.1),
                      blurRadius: 40,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Banner/Top Section
                    Stack(
                      children: [
                        Container(
                          height: 100,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [AppColors.accentCyan, AppColors.bgCard],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
                          ),
                        ),
                        Positioned(
                          top: 12,
                          right: 12,
                          child: IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.only(top: 40),
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.bgCard, width: 5),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(100),
                              child: Image.asset(
                                'assets/mahtab.jpg',
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: AppColors.bgElevated,
                                  child: const Icon(Icons.person_rounded, size: 50, color: AppColors.textMuted),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'MAHTAB JACK',
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Lead Full-Stack Developer',
                      style: TextStyle(color: AppColors.accentCyan, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                      child: Text(
                        'Expert in Flutter, Node.js, and Cloud Architecture. Passionate about building seamless multimedia experiences and high-performance applications.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
                      ),
                    ),
                    const Divider(color: AppColors.borderSubtle, height: 1),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const Text('CONNECT WITH ME',
                              style: TextStyle(color: AppColors.textDim, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 2)),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _SocialLink(
                                icon: '𝕏',
                                label: 'Twitter',
                                url: 'https://x.com/mahtab_jack',
                              ),
                              _SocialLink(
                                icon: '🔗',
                                label: 'Blog',
                                url: 'https://blogthread.in/author/mahtabjack',
                              ),
                              _SocialLink(
                                icon: '💻',
                                label: 'GitHub',
                                url: 'https://github.com/mahtab-jack',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _player.dispose();
    _controlsTimer?.cancel();
    _bannerTimer?.cancel();
    _volumeTimer?.cancel();
    _numberTimer?.cancel();
    _roomService.stop();
    _serverManager.stop();
    _mainFocus.dispose();
    _categoryScrollController.dispose();
    _feedbackTimer?.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // Background transparent for overlays
      body: KeyboardListener(
        focusNode: _mainFocus,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: GestureDetector(
          onTap: () {
            setState(() => _isRemoteAction = false);
            _togglePlayPause();
          },
          onSecondaryTap: _toggleFavoritesPopup,
          child: MouseRegion(
            onHover: (_) {
              _isRemoteAction = false;
              _showControlsTemporarily();
            },
            child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Main content area with solid background
              Positioned.fill(
                child: Container(
                  color: AppColors.bgDeepest,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColorFiltered(
                          colorFilter: _isPlaying
                              ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
                              : const ColorFilter.matrix(<double>[
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0,      0,      0,      1, 0,
                                ]),
                          child: Video(
                            controller: _videoController,
                            fill: Colors.black,
                            controls: NoVideoControls,
                          ),
                        ),
                      ),

                      // Loading overlay
                      LoadingOverlay(
                        isLoading: _isBuffering && !_hasError,
                        channel: _currentChannel,
                        message: _currentChannel != null
                            ? 'Loading ${_currentChannel!.name}...'
                            : 'Buffering...',
                      ),

                      // Error overlay
                      ErrorOverlay(
                        isVisible: _hasError && !_isPlaying,
                        message: _errorMsg,
                        onRetry: () {
                          setState(() => _hasError = false);
                          if (_currentChannel != null) _playChannel(_currentChannel!);
                        },
                      ),

                      // Channel banner OSD
                      ChannelBanner(channel: _currentChannel, visible: _showBanner),

                      // Volume indicator
                      VolumeIndicator(volume: _volume, muted: _isMuted, visible: _showVolume),

                      // Central action feedback overlay
                      if (_feedbackIcon != null)
                        IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppColors.accentCyan.withOpacity(0.35), width: 1.5),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: Icon(_feedbackIcon, size: 52, color: AppColors.accentCyan),
                                      ),
                                      if (_feedbackLabel == 'VOL +')
                                        const Positioned(
                                          right: 0,
                                          top: 0,
                                          child: Text('+', style: TextStyle(color: AppColors.accentCyan, fontSize: 24, fontWeight: FontWeight.bold)),
                                        ),
                                      if (_feedbackLabel == 'VOL -')
                                        const Positioned(
                                          right: 0,
                                          top: 0,
                                          child: Text('-', style: TextStyle(color: AppColors.accentCyan, fontSize: 24, fontWeight: FontWeight.bold)),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _feedbackLabel ?? '',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      // Channel number input overlay (top left)
                      if (_numberBuffer.isNotEmpty)
                        Positioned(
                          top: 70,
                          left: 24,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.8),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppColors.accentCyan.withOpacity(0.5), width: 1.5),
                            ),
                            child: Text(
                              'CH $_numberBuffer',
                              style: const TextStyle(
                                color: AppColors.accentCyan,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ),

                      // Bottom player controls
                      _buildPlayerControls(),

                      // Title bar (auto-hiding, tied to controls visibility)
                      AnimatedPositioned(
                        duration: AppDurations.normal,
                        curve: Curves.easeOutCubic,
                        top: (_showControls || _isBuffering) ? 0 : -45,
                        left: 0,
                        right: 0,
                        child: WindowTitleBar(
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _TopBarBtn(
                                  icon: Icons.menu_rounded,
                                  tooltip: 'TV Guide (G)',
                                  onPressed: () => setState(() => _showGuide = !_showGuide),
                                ),
                                _TopBarBtn(
                                  icon: Icons.search_rounded,
                                  tooltip: 'Search (S)',
                                  onPressed: _showSearchPopup,
                                ),
                                _TopBarBtn(
                                  icon: Icons.phonelink_rounded,
                                  tooltip: 'Phone Remote',
                                  onPressed: _showQrDialog,
                                  color: _hasRemoteConnected ? AppColors.accentGreen : null,
                                ),
                                _TopBarBtn(
                                  icon: Icons.info_outline_rounded,
                                  tooltip: 'Credits',
                                  onPressed: _showCreditDialog,
                                ),
                                _TopBarBtn(
                                  icon: Icons.settings_rounded,
                                  tooltip: 'Settings (I)',
                                  onPressed: () {
                                    _showSettings = true;
                                    _showCenteredPopup(_buildSettingsPanel());
                                  },
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                      ),

                      // TV Guide sidebar
                      _buildGuide(),

                      // Channel Badge Overlay (Inside the video area)
                      if (_showMiniBadge && _currentChannel != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: Center(
                            child: Text(
                              _showNumberWithName 
                                ? 'CH ${_currentChannel!.number.toString().padLeft(2, '0')} ${_currentChannel!.name.toUpperCase()}'
                                : _currentChannel!.name.toUpperCase(),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Search overlay
              if (_showSearch) _buildSearchOverlay(),
            ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSearchPopup() {
    setState(() => _showSearch = true);
    _showCenteredPopup(_buildSearchOverlay());
  }

  void _showCenteredPopup(Widget child) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'CenteredPopup',
      barrierColor: Colors.black.withOpacity(0.7),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim1, anim2, childPopup) {
        return Transform.scale(
          scale: Curves.easeOutCubic.transform(anim1.value),
          child: FadeTransition(
            opacity: anim1,
            child: child,
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        setState(() {
          _showSearch = false;
          _showSettings = false;
          _showFavorites = false;
        });
        _mainFocus.requestFocus();
      }
    });
  }

  Widget _buildPlayerControls() {
    return AnimatedPositioned(
      duration: AppDurations.normal,
      curve: Curves.easeOutCubic,
      bottom: (_showControls || _isBuffering) ? 0 : -140,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          border: const Border(
            top: BorderSide(color: AppColors.borderSubtle, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Channel info row
            if (_currentChannel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.transparent,
                      ),
                      child: _currentChannel!.logo.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: CachedNetworkImage(
                                imageUrl: _currentChannel!.logo,
                                fit: BoxFit.contain,
                                fadeInDuration: Duration.zero,
                                fadeOutDuration: Duration.zero,
                                placeholder: (context, url) => _buildSquareInitials(_currentChannel!, fontSize: 16),
                                errorWidget: (context, url, error) => _buildSquareInitials(_currentChannel!, fontSize: 16),
                              ),
                            )
                          : _buildSquareInitials(_currentChannel!, fontSize: 16),
                    ),
                    const SizedBox(width: 16),
                    if (_showNumberWithName)
                      Text('CH ${_currentChannel!.number.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: AppColors.accentCyan, fontSize: 20, fontWeight: FontWeight.w900)),
                    if (_showNumberWithName)
                      const SizedBox(width: 14),
                    Text(_currentChannel!.name,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text('LIVE',
                          style: TextStyle(color: AppColors.accentRed, fontSize: 8, fontWeight: FontWeight.w800)),
                    ),
                    const Spacer(),
                    // Favorite toggle
                    IconButton(
                      icon: Icon(
                        _favorites.contains(_currentChannel!.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: _favorites.contains(_currentChannel!.id) ? AppColors.accentRed : AppColors.textMuted,
                        size: 18,
                      ),
                      onPressed: () => _toggleFavorite(_currentChannel!.id),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            
            // Hide progress bar as requested
            const SizedBox(height: 8),

            // Controls row
            Row(
              children: [
                _ControlBtn(icon: Icons.skip_previous_rounded, onPressed: _prevChannel),
                _ControlBtn(
                  icon: _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  onPressed: _togglePlayPause,
                ),
                _ControlBtn(icon: Icons.skip_next_rounded, onPressed: _nextChannel),
                const Spacer(),
                _ControlBtn(
                  icon: _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  onPressed: _toggleMute,
                ),
                // Volume slider
                SizedBox(
                  width: 100,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppColors.accentCyan,
                      inactiveTrackColor: AppColors.bgElevated,
                      thumbColor: AppColors.accentCyan,
                      overlayColor: AppColors.accentCyan.withOpacity(0.2),
                    ),
                    child: Slider(
                      value: _volume.toDouble(),
                      min: 0,
                      max: 100,
                      onChanged: (v) {
                        setState(() => _volume = v.round());
                        _player.setVolume(_isMuted ? 0 : v);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Go Live button
                Tooltip(
                  message: 'Go Live',
                  child: GestureDetector(
                    onTap: () {
                      if (_currentChannel != null) _playChannel(_currentChannel!);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppColors.accentRed.withOpacity(0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, color: AppColors.accentRed, size: 7),
                          SizedBox(width: 5),
                          Text('LIVE', style: TextStyle(color: AppColors.accentRed, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
                        ],
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: _isMiniPlayer ? 'Exit Mini-Player' : 'Mini-Player Mode',
                  child: _ControlBtn(
                    icon: _isMiniPlayer ? Icons.picture_in_picture_rounded : Icons.open_in_new_rounded,
                    onPressed: _toggleMiniPlayer,
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: _isFullscreen ? 'Exit Full Screen' : 'Full Screen',
                  child: _ControlBtn(
                    icon: _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                    onPressed: _toggleFullscreen,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuide() {
    var filteredChannels = _selectedCategory == 'favorites'
        ? _channelService.channels.where((c) => c.hasStream && _favorites.contains(c.id)).toList()
        : _channelService.getByCategory(_selectedCategory);

    if (_guideSearchQuery.isNotEmpty) {
      filteredChannels = filteredChannels.where((c) =>
          c.name.toLowerCase().contains(_guideSearchQuery.toLowerCase()) ||
          c.number.toString().contains(_guideSearchQuery)
      ).toList();
    }

    return AnimatedPositioned(
      duration: AppDurations.normal,
      curve: Curves.easeOutQuart,
      top: 0,
      left: _showGuide ? 0 : -450,
      bottom: 0,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          boxShadow: [
            if (_showGuide) BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40),
          ],
        ),
        child: Material(
          color: AppColors.bgPrimary.withOpacity(0.96),
          child: Column(
            children: [
              // Guide header
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text('TV GUIDE',
                            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
                          onPressed: () => setState(() => _showGuide = false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Search channels...',
                        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textMuted, size: 18),
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.bgElevated.withOpacity(0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(5),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onChanged: (v) => setState(() => _guideSearchQuery = v),
                    ),
                  ],
                ),
              ),
              // Category pills
              SizedBox(
                height: 36,
                child: Listener(
                  onPointerSignal: (pointerSignal) {
                    if (pointerSignal is PointerScrollEvent) {
                      final newOffset = _categoryScrollController.offset + pointerSignal.scrollDelta.dy;
                      _categoryScrollController.jumpTo(
                        newOffset.clamp(0.0, _categoryScrollController.position.maxScrollExtent),
                      );
                    }
                  },
                  child: ListView.separated(
                    controller: _categoryScrollController,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: ChannelService.categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final cat = ChannelService.categories[i];
                      final selected = cat.id == _selectedCategory;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedCategory = cat.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.accentCyan : AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: selected ? AppColors.accentCyan : AppColors.borderSubtle),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cat.icon, size: 14, color: selected ? AppColors.bgDeepest : AppColors.textSecondary),
                              const SizedBox(width: 8),
                              Text(cat.name,
                                  style: TextStyle(
                                    color: selected ? AppColors.bgDeepest : AppColors.textSecondary,
                                    fontSize: 11, fontWeight: FontWeight.w600,
                                  )),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Channel list
              Expanded(
                child: Stack(
                  children: [
                    filteredChannels.isEmpty
                        ? const Center(child: Text('No channels available', style: TextStyle(color: AppColors.textMuted)))
                        : ListView.builder(
                            controller: _guideScrollController,
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                            itemCount: filteredChannels.length,
                            itemBuilder: (_, i) {
                              final ch = filteredChannels[i];
                              final isActive = _currentChannel?.id == ch.id;
                              return GestureDetector(
                                onTap: () {
                                  _switchChannel(ch);
                                  setState(() => _showGuide = false);
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isActive ? AppColors.accentCyan.withOpacity(0.1) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(AppRadius.sm),
                                    border: isActive ? Border.all(color: AppColors.accentCyan.withOpacity(0.3)) : null,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 42,
                                        child: Text('${ch.number}',
                                            style: TextStyle(
                                              color: isActive ? AppColors.accentCyan : AppColors.textMuted,
                                              fontSize: 13, fontWeight: FontWeight.w700,
                                            )),
                                      ),
                                      const SizedBox(width: 12),
                                      Container(
                                        width: 44, height: 44,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      color: Colors.transparent,
                                    ),
                                    child: ch.logo.isNotEmpty
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(6),
                                            child: CachedNetworkImage(
                                              imageUrl: ch.logo,
                                              fit: BoxFit.contain,
                                              fadeInDuration: Duration.zero,
                                              fadeOutDuration: Duration.zero,
                                              placeholder: (context, url) => _buildSquareInitials(ch, fontSize: 12),
                                              errorWidget: (context, url, error) => _buildSquareInitials(ch, fontSize: 12),
                                            ),
                                          )
                                        : _buildSquareInitials(ch, fontSize: 12),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(ch.name,
                                            style: TextStyle(
                                              color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
                                              fontSize: 14, fontWeight: FontWeight.w700,
                                            ), maxLines: 1, overflow: TextOverflow.ellipsis),
                                        Text(ch.language,
                                            style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
                                      ],
                                    ),
                                  ),
                                  if (isActive)
                                    Container(
                                      width: 6, height: 6,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.accentGreen,
                                        boxShadow: [BoxShadow(color: AppColors.accentGreen, blurRadius: 6)],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    if (_currentChannel != null)
                      Positioned(
                        bottom: 24,
                        right: 24,
                        child: FloatingActionButton.small(
                          onPressed: () {
                            final idx = filteredChannels.indexWhere((c) => c.id == _currentChannel!.id);
                            if (idx != -1 && _guideScrollController.hasClients) {
                              const itemHeight = 70.0; // 44(icon) + 20(padding) + 6(margin)
                              final viewportHeight = _guideScrollController.position.viewportDimension;
                              final targetOffset = (idx * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);

                              _guideScrollController.animateTo(
                                targetOffset.clamp(0.0, _guideScrollController.position.maxScrollExtent),
                                duration: AppDurations.normal,
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                          backgroundColor: AppColors.accentCyan,
                          child: const Icon(Icons.my_location_rounded, color: AppColors.bgDeepest, size: 18),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFavoritesPanel() {
    final favChannels = _channelService.channels
        .where((c) => c.hasStream && _favorites.contains(c.id))
        .toList();

    return Center(
      child: Material(
        color: AppColors.bgCard.withOpacity(0.95),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: MediaQuery.of(context).size.width * 0.75,
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40),
            ],
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle, width: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.favorite_rounded, color: AppColors.accentRed, size: 20),
                    const SizedBox(width: 12),
                    const Text('FAVORITE CHANNELS',
                        style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: favChannels.isEmpty
                    ? const Center(child: Text('No favorites yet', style: TextStyle(color: AppColors.textMuted)))
                    : GridView.builder(
                        padding: const EdgeInsets.all(24),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 20,
                          childAspectRatio: 0.85,
                        ),
                        itemCount: favChannels.length,
                        itemBuilder: (_, i) {
                          final ch = favChannels[i];
                          final isActive = _currentChannel?.id == ch.id;
                          return GestureDetector(
                            onTap: () {
                              _switchChannel(ch);
                              Navigator.of(context).pop();
                            },
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isActive ? AppColors.accentCyan.withOpacity(0.15) : AppColors.bgElevated.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(AppRadius.lg),
                                border: Border.all(
                                  color: isActive ? AppColors.accentCyan.withOpacity(0.5) : AppColors.borderSubtle,
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Container(
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: Colors.transparent,
                                      ),
                                      child: ch.logo.isNotEmpty
                                          ? ClipRRect(
                                              borderRadius: BorderRadius.circular(8),
                                              child: CachedNetworkImage(
                                                imageUrl: ch.logo,
                                                fit: BoxFit.contain,
                                                fadeInDuration: Duration.zero,
                                                fadeOutDuration: Duration.zero,
                                                placeholder: (context, url) => _buildSquareInitials(ch, fontSize: 16),
                                                errorWidget: (context, url, error) => _buildSquareInitials(ch, fontSize: 16),
                                              ),
                                            )
                                          : _buildSquareInitials(ch, fontSize: 16),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(ch.name,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
                                        fontSize: 13, fontWeight: FontWeight.w800,
                                      ), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text('CH ${ch.number}',
                                      style: const TextStyle(color: AppColors.accentCyan, fontSize: 10, fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchOverlay() {
    return StatefulBuilder(
      builder: (context, setSearchState) {
        final results = _searchQuery.isNotEmpty ? _channelService.search(_searchQuery) : <Channel>[];
        return Center(
          child: Material(
            color: AppColors.bgCard.withOpacity(0.95),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            clipBehavior: Clip.antiAlias,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.65,
              height: MediaQuery.of(context).size.height * 0.7,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            autofocus: true,
                            style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
                            decoration: InputDecoration(
                              hintText: 'Search channels...',
                              hintStyle: const TextStyle(color: AppColors.textMuted),
                              prefixIcon: const Icon(Icons.search_rounded, color: AppColors.accentCyan),
                              filled: true,
                              fillColor: AppColors.bgElevated,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadius.md),
                                borderSide: const BorderSide(color: AppColors.borderSubtle),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadius.md),
                                borderSide: const BorderSide(color: AppColors.borderSubtle),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadius.md),
                                borderSide: const BorderSide(color: AppColors.accentCyan),
                              ),
                            ),
                            onChanged: (v) {
                              setSearchState(() => _searchQuery = v);
                              setState(() => _searchQuery = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 28),
                          onPressed: () {
                            Navigator.of(context).pop();
                            setState(() {
                              _showSearch = false;
                              _searchQuery = '';
                            });
                            _mainFocus.requestFocus();
                          },
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final ch = results[i];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: AppColors.bgElevated.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.transparent,
                              ),
                              child: ch.logo.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: CachedNetworkImage(
                                        imageUrl: ch.logo,
                                        fit: BoxFit.contain,
                                        fadeInDuration: Duration.zero,
                                        fadeOutDuration: Duration.zero,
                                        placeholder: (context, url) => _buildSquareInitials(ch, fontSize: 12),
                                        errorWidget: (context, url, error) => _buildSquareInitials(ch, fontSize: 12),
                                      ),
                                    )
                                  : _buildSquareInitials(ch, fontSize: 12),
                            ),
                            title: Text(ch.name, style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                            subtitle: Text('CH ${ch.number} • ${ch.language}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                            trailing: IconButton(
                              icon: Icon(
                                _favorites.contains(ch.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                color: _favorites.contains(ch.id) ? AppColors.accentRed : AppColors.textMuted,
                                size: 20,
                              ),
                              onPressed: () => _toggleFavorite(ch.id),
                            ),
                            onTap: () {
                              _switchChannel(ch);
                              Navigator.of(context).pop();
                              setState(() {
                                _showSearch = false;
                                _searchQuery = '';
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    );
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return AppColors.bgElevated;
    }
  }

  Widget _buildSquareInitials(Channel ch, {double fontSize = 11}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Text(
          ch.initials,
          style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return StatefulBuilder(
      builder: (context, setPanelState) {
        return DefaultTabController(
          length: 3,
          child: Center(
            child: Material(
              color: AppColors.bgCard.withOpacity(0.95),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              clipBehavior: Clip.antiAlias,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.75,
                height: MediaQuery.of(context).size.height * 0.75,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40),
                  ],
                ),
                child: Column(
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: AppColors.borderSubtle, width: 0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.settings_rounded, color: AppColors.accentCyan, size: 20),
                          const SizedBox(width: 12),
                          const Text('SETTINGS',
                              style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
                            onPressed: () {
                              Navigator.of(context).pop();
                              setState(() => _showSettings = false);
                              _mainFocus.requestFocus();
                            },
                          ),
                        ],
                      ),
                    ),
                    // Main Content with Vertical Tabs
                    Expanded(
                      child: Row(
                        children: [
                          // Left Sidebar (Vertical Tabs)
                          Container(
                            width: 200,
                            decoration: const BoxDecoration(
                              border: Border(right: BorderSide(color: AppColors.borderSubtle, width: 0.5)),
                            ),
                            child: Builder(builder: (context) {
                              final controller = DefaultTabController.of(context);
                              return AnimatedBuilder(
                                animation: controller,
                                builder: (context, _) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      _buildVerticalTab(controller, 0, 'GENERAL', Icons.tune_rounded),
                                      _buildVerticalTab(controller, 1, 'SHORTCUTS', Icons.keyboard_rounded),
                                      _buildVerticalTab(controller, 2, 'UPDATES', Icons.system_update_rounded),
                                    ],
                                  );
                                }
                              );
                            }),
                          ),
                          // Right Content Area
                          Expanded(
                            child: TabBarView(
                              physics: const NeverScrollableScrollPhysics(), // Disable swiping
                              children: [
                                // General Settings
                                ListView(
                                  padding: const EdgeInsets.all(32),
                                  children: [
                                    _buildSettingRow(
                                      'Show Channel in Taskbar',
                                      'Displays current channel name in window title (e.g. NDTV - TV)',
                                      _showChannelInTaskbar,
                                      (v) => setPanelState(() {
                                        setState(() {
                                          _showChannelInTaskbar = v;
                                          _saveSetting('settings_taskbar_name', v);
                                        });
                                      }),
                                    ),
                                    const SizedBox(height: 24),
                                    _buildSettingRow(
                                      'Auto-Retry on Failure',
                                      'Automatically reloads stream if stuck for more than 5 seconds',
                                      _autoRetry,
                                      (v) => setPanelState(() {
                                        setState(() {
                                          _autoRetry = v;
                                          _saveSetting('settings_auto_retry', v);
                                        });
                                      }),
                                    ),
                                    const SizedBox(height: 24),
                                    _buildSettingRow(
                                      'External-style Badge',
                                      'Show floating channel badge at bottom center when windowed',
                                      _showMiniBadge,
                                      (v) => setPanelState(() {
                                        setState(() {
                                          _showMiniBadge = v;
                                          _saveSetting('settings_mini_badge', v);
                                        });
                                      }),
                                    ),
                                    const SizedBox(height: 24),
                                    _buildSettingRow(
                                      'Show Channel Number',
                                      'Include "CH XX" prefix in player info and window title',
                                      _showNumberWithName,
                                      (v) => setPanelState(() {
                                        setState(() {
                                          _showNumberWithName = v;
                                          _saveSetting('settings_number_name', v);
                                          _updateWindowTitle();
                                        });
                                      }),
                                    ),
                                    const SizedBox(height: 24),
                                    _buildSettingRow(
                                      'Hardware Acceleration',
                                      'Use GPU for smoother video playback',
                                      true,
                                      null, // Locked for now
                                    ),
                                    const SizedBox(height: 24),
                                    _buildSettingRow(
                                      'Low Latency Mode',
                                      'Optimizes for faster channel switching',
                                      true,
                                      null, // Already implemented globally
                                    ),
                                  ],
                                ),
                                // Shortcuts
                                ListView(
                                  padding: const EdgeInsets.all(32),
                                  children: [
                                    _buildShortcutItem('UP / DOWN', 'Change Channel'),
                                    _buildShortcutItem('LEFT / RIGHT', 'Adjust Volume'),
                                    _buildShortcutItem('SPACE / ENTER', 'Play / Pause'),
                                    _buildShortcutItem('M', 'Mute / Unmute'),
                                    _buildShortcutItem('F', 'Toggle Fullscreen'),
                                    _buildShortcutItem('G', 'TV Guide'),
                                    _buildShortcutItem('S', 'Search Channels'),
                                    _buildShortcutItem('I', 'Settings'),
                                    _buildShortcutItem('ESC', 'Close Overlays'),
                                    _buildShortcutItem('0-9', 'Direct Channel Input'),
                                  ],
                                ),
                                // Updates
                                Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.check_circle_outline_rounded, size: 64, color: AppColors.accentGreen),
                                      const SizedBox(height: 24),
                                      const Text('Software is up to date',
                                          style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 8),
                                      const Text('Current Version: 2.0.0',
                                          style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
                                      const SizedBox(height: 32),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppColors.accentCyan,
                                          foregroundColor: AppColors.bgDeepest,
                                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                        onPressed: () {
                                          showDialog(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              backgroundColor: AppColors.bgCard,
                                              title: const Text('Check for Updates', style: TextStyle(color: AppColors.textPrimary)),
                                              content: const Text('You are using the latest version.', style: TextStyle(color: AppColors.textSecondary)),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.of(ctx).pop(),
                                                  child: const Text('OK', style: TextStyle(color: AppColors.accentCyan)),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                        child: const Text('Check for Updates', style: TextStyle(fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVerticalTab(TabController controller, int index, String label, IconData icon) {
    final isSelected = controller.index == index;
    return InkWell(
      onTap: () => controller.animateTo(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isSelected ? AppColors.accentCyan : Colors.transparent,
              width: 4,
            ),
          ),
          color: isSelected ? AppColors.accentCyan.withOpacity(0.05) : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: isSelected ? AppColors.accentCyan : AppColors.textMuted),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppColors.accentCyan : AppColors.textMuted,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingRow(String title, String subtitle, bool value, ValueChanged<bool>? onChanged) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.accentCyan,
          activeTrackColor: AppColors.accentCyan.withOpacity(0.3),
        ),
      ],
    );
  }

  Widget _buildShortcutItem(String keys, String action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.bgElevated,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Text(keys, style: const TextStyle(color: AppColors.accentCyan, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          ),
          const SizedBox(width: 16),
          Text(action, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}

class _TopBarBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  const _TopBarBtn({required this.icon, required this.tooltip, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color ?? AppColors.textSecondary),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      splashRadius: 16,
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _ControlBtn({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: AppColors.textPrimary, size: 22),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
    );
  }
}

class _SocialLink extends StatelessWidget {
  final String icon;
  final String label;
  final String url;

  const _SocialLink({required this.icon, required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(url)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              alignment: Alignment.center,
              child: Text(icon, style: const TextStyle(color: Colors.white, fontSize: 20)),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
