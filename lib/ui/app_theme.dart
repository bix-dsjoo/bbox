import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

class BboxAppTheme {
  const BboxAppTheme._();

  static const fontFamily = 'Pretendard';

  static final FThemeData foruiTheme = _buildForuiTheme();

  static ThemeData get materialTheme {
    final base = foruiTheme.toApproximateMaterialTheme();
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: WorkbenchPalette.accent,
        onPrimary: Colors.white,
        primaryContainer: WorkbenchPalette.accentSoft,
        onPrimaryContainer: WorkbenchPalette.accentStrong,
        secondary: WorkbenchPalette.accentStrong,
        onSecondary: Colors.white,
        secondaryContainer: WorkbenchPalette.accentSoft,
        onSecondaryContainer: WorkbenchPalette.accentStrong,
      ),
      scaffoldBackgroundColor: WorkbenchPalette.appBackground,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: WorkbenchPalette.panel,
        foregroundColor: WorkbenchPalette.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: WorkbenchPalette.border,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.field),
            ),
          ),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: WorkbenchPalette.panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.field),
          borderSide: const BorderSide(color: WorkbenchPalette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.field),
          borderSide: const BorderSide(color: WorkbenchPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.field),
          borderSide: const BorderSide(
            color: WorkbenchPalette.accent,
            width: 1.4,
          ),
        ),
      ),
    );
  }

  static FThemeData _buildForuiTheme() {
    final base = FThemes.zinc.light.desktop;
    final typeface = FTypeface.inherit(
      colors: base.colors,
      touch: false,
      fontFamily: fontFamily,
      fontFamilyFallback: const ['Malgun Gothic', 'Segoe UI'],
    );
    return FThemeData(
      colors: base.colors,
      touch: false,
      typography: base.typography.copyWith(display: typeface, body: typeface),
      style: base.style.copyWith(
        tappableStyle: const FTappableStyleDelta.delta(
          pressedEnterDuration: Duration.zero,
          pressedExitDuration: Duration.zero,
          motion: FTappableMotion.none,
        ),
      ),
    );
  }
}

class AppRadii {
  const AppRadii._();

  static const button = 4.0;
  static const field = 4.0;
  static const badge = 4.0;
  static const row = 6.0;
  static const panel = 6.0;
  static const large = 8.0;
}

class WorkbenchPalette {
  const WorkbenchPalette._();

  static const appBackground = Color(0xfff6f7f9);
  static const panel = Color(0xffffffff);
  static const panelMuted = Color(0xfff9fafb);
  static const border = Color(0xffd7dde4);
  static const borderStrong = Color(0xffb9c3cf);
  static const foreground = Color(0xff181c20);
  static const mutedForeground = Color(0xff66717f);
  static const accent = Color(0xffd97706);
  static const accentSoft = Color(0xfffff3e0);
  static const accentStrong = Color(0xffb45309);
  static const accentBorder = Color(0xfff59e0b);
  static const warning = Color(0xffb45309);
  static const warningSoft = Color(0xfffff3d6);
  static const danger = Color(0xffb42318);
  static const dangerSoft = Color(0xffffe4e0);
}
