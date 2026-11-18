import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'system_font.dart';

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
    List<Color>? float,
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
    this.overviewArt,
    this.textSize = fallbackTextSize,
  }) : float = float ?? panel;

  final Color bg, line, text, muted, on, accent, accentInk, tint;

  /// One colour = solid fill; two = top-to-bottom gradient.
  final List<Color> panel, raise;

  /// What floats over the remote picture (menus, the writing panel): always opaque, since the
  /// picture under it may be any colour. Defaults to [panel] where that is opaque already.
  final List<Color> float;
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

  /// The one text size (the system's, see [systemTextSize]); only the big dashboard numbers differ.
  final double textSize;

  /// File name of the overview's bottom-right illustration, under [themeAssetDir].
  /// Null: the theme has none.
  final String? overviewArt;

  /// The asset key of [overviewArt], or null.
  String? get overviewArtAsset => overviewArt == null ? null : '$themeAssetDir/$overviewArt';

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
  BoxDecoration floatBox({Color? border}) => _box(float, border);

  @override
  RappTokens copyWith({Color? bg, Color? text, String? overviewArt, double? textSize}) => RappTokens(
    bg: bg ?? this.bg,
    panel: panel,
    raise: raise,
    float: float,
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
    overviewArt: overviewArt ?? this.overviewArt,
    textSize: textSize ?? this.textSize,
  );

  // Themes are switched discretely, not animated.
  @override
  RappTokens lerp(ThemeExtension<RappTokens>? other, double t) =>
      t < 0.5 || other is! RappTokens ? this : other;
}

/// Where theme images live (listed in pubspec.yaml).
const themeAssetDir = 'assets/themes';

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
        overviewArt: 'overview_matrix.png',
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
        // The glass panel is see-through, made for the dark backdrop; over a light remote
        // window it vanishes. Same look, but solid.
        float: const [Color(0xFF13222A), Color(0xFF0E181D)],
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
        overviewArt: 'overview_avatar.png',
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
        overviewArt: 'overview_westworld.png',
      );
  }
}

/// Every text style at [size] and one line height: one text size throughout (the dashboard
/// numbers set their own), and a switch row's title (bodyLarge, 1.5) no taller than the text beside it.
TextTheme _oneSize(TextTheme tt, double size) {
  TextStyle? z(TextStyle? x) => x?.copyWith(fontSize: size, height: 1.4);
  return tt.copyWith(
    displayLarge: z(tt.displayLarge),
    displayMedium: z(tt.displayMedium),
    displaySmall: z(tt.displaySmall),
    headlineLarge: z(tt.headlineLarge),
    headlineMedium: z(tt.headlineMedium),
    headlineSmall: z(tt.headlineSmall),
    titleLarge: z(tt.titleLarge),
    titleMedium: z(tt.titleMedium),
    titleSmall: z(tt.titleSmall),
    bodyLarge: z(tt.bodyLarge),
    bodyMedium: z(tt.bodyMedium),
    bodySmall: z(tt.bodySmall),
    labelLarge: z(tt.labelLarge),
    labelMedium: z(tt.labelMedium),
    labelSmall: z(tt.labelSmall),
  );
}

/// Whether [p] is driven by touch (iOS, Android) rather than a pointer.
bool touchPlatform(TargetPlatform p) => p == TargetPlatform.iOS || p == TargetPlatform.android;

/// The height of every clickable control: the 48 touch target, or 40 with a pointer.
double controlHeightFor(TargetPlatform p) => touchPlatform(p) ? 48 : 40;

/// [controlHeightFor] the platform of [c]'s theme.
double controlHeightOf(BuildContext c) => controlHeightFor(Theme.of(c).platform);

/// [textSize]: the system's text size ([systemTextSize]), used by every text style.
/// [platform]: sets the control height (see [controlHeightFor]); defaults to [defaultTargetPlatform].
ThemeData themeDataFor(RappTheme theme, {double textSize = fallbackTextSize, TargetPlatform? platform}) {
  final plat = platform ?? defaultTargetPlatform;
  final touch = touchPlatform(plat);
  final t = tokensFor(theme).copyWith(textSize: textSize);
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
  OutlineInputBorder outline(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.r),
        borderSide: BorderSide(color: c),
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
    platform: plat,
    visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
    materialTapTargetSize: touch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    fontFamily: family,
    fontFamilyFallback: fallback,
    textTheme: _withShadows(_oneSize(Typography.material2021().white
        .apply(
          fontFamily: family,
          fontFamilyFallback: fallback,
          bodyColor: t.text,
          displayColor: t.text,
        )
        .copyWith(
          bodyMedium: TextStyle(
            height: 1.4,
            color: t.text,
            fontFamily: family,
            fontFamilyFallback: fallback,
          ),
        ), textSize), t.textGlow),
    filledButtonTheme: FilledButtonThemeData(style: button),
    elevatedButtonTheme: ElevatedButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    textButtonTheme: TextButtonThemeData(style: button),
    iconButtonTheme: IconButtonThemeData(style: button),
    // Switch and checkbox rows as tall as a dropdown or a button (48 touch, 40 with a pointer via the
    // density), not Material's 56 / 72.
    listTileTheme: const ListTileThemeData(minTileHeight: 48, minVerticalPadding: 4),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentInk : t.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accent : t.line),
      trackOutlineColor: WidgetStatePropertyAll(t.line),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : Colors.transparent),
      checkColor: WidgetStatePropertyAll(t.accentInk),
      side: BorderSide(color: t.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.r / 2)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.r),
        side: BorderSide(color: t.text),
      ),
      elevation: 8,
      shadowColor: Colors.black,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      // A single line is at least as tall as a control (a multi-line field just grows); the
      // padding stays below that so the minimum decides, whatever the platform's text metrics.
      constraints: BoxConstraints(minHeight: controlHeightFor(plat)),
      contentPadding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: (controlHeightFor(plat) - textSize * 1.4) / 2,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      border: outline(t.line),
      enabledBorder: outline(t.line),
      focusedBorder: outline(t.text),
      errorBorder: outline(scheme.error),
      focusedErrorBorder: outline(scheme.error),
      errorStyle: TextStyle(color: scheme.error),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: t.accent,
      inactiveTrackColor: t.line,
      thumbColor: t.accent,
      overlayShape: SliderComponentShape.noOverlay,
      trackHeight: 3,
    ),
    extensions: [t],
  );
}
