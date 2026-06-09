import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../utils/constants.dart';

/// Custom window title bar with minimize, maximize/restore, close buttons
/// Styled to match the TV app's premium dark theme
class WindowTitleBar extends StatefulWidget implements PreferredSizeWidget {
  final bool showLogo;
  final Widget? trailing;
  final double height;

  const WindowTitleBar({
    super.key,
    this.showLogo = true,
    this.trailing,
    this.height = 40,
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _checkMaximized();
  }

  Future<void> _checkMaximized() async {
    _isMaximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (_isMaximized) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
        _checkMaximized();
      },
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: AppColors.bgDeepest.withOpacity(0.95),
          border: const Border(
            bottom: BorderSide(color: AppColors.borderSubtle, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            // Logo
            if (widget.showLogo) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(
                    colors: [
                      AppColors.accentCyan.withOpacity(0.1),
                      Colors.transparent,
                    ],
                  ),
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
                          BoxShadow(
                            color: AppColors.accentRed,
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'TV',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Spacer(),
            if (widget.trailing != null) widget.trailing!,
            // Window control buttons
            _WindowButton(
              icon: Icons.minimize_rounded,
              onPressed: () => windowManager.minimize(),
              hoverColor: AppColors.bgElevated,
            ),
            _WindowButton(
              icon: _isMaximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              iconSize: _isMaximized ? 14 : 16,
              onPressed: () async {
                if (_isMaximized) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
                _checkMaximized();
              },
              hoverColor: AppColors.bgElevated,
            ),
            _WindowButton(
              icon: Icons.close_rounded,
              onPressed: () => windowManager.close(),
              hoverColor: AppColors.accentRed,
              hoverIconColor: Colors.white,
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color hoverColor;
  final Color? hoverIconColor;
  final double iconSize;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.hoverColor,
    this.hoverIconColor,
    this.iconSize = 16,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          width: 46,
          height: 40,
          color: _hovered ? widget.hoverColor : Colors.transparent,
          child: Center(
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hovered
                  ? (widget.hoverIconColor ?? AppColors.textPrimary)
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
