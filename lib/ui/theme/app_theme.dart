import 'package:flutter/material.dart';

/// The monospace face used for anything technical: file names, scores,
/// settings, model names.
const String kMono = 'Menlo';

/// Colours with a fixed meaning across the app, on top of the Material
/// scheme. Each one says something specific, so none is used decoratively.
abstract final class AppColors {
  /// On, connected, indexed, optimized.
  static const Color ok = Color(0xFF4ADE80);

  /// The naive recipe: not an error, but not the version you want.
  static const Color caution = Color(0xFFFBBF24);

  /// An answer computed from a table rather than retrieved.
  static const Color computed = Color(0xFF38BDF8);

  /// Dark text or thumbs drawn on top of [ok].
  static const Color ink = Color(0xFF06120B);
}

abstract final class AppTheme {
  static const Color _seed = Color(0xFF4F46E5);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    final hairline = scheme.outlineVariant.withValues(alpha: 0.5);
    final radius = BorderRadius.circular(10);
    // Button text derives from the theme's label style, so it keeps the
    // platform font; a bare TextStyle would drop it.
    final label = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
    ).textTheme.labelLarge!;
    final buttonText = label.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      dividerTheme: DividerThemeData(color: hairline, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius),
          side: BorderSide(color: hairline),
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: label.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(fontSize: 11, color: scheme.onSurface),
      ),
    );
  }
}
