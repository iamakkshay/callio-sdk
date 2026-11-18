import 'package:flutter/material.dart';

/// The Callio Jade palette.
abstract final class CallioColors {
  static const jade = Color(0xFF1F7A5C);
  static const jadeDark = Color(0xFF14533E);
  static const mint = Color(0xFF4FBF93);
  static const jadeLight = Color(0xFFE3F1EA);
  static const ink = Color(0xFF1C1B19);

  static const paper = Color(0xFFFAFAF7);
  static const night = Color(0xFF121412);
  static const nightSurface = Color(0xFF1B1E1C);
  static const danger = Color(0xFFC8443A);
  static const amber = Color(0xFFD39B2A);
}

/// Ready-made Material 3 themes in the Callio Jade style, light and dark.
///
/// Fonts are optional. Pass a bundled family (`fontFamily: 'PlusJakartaSans'`, `displayFontFamily: 'Sora'`), or
/// if your app uses the google_fonts package, pass its families, e.g.
/// `fontFamily: GoogleFonts.plusJakartaSans().fontFamily`. With nothing passed the platform font is used and
/// nothing is fetched at runtime.
abstract final class CallioTheme {
  static ThemeData light({String? fontFamily, String? displayFontFamily}) => _build(
        const ColorScheme(
          brightness: Brightness.light,
          primary: CallioColors.jade,
          onPrimary: Colors.white,
          primaryContainer: CallioColors.jadeLight,
          onPrimaryContainer: CallioColors.jadeDark,
          secondary: CallioColors.mint,
          onSecondary: CallioColors.ink,
          secondaryContainer: CallioColors.jadeLight,
          onSecondaryContainer: CallioColors.jadeDark,
          error: CallioColors.danger,
          onError: Colors.white,
          surface: CallioColors.paper,
          onSurface: CallioColors.ink,
          onSurfaceVariant: Color(0xFF5B5E59),
          outline: Color(0xFFD5D9D3),
          outlineVariant: Color(0xFFE7EAE5),
          surfaceContainerHighest: Color(0xFFEFF2EE),
          surfaceContainerHigh: Color(0xFFF3F5F2),
          surfaceContainer: Color(0xFFF6F7F4),
          surfaceContainerLow: Colors.white,
        ),
        fontFamily,
        displayFontFamily,
      );

  static ThemeData dark({String? fontFamily, String? displayFontFamily}) => _build(
        const ColorScheme(
          brightness: Brightness.dark,
          primary: CallioColors.mint,
          onPrimary: CallioColors.ink,
          primaryContainer: CallioColors.jadeDark,
          onPrimaryContainer: CallioColors.jadeLight,
          secondary: CallioColors.mint,
          onSecondary: CallioColors.ink,
          secondaryContainer: CallioColors.jadeDark,
          onSecondaryContainer: CallioColors.jadeLight,
          error: Color(0xFFE5776E),
          onError: CallioColors.ink,
          surface: CallioColors.night,
          onSurface: Color(0xFFEDEEE9),
          onSurfaceVariant: Color(0xFFA9AEA7),
          outline: Color(0xFF3A3F3B),
          outlineVariant: Color(0xFF2A2E2B),
          surfaceContainerHighest: Color(0xFF2A2E2B),
          surfaceContainerHigh: Color(0xFF232724),
          surfaceContainer: CallioColors.nightSurface,
          surfaceContainerLow: Color(0xFF171A18),
        ),
        fontFamily,
        displayFontFamily,
      );

  static ThemeData _build(ColorScheme scheme, String? fontFamily, String? displayFontFamily) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: fontFamily);
    final text = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(fontFamily: displayFontFamily, fontWeight: FontWeight.w600),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontFamily: displayFontFamily, fontWeight: FontWeight.w600),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontFamily: displayFontFamily, fontWeight: FontWeight.w600),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontFamily: displayFontFamily, fontWeight: FontWeight.w600),
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface, fontSize: 18),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape, minimumSize: const Size(48, 48))),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape, minimumSize: const Size(48, 48), side: BorderSide(color: scheme.outline)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outline)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.outline)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: scheme.outlineVariant)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      extensions: [CallioCallStyle.fromScheme(scheme, displayFontFamily: displayFontFamily)],
    );
  }
}

/// Colours of the full-screen call surfaces (incoming call, in call). Read with [CallioCallStyle.of]; it falls
/// back to Jade defaults when the app's theme does not carry it, so the widgets work under any theme.
@immutable
class CallioCallStyle extends ThemeExtension<CallioCallStyle> {
  final Color backgroundTop, backgroundBottom, foreground, mutedForeground;
  final Color controlFill, controlActiveFill, controlActiveForeground;
  final Color answerFill, endFill;
  final String? displayFontFamily;

  const CallioCallStyle({
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.foreground,
    required this.mutedForeground,
    required this.controlFill,
    required this.controlActiveFill,
    required this.controlActiveForeground,
    required this.answerFill,
    required this.endFill,
    this.displayFontFamily,
  });

  factory CallioCallStyle.fromScheme(ColorScheme scheme, {String? displayFontFamily}) {
    final dark = scheme.brightness == Brightness.dark;
    return CallioCallStyle(
      backgroundTop: dark ? CallioColors.jadeDark : CallioColors.jade,
      backgroundBottom: dark ? CallioColors.night : CallioColors.jadeDark,
      foreground: Colors.white,
      mutedForeground: Colors.white.withValues(alpha: 0.72),
      controlFill: Colors.white.withValues(alpha: 0.12),
      controlActiveFill: Colors.white,
      controlActiveForeground: CallioColors.jadeDark,
      answerFill: CallioColors.mint,
      endFill: CallioColors.danger,
      displayFontFamily: displayFontFamily,
    );
  }

  static CallioCallStyle of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<CallioCallStyle>() ?? CallioCallStyle.fromScheme(theme.colorScheme);
  }

  @override
  CallioCallStyle copyWith({
    Color? backgroundTop,
    Color? backgroundBottom,
    Color? foreground,
    Color? mutedForeground,
    Color? controlFill,
    Color? controlActiveFill,
    Color? controlActiveForeground,
    Color? answerFill,
    Color? endFill,
    String? displayFontFamily,
  }) =>
      CallioCallStyle(
        backgroundTop: backgroundTop ?? this.backgroundTop,
        backgroundBottom: backgroundBottom ?? this.backgroundBottom,
        foreground: foreground ?? this.foreground,
        mutedForeground: mutedForeground ?? this.mutedForeground,
        controlFill: controlFill ?? this.controlFill,
        controlActiveFill: controlActiveFill ?? this.controlActiveFill,
        controlActiveForeground: controlActiveForeground ?? this.controlActiveForeground,
        answerFill: answerFill ?? this.answerFill,
        endFill: endFill ?? this.endFill,
        displayFontFamily: displayFontFamily ?? this.displayFontFamily,
      );

  @override
  CallioCallStyle lerp(covariant CallioCallStyle? other, double t) {
    if (other == null) return this;
    return CallioCallStyle(
      backgroundTop: Color.lerp(backgroundTop, other.backgroundTop, t)!,
      backgroundBottom: Color.lerp(backgroundBottom, other.backgroundBottom, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      controlFill: Color.lerp(controlFill, other.controlFill, t)!,
      controlActiveFill: Color.lerp(controlActiveFill, other.controlActiveFill, t)!,
      controlActiveForeground: Color.lerp(controlActiveForeground, other.controlActiveForeground, t)!,
      answerFill: Color.lerp(answerFill, other.answerFill, t)!,
      endFill: Color.lerp(endFill, other.endFill, t)!,
      displayFontFamily: t < 0.5 ? displayFontFamily : other.displayFontFamily,
    );
  }
}
