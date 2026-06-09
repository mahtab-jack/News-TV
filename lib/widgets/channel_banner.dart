import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../utils/constants.dart';
import '../models/channel.dart';

/// Channel switch OSD banner — slides in when channel changes
class ChannelBanner extends StatefulWidget {
  final Channel? channel;
  final bool visible;

  const ChannelBanner({super.key, this.channel, required this.visible});

  @override
  State<ChannelBanner> createState() => _ChannelBannerState();
}

class _ChannelBannerState extends State<ChannelBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnim;
  late Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.normal);
    _slideAnim = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _opacityAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(ChannelBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _controller.forward(from: 0);
    } else if (!widget.visible && oldWidget.visible) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.channel;
    if (ch == null) return const SizedBox.shrink();

    return Positioned(
      top: 60,
      left: 24,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _opacityAnim,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.bgCard.withOpacity(0.92),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.borderSubtle),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Channel logo or initials
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.transparent,
                    border: Border.all(
                      color: AppColors.accentCyan.withOpacity(0.5),
                      width: 1.5,
                    ),
                  ),
                  child: ch.logo.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: ch.logo,
                            fit: BoxFit.contain,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            placeholder: (context, url) => Center(
                              child: Text(
                                ch.initials,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            errorWidget: (context, url, error) => Center(
                              child: Text(
                                ch.initials,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            ch.initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'CH ${ch.number.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: AppColors.accentCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    Text(
                      ch.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                // LIVE badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.accentRed.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.accentRed.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accentRed,
                          boxShadow: [
                            BoxShadow(color: AppColors.accentRed, blurRadius: 6),
                          ],
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Text(
                        'LIVE',
                        style: TextStyle(
                          color: AppColors.accentRed,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
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
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return AppColors.bgElevated;
    }
  }
}

/// QR Code pairing dialog
class QrPairingDialog extends StatelessWidget {
  final String qrData;
  final String roomCode;
  final VoidCallback? onRegenerate;

  const QrPairingDialog({
    super.key,
    required this.qrData,
    required this.roomCode,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    // We'll use qr_flutter package for QR generation
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 380,
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
            // Header
            Row(
              children: [
                const Icon(Icons.phonelink_rounded,
                    color: AppColors.accentCyan, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Mobile Remote Control',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textMuted, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan this QR code with the News TV Remote app on your phone',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 24),

            // QR Code container
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accentCyan.withOpacity(0.1),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: SizedBox(
                width: 200,
                height: 200,
                child: _buildQrWidget(),
              ),
            ),
            const SizedBox(height: 20),

            // Room code display
            const Text(
              'CONNECTION CODE',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              roomCode.isNotEmpty ? roomCode : '------',
              style: const TextStyle(
                color: AppColors.accentCyan,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: 8,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),

            // Regenerate button
            if (onRegenerate != null)
              TextButton.icon(
                onPressed: onRegenerate,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Generate New Code'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accentCyan,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrWidget() {
    // Import qr_flutter in the actual implementation
    // For now, use a placeholder that will be replaced
    try {
      // This will work once qr_flutter is imported in the screen that uses this
      return const Center(
        child: Text('QR', style: TextStyle(color: Colors.black, fontSize: 24)),
      );
    } catch (_) {
      return const Center(child: CircularProgressIndicator());
    }
  }
}

/// Volume indicator OSD
class VolumeIndicator extends StatefulWidget {
  final int volume;
  final bool muted;
  final bool visible;

  const VolumeIndicator({
    super.key,
    required this.volume,
    required this.muted,
    required this.visible,
  });

  @override
  State<VolumeIndicator> createState() => _VolumeIndicatorState();
}

class _VolumeIndicatorState extends State<VolumeIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.fast);
    _opacity = Tween<double>(begin: 0, end: 1).animate(_controller);
  }

  @override
  void didUpdateWidget(VolumeIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 80,
      right: 32,
      child: FadeTransition(
        opacity: _opacity,
        child: Container(
          width: 50,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            color: AppColors.bgCard.withOpacity(0.9),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.muted
                    ? Icons.volume_off_rounded
                    : widget.volume > 50
                        ? Icons.volume_up_rounded
                        : Icons.volume_down_rounded,
                color: widget.muted ? AppColors.accentRed : AppColors.accentCyan,
                size: 20,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 100,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: widget.muted ? 0 : widget.volume / 100,
                      minHeight: 4,
                      backgroundColor: AppColors.bgElevated,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        widget.muted ? AppColors.accentRed : AppColors.accentCyan,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.muted ? 'M' : '${widget.volume}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
