import 'package:flutter/material.dart';

/// Design system constants for News TV
class AppColors {
  // Backgrounds
  static const Color bgDeepest = Color(0xFF060810);
  static const Color bgPrimary = Color(0xFF0A0D14);
  static const Color bgCard = Color(0xFF111520);
  static const Color bgElevated = Color(0xFF181D2A);
  static const Color bgSurface = Color(0xFF1E2436);
  static const Color bgGlass = Color(0x33111520);

  // Accents
  static const Color accentCyan = Color(0xFF00E5FF);
  static const Color accentCyanDim = Color(0xFF0097A7);
  static const Color accentRed = Color(0xFFFF3D57);
  static const Color accentGreen = Color(0xFF00E676);
  static const Color accentAmber = Color(0xFFFFB300);
  static const Color accentPurple = Color(0xFF7C4DFF);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF); // white70
  static const Color textMuted = Color(0x61FFFFFF); // white38
  static const Color textDim = Color(0x33FFFFFF); // white20

  // Borders
  static const Color borderSubtle = Color(0x1AFFFFFF); // white10
  static const Color borderLight = Color(0x33FFFFFF); // white20

  // Gradients
  static const LinearGradient bgGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgDeepest, bgPrimary],
  );

  static const LinearGradient cyanGradient = LinearGradient(
    colors: [Color(0xFF00E5FF), Color(0xFF00B8D4)],
  );

  static const LinearGradient redGradient = LinearGradient(
    colors: [Color(0xFFFF3D57), Color(0xFFD50032)],
  );

  static const RadialGradient glowCyan = RadialGradient(
    colors: [Color(0x4400E5FF), Color(0x0000E5FF)],
    radius: 0.8,
  );
}

class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double round = 100;
}

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class AppDurations {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration splash = Duration(milliseconds: 2500);
  static const Duration channelBanner = Duration(seconds: 4);
  static const Duration controlsAutoHide = Duration(seconds: 3);
}
