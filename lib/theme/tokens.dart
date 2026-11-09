import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 设计稿色板：浅色为主，深色为 [VColors.dark]。
@immutable
class VColors extends ThemeExtension<VColors> {
  const VColors({
    required this.bg,
    required this.surface,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
    required this.blue,
    required this.blueInk,
    required this.blueTrack,
    required this.mint,
    required this.mintInk,
    required this.green,
    required this.greenInk,
    required this.purple,
    required this.purpleInk,
    required this.sky,
    required this.skyInk,
    required this.peach,
    required this.peachInk,
    required this.pink,
    required this.pinkInk,
    required this.lime,
    required this.limeInk,
    required this.grey,
    required this.greyInk,
    required this.danger,
    required this.warn,
    required this.warnInk,
    required this.heartInk,
    required this.tintGreen,
    required this.tintBlue,
    required this.tintPeach,
    required this.tintPurple,
    required this.tintSky,
    required this.tintGrey,
    required this.tintHeart,
    required this.barTrack,
    required this.mapRoad,
    required this.mapThumb,
    required this.glass,
  });

  final Color bg;
  final Color surface;
  final Color ink;
  final Color ink2;
  final Color muted;
  final Color line;
  final Color blue;
  final Color blueInk;
  final Color blueTrack;
  final Color mint;
  final Color mintInk;
  final Color green;
  final Color greenInk;
  final Color purple;
  final Color purpleInk;
  final Color sky;
  final Color skyInk;
  final Color peach;
  final Color peachInk;
  final Color pink;
  final Color pinkInk;
  final Color lime;
  final Color limeInk;
  final Color grey;
  final Color greyInk;
  final Color danger;
  final Color warn;
  final Color warnInk;
  final Color heartInk;
  final Color tintGreen;
  final Color tintBlue;
  final Color tintPeach;
  final Color tintPurple;
  final Color tintSky;
  final Color tintGrey;
  final Color tintHeart;
  final Color barTrack;
  final Color mapRoad;
  final Color mapThumb;
  final Color glass;

  bool get isDark => bg.computeLuminance() < 0.2;

  static const light = VColors(
    bg: Color(0xFFEDF0F8),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF101318),
    ink2: Color(0xFF596273),
    muted: Color(0xFF8A93A4),
    line: Color(0x12101318),
    blue: Color(0xFF3B63F0),
    blueInk: Color(0xFF1E3DA8),
    blueTrack: Color(0xFFC9D6FB),
    mint: Color(0xFFB4EDE0),
    mintInk: Color(0xFF0B5A4C),
    green: Color(0xFFC9E9BF),
    greenInk: Color(0xFF2E5C2A),
    purple: Color(0xFFEADCFB),
    purpleInk: Color(0xFF4B2F78),
    sky: Color(0xFFD8EAFB),
    skyInk: Color(0xFF174A73),
    peach: Color(0xFFFBE3CF),
    peachInk: Color(0xFF7A4318),
    pink: Color(0xFFFBDDE8),
    pinkInk: Color(0xFF7C2A47),
    lime: Color(0xFFDCEFCB),
    limeInk: Color(0xFF3F6128),
    grey: Color(0xFFE2E5EB),
    greyInk: Color(0xFF3C424C),
    danger: Color(0xFFE5484D),
    warn: Color(0xFFD97A12),
    warnInk: Color(0xFF8A4E05),
    heartInk: Color(0xFFD9364A),
    tintGreen: Color(0xFFDCF3D4),
    tintBlue: Color(0xFFE3EAFF),
    tintPeach: Color(0xFFFCEBCF),
    tintPurple: Color(0xFFEBDFFC),
    tintSky: Color(0xFFD8EAFB),
    tintGrey: Color(0xFFEFF2F8),
    tintHeart: Color(0xFFFDE7EA),
    barTrack: Color(0xFFDDE4F6),
    mapRoad: Color(0xFFFFFFFF),
    mapThumb: Color(0xFFE7EBEE),
    glass: Color(0x80FFFFFF),
  );

  static const dark = VColors(
    bg: Color(0xFF0C1322),
    surface: Color(0xFF121B2C),
    ink: Color(0xFFEAF0FA),
    ink2: Color(0xFFAAB8CE),
    muted: Color(0xFF7E8DA6),
    line: Color(0x14FFFFFF),
    blue: Color(0xFF5B7CFF),
    blueInk: Color(0xFFA9BBFF),
    blueTrack: Color(0xFF25345A),
    mint: Color(0xFF10352E),
    mintInk: Color(0xFF8FE3D1),
    green: Color(0xFF20351A),
    greenInk: Color(0xFFB7E6A4),
    purple: Color(0xFF2B2140),
    purpleInk: Color(0xFFD6BFFB),
    sky: Color(0xFF14283E),
    skyInk: Color(0xFFA9D4F7),
    peach: Color(0xFF39281A),
    peachInk: Color(0xFFF6C79B),
    pink: Color(0xFF3A2029),
    pinkInk: Color(0xFFF8B7CD),
    lime: Color(0xFF2A3317),
    limeInk: Color(0xFFD3EB9F),
    grey: Color(0xFF202631),
    greyInk: Color(0xFFC6CDD9),
    danger: Color(0xFFE5484D),
    warn: Color(0xFFD97A12),
    warnInk: Color(0xFFF3C989),
    heartInk: Color(0xFFFF7A8B),
    tintGreen: Color(0xFF22371B),
    tintBlue: Color(0xFF1D2C55),
    tintPeach: Color(0xFF3A2A18),
    tintPurple: Color(0xFF2B2140),
    tintSky: Color(0xFF14283E),
    tintGrey: Color(0xFF1A2436),
    tintHeart: Color(0xFF3A1B22),
    barTrack: Color(0xFF24314A),
    mapRoad: Color(0xFF2A3B55),
    mapThumb: Color(0xFF172235),
    glass: Color(0x1FFFFFFF),
  );

  @override
  VColors copyWith({Color? bg, Color? surface, Color? ink}) => this;

  @override
  VColors lerp(ThemeExtension<VColors>? other, double t) =>
      other is VColors ? other : this;
}

extension VColorsContext on BuildContext {
  VColors get v => Theme.of(this).extension<VColors>()!;
}

class VText {
  static const h1 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
    height: 1.15,
  );
  static const h2 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const h3 = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );
  static const body = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    height: 1.55,
  );
  static const meta = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );
  static const label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );
  static const value = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );
  static const big = TextStyle(
    fontSize: 44,
    fontWeight: FontWeight.w700,
    letterSpacing: -2.0,
    height: 1.0,
  );
  static const num = TextStyle(
    fontSize: 46,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.2,
    height: 1.0,
  );
}

ThemeData buildTheme(Brightness brightness) {
  final v = brightness == Brightness.dark ? VColors.dark : VColors.light;
  final scheme = ColorScheme.fromSeed(seedColor: v.blue, brightness: brightness)
      .copyWith(
        surface: v.surface,
        primary: v.blue,
        onPrimary: Colors.white,
        error: v.danger,
      );
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: scheme,
  );
  return base.copyWith(
    scaffoldBackgroundColor: v.bg,
    extensions: [v],
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(bodyColor: v.ink, displayColor: v.ink),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
