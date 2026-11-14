import 'package:flutter/material.dart';

/// The three themes, named after the films. Default is [RappTheme.matrix].
enum RappTheme { avatar, matrix, westworld }

const themeOrder = [
  RappTheme.avatar,
  RappTheme.matrix,
  RappTheme.westworld,
];

String themeLabel(RappTheme t) => switch (t) {
  RappTheme.avatar => 'AVATAR',
  RappTheme.matrix => 'MATRIX',
  RappTheme.westworld => 'WESTWORLD',
};

/// Colour / shape tokens (design language section 4). Components read these
/// and never hard-code colours.
@immutable
class RappTokens extends ThemeExtension<RappTokens> {
  const RappTokens({
    required this.bg,
    required this.panel,
    required this.raise,
    required this.line,
    required this.text,
    required this.muted,
    required this.on,
    required this.accent,
    required this.accentInk,
    required this.tint,
    required this.r,
    required this.glow,
    required this.textGlow,
    required this.font,
    required this.fontFallback,
    required this.mono,
    required this.monoFallback,
    required this.monoBody,
    required this.labelSpacing,
  });

  final Color bg, line, text, muted, on, accent, accentInk, tint;

  /// One colour = solid fill; two = top-to-bottom gradient.
  final List<Color> panel, raise;
  final double r;

  /// Halo around an active lamp.
  final List<BoxShadow> glow;

  /// Text glow; only MATRIX.
  final List<Shadow> textGlow;
  final String font;
  final List<String> fontFallback;
  final String mono;
  final List<String> monoFallback;

  /// Body text in the monospace font (MATRIX only).
  final bool monoBody;

  /// Letter spacing (em) for small headings.
  final double labelSpacing;

  static RappTokens of(BuildContext context) =>
      Theme.of(context).extension<RappTokens>()!;

  BoxDecoration _box(List<Color> fill, Color? border) {
    return BoxDecoration(
      color: fill.length == 1 ? fill.first : null,
      gradient: fill.length == 2
          ? LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: fill,
            )
          : null,
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: border ?? line),
    );
  }

  BoxDecoration panelBox({Color? border}) => _box(panel, border);
  BoxDecoration raiseBox({Color? border}) => _box(raise, border);

  @override
  RappTokens copyWith({Color? bg, Color? text}) => RappTokens(
    bg: bg ?? this.bg,
    panel: panel,
    raise: raise,
    line: line,
    text: text ?? this.text,
    muted: muted,
    on: on,
    accent: accent,
    accentInk: accentInk,
    tint: tint,
    r: r,
    glow: glow,
    textGlow: textGlow,
    font: font,
    fontFallback: fontFallback,
    mono: mono,
    monoFallback: monoFallback,
    monoBody: monoBody,
    labelSpacing: labelSpacing,
  );

  // Themes are switched discretely, not animated.
  @override
  RappTokens lerp(ThemeExtension<RappTokens>? other, double t) =>
      t < 0.5 || other is! RappTokens ? this : other;
}

const _font = 'Inter';
const _fontFallback = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Noto Sans SC',
  'Microsoft YaHei',
];
/// The top bar's height. The corners' scrims start below it, so a click on the other corner's
/// button switches corners in one click instead of being eaten by the scrim.
const topBarHeight = 56.0;

const _mono = 'JetBrains Mono';
const _monoFallback = ['SF Mono', 'Menlo', 'Consolas', 'monospace'];

List<BoxShadow> _lampGlow(Color c, {double alpha = .6, double blur = 8}) => [
  BoxShadow(color: c.withValues(alpha: alpha), blurRadius: blur),
];

/// Text glow goes on every text style, so buttons and dropdowns get it too.
TextTheme _withShadows(TextTheme tt, List<Shadow> s) {
  if (s.isEmpty) return tt;
  TextStyle? g(TextStyle? x) => x?.copyWith(shadows: s);
  return tt.copyWith(
    displayLarge: g(tt.displayLarge),
    displayMedium: g(tt.displayMedium),
    displaySmall: g(tt.displaySmall),
    headlineLarge: g(tt.headlineLarge),
    headlineMedium: g(tt.headlineMedium),
    headlineSmall: g(tt.headlineSmall),
    titleLarge: g(tt.titleLarge),
    titleMedium: g(tt.titleMedium),
    titleSmall: g(tt.titleSmall),
    bodyLarge: g(tt.bodyLarge),
    bodyMedium: g(tt.bodyMedium),
    bodySmall: g(tt.bodySmall),
    labelLarge: g(tt.labelLarge),
    labelMedium: g(tt.labelMedium),
    labelSmall: g(tt.labelSmall),
  );
}

RappTokens tokensFor(RappTheme theme) {
  switch (theme) {
    case RappTheme.matrix:
      const on = Color(0xFFB6FFC8);
      return RappTokens(
        bg: const Color(0xFF020A04),
        panel: const [Color(0xFF041208)],
        raise: const [Color(0xFF07200F)],
        line: const Color(0xFF176A33),
        text: const Color(0xFF7DFF9E),
        muted: const Color(0xFF3FBF68),
        on: on,
        accent: const Color(0xFFF2FFF5),
        accentInk: const Color(0xFF02240C),
        tint: const Color.fromRGBO(125, 255, 158, .17),
        r: 0,
        glow: _lampGlow(on),
        textGlow: const [
          Shadow(color: Color.fromRGBO(125, 255, 158, .55), blurRadius: 6),
        ],
        font: _font,
        fontFallback: _fontFallback,
        mono: _mono,
        monoFallback: _monoFallback,
        monoBody: true,
        labelSpacing: 0.06,
      );
    case RappTheme.avatar:
      const on = Color(0xFF6FE3FF);
      return RappTokens(
        bg: const Color(0xFF0C1418),
        panel: const [
          Color.fromRGBO(255, 255, 255, .035),
          Color.fromRGBO(255, 255, 255, .01),
        ],
        raise: const [
          Color.fromRGBO(150, 225, 255, .14),
          Color.fromRGBO(150, 225, 255, .07),
        ],
        line: const Color.fromRGBO(150, 225, 255, .45),
        text: const Color(0xFFE9FAFF),
        muted: const Color(0xFF93C9DD),
        on: on,
        accent: const Color(0xFFFF9A3D),
        accentInk: const Color(0xFF2A1400),
        tint: const Color.fromRGBO(255, 154, 61, .13),
        r: 4,
        glow: _lampGlow(on),
        textGlow: const [],
        font: _font,
        fontFallback: _fontFallback,
        mono: _mono,
        monoFallback: _monoFallback,
        monoBody: false,
        labelSpacing: 0.06,
      );
    case RappTheme.westworld:
      const on = Color(0xFFFFFFFF);
      return RappTokens(
        bg: const Color(0xFF070707),
        panel: const [Color(0xFF0E0E0E)],
        raise: const [Color(0xFF1A1A1A)],
        line: const Color(0xFF3A3A3A),
        text: const Color(0xFFF4F4F2),
        muted: const Color(0xFFA3A3A0),
        on: on,
        accent: const Color(0xFFFF3B30),
        accentInk: const Color(0xFF1A0000),
        tint: const Color.fromRGBO(255, 59, 48, .14),
        r: 2,
        glow: _lampGlow(on),
        textGlow: const [],
        font: _font,
        fontFallback: _fontFallback,
        mono: _mono,
        monoFallback: _monoFallback,
        monoBody: false,
        labelSpacing: 0.12,
      );
  }
}

ThemeData themeDataFor(RappTheme theme) {
  final t = tokensFor(theme);
  final family = t.monoBody ? t.mono : t.font;
  final fallback = t.monoBody ? t.monoFallback : t.fontFallback;
  final scheme = ColorScheme.dark(
    surface: t.bg,
    primary: t.text,
    onPrimary: t.bg,
    error: t.accent,
    onError: t.accentInk,
    outline: t.line,
    onSurface: t.text,
    onSurfaceVariant: t.muted,
  );
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.r)),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    fontFamily: family,
    fontFamilyFallback: fallback,
    textTheme: _withShadows(Typography.material2021().white
        .apply(
          fontFamily: family,
          fontFamilyFallback: fallback,
          bodyColor: t.text,
          displayColor: t.text,
        )
        .copyWith(
          bodyMedium: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: t.text,
            fontFamily: family,
            fontFamilyFallback: fallback,
          ),
        ), t.textGlow),
    filledButtonTheme: FilledButtonThemeData(style: button),
    elevatedButtonTheme: ElevatedButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    textButtonTheme: TextButtonThemeData(style: button),
    iconButtonTheme: IconButtonThemeData(style: button),
    extensions: [t],
  );
}
