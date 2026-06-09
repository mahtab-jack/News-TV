import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// Premium TV loading/buffering overlay with animated effects
import '../models/channel.dart';

/// Premium TV loading/buffering overlay with animated effects
class LoadingOverlay extends StatefulWidget {
  final bool isLoading;
  final String message;
  final bool showStatic; // Show TV static noise effect
  final Channel? channel; // Channel logo to show in center

  const LoadingOverlay({
    super.key,
    required this.isLoading,
    this.message = 'Buffering...',
    this.showStatic = false,
    this.channel,
  });

  @override
  State<LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<LoadingOverlay>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late AnimationController _staticController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _staticController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    )..repeat();

    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    _staticController.dispose();
    super.dispose();
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return AppColors.bgElevated;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: widget.isLoading ? 1.0 : 0.0,
      duration: AppDurations.normal,
      child: IgnorePointer(
        ignoring: !widget.isLoading,
        child: Container(
          color: AppColors.bgDeepest.withOpacity(0.85),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated loading ring with center logo
                Stack(
                  alignment: Alignment.center,
                  children: [
                    if (widget.channel != null)
                      Container(
                        width: 46,
                        height: 46,
                        decoration: const BoxDecoration(
                          color: Colors.transparent,
                        ),
                        child: widget.channel!.logo.isNotEmpty
                            ? Image.network(
                                widget.channel!.logo,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => Center(
                                  child: Text(
                                    widget.channel!.initials,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              )
                            : Center(
                                child: Text(
                                  widget.channel!.initials,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                      ),
                    SizedBox(
                      width: 80,
                      height: 80,
                      child: AnimatedBuilder(
                        animation: _rotateController,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle: _rotateController.value * 2 * pi,
                            child: child,
                          );
                        },
                        child: CustomPaint(
                          painter: _LoadingRingPainter(
                            animation: _pulseAnim,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Loading text
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, _) {
                    return Opacity(
                      opacity: _pulseAnim.value,
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 1.5,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingRingPainter extends CustomPainter {
  final Animation<double> animation;

  _LoadingRingPainter({required this.animation}) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Background ring
    final bgPaint = Paint()
      ..color = AppColors.bgElevated
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, bgPaint);

    // Animated arc
    final arcPaint = Paint()
      ..shader = const SweepGradient(
        colors: [
          Colors.transparent,
          AppColors.accentCyan,
        ],
        stops: [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      pi * 1.5,
      false,
      arcPaint,
    );

    // Glow dot at the end
    final dotAngle = -pi / 2 + pi * 1.5;
    final dotX = center.dx + radius * cos(dotAngle);
    final dotY = center.dy + radius * sin(dotAngle);

    final glowPaint = Paint()
      ..color = AppColors.accentCyan.withOpacity(0.5 * animation.value)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(dotX, dotY), 6, glowPaint);

    final dotPaint = Paint()..color = AppColors.accentCyan;
    canvas.drawCircle(Offset(dotX, dotY), 3, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Error overlay for when stream fails
class ErrorOverlay extends StatelessWidget {
  final bool isVisible;
  final String message;
  final VoidCallback? onRetry;

  const ErrorOverlay({
    super.key,
    required this.isVisible,
    this.message = 'Failed to load stream',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: isVisible ? 1.0 : 0.0,
      duration: AppDurations.normal,
      child: IgnorePointer(
        ignoring: !isVisible,
        child: Container(
          color: AppColors.bgDeepest.withOpacity(0.9),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accentRed.withOpacity(0.1),
                    border: Border.all(
                      color: AppColors.accentRed.withOpacity(0.3),
                    ),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.accentRed,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
                if (onRetry != null)
                  ElevatedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry Feed'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentCyan,
                      foregroundColor: AppColors.bgDeepest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
