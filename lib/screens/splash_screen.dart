import 'dart:math';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/constants.dart';

/// Premium TV boot/splash screen with animated logo and static noise effect
class SplashScreen extends StatefulWidget {
  final VoidCallback onComplete;
  final bool isTvReady;

  const SplashScreen({
    super.key,
    required this.onComplete,
    required this.isTvReady,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _glowController;
  late AnimationController _progressController;
  late AnimationController _staticController;
  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _glowAnim;
  late Animation<double> _progressAnim;
  String _statusText = 'Initializing...';

  @override
  void initState() {
    super.initState();

    _staticController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    )..repeat();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _logoScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: const Interval(0, 0.4)),
    );

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _progressAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _progressController, curve: Curves.easeInOut),
    );

    _startSequence();
  }

  void _startSequence() async {
    await Future.delayed(const Duration(milliseconds: 300));
    _logoController.forward();

    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _statusText = 'Starting server...');

    await Future.delayed(const Duration(milliseconds: 400));
    _progressController.forward();
    if (mounted) setState(() => _statusText = 'Loading channels...');

    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) setState(() => _statusText = 'Fetching streams...');

    // Wait until TvScreen is ready (i.e. first channel video starts playing)
    while (!widget.isTvReady) {
      if (mounted) setState(() => _statusText = 'Buffering stream...');
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (mounted) setState(() => _statusText = 'Ready');

    await Future.delayed(const Duration(milliseconds: 400));
    widget.onComplete();
  }

  @override
  void dispose() {
    _logoController.dispose();
    _glowController.dispose();
    _progressController.dispose();
    _staticController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeepest,
      body: Stack(
        children: [
          // TV static noise background
          AnimatedBuilder(
            animation: _staticController,
            builder: (context, _) {
              return Opacity(
                opacity: 0.03,
                child: CustomPaint(
                  size: MediaQuery.of(context).size,
                  painter: _StaticNoisePainter(
                    seed: (_staticController.value * 1000).toInt(),
                  ),
                ),
              );
            },
          ),

          // Scanlines effect
          CustomPaint(
            size: MediaQuery.of(context).size,
            painter: _ScanlinePainter(),
          ),

          // Main content
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated logo
                AnimatedBuilder(
                  animation: Listenable.merge([_logoController, _glowController]),
                  builder: (context, _) {
                    return Opacity(
                      opacity: _logoOpacity.value,
                      child: Transform.scale(
                        scale: _logoScale.value,
                        child: Column(
                          children: [
                            // Glow behind logo
                            Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.accentCyan
                                        .withOpacity(_glowAnim.value * 0.3),
                                    blurRadius: 60,
                                    spreadRadius: 20,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        AppColors.accentCyan.withOpacity(0.15),
                                        AppColors.bgDeepest,
                                      ],
                                    ),
                                    border: Border.all(
                                      color: AppColors.accentCyan.withOpacity(0.4),
                                      width: 2,
                                    ),
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.live_tv_rounded,
                                      color: AppColors.accentCyan,
                                      size: 36,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            // NEWS TV text
                            const Text(
                              'NEWS TV',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 36,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 6,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'LIVE TELEVISION',
                              style: TextStyle(
                                color: AppColors.accentCyan.withOpacity(0.7),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 60),

                // Progress bar
                AnimatedBuilder(
                  animation: _progressAnim,
                  builder: (context, _) {
                    return Column(
                      children: [
                        SizedBox(
                          width: 200,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _progressAnim.value,
                              minHeight: 2,
                              backgroundColor: AppColors.bgElevated,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.accentCyan,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _statusText,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticNoisePainter extends CustomPainter {
  final int seed;
  _StaticNoisePainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final paint = Paint();
    const step = 4.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        final v = random.nextInt(256);
        paint.color = Color.fromARGB(255, v, v, v);
        canvas.drawRect(Rect.fromLTWH(x, y, step, step), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StaticNoisePainter old) => old.seed != seed;
}

class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.03);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
