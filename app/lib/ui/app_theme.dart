import 'package:flutter/material.dart';

/// OpenPendant design tokens — dark editorial. Near-black warm canvas,
/// quiet type, hairline dividers, one orange accent used sparingly.
class AppColors {
  // Canvas + surfaces
  static const paper = Color(0xFF0F0E0C);
  static const card = Color(0xFF1A1815);
  static const inset = Color(0xFF201D19);

  // Text
  static const ink = Color(0xFFF4F1EC);
  static const muted = Color(0xFF8F8A82);
  static const faint = Color(0xFF57534C);

  // Hairlines
  static const line = Color(0xFF262320);
  static const lineStrong = Color(0xFF33302B);

  // The accent. Live, recording, primary — nothing else.
  static const accent = Color(0xFFFF4D00);
  static const accentDeep = Color(0xFFFF6224);
  static const accentSoft = Color(0xFF2E1A10);
  static const accentFaint = Color(0xFF241610);

  // Immersive recording aliases (same system now).
  static const darkBg = paper;
  static const darkGlow = Color(0xFF221711);
  static const onDark = ink;
  static const onDarkMuted = muted;
  static const onDarkLine = lineStrong;

  // Legacy aliases (older pages reference these names).
  static const canvas = paper;
  static const rule = accent;
  static const live = accent;
  static const liveSoft = accentSoft;
  static const bolt = accent;
  static const teal = accent;
  static const tealDark = accentDeep;
  static const mint = inset;
  static const mintBadge = accentSoft;
}

class AppFonts {
  /// One voice: Instrument Sans everywhere.
  static const sans = 'Instrument Sans';
}

/// Editorial type scale — size does the talking, weight stays calm.
class AppText {
  static const micro = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
    color: AppColors.muted,
    height: 1.0,
  );

  static const microAccent = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    color: AppColors.accent,
    height: 1.0,
  );

  /// The big editorial headline.
  static const display = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.8,
    color: AppColors.ink,
    height: 1.12,
  );

  static const headline = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 21,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    color: AppColors.ink,
    height: 1.2,
  );

  static const timer = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 54,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
    color: AppColors.ink,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const title = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: AppColors.ink,
  );

  static const body = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
    height: 1.5,
  );

  /// Small quiet caption — the editorial voice.
  static const sub = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    color: AppColors.muted,
    height: 1.55,
  );

  static const label = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: AppColors.ink,
  );

  /// Small time/data captions.
  static const monoSmall = TextStyle(
    fontFamily: AppFonts.sans,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    color: AppColors.muted,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData openPendantTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: AppFonts.sans,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      surface: AppColors.paper,
      onSurface: AppColors.ink,
      surfaceContainerHighest: AppColors.inset,
      outline: AppColors.lineStrong,
      outlineVariant: AppColors.line,
    ),
    scaffoldBackgroundColor: AppColors.paper,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          bodyColor: AppColors.ink,
          displayColor: AppColors.ink,
          fontFamily: AppFonts.sans,
        )
        .copyWith(
          titleLarge: AppText.title.copyWith(fontSize: 19),
          titleMedium: AppText.title,
          bodyMedium: AppText.body,
          bodySmall: AppText.sub,
        ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: AppColors.ink,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.muted,
      textColor: AppColors.ink,
      titleTextStyle: TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
        color: AppColors.ink,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: AppFonts.sans,
        color: AppColors.muted,
        fontSize: 12.5,
        height: 1.45,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.card,
      labelStyle: const TextStyle(color: AppColors.muted),
      hintStyle: const TextStyle(color: AppColors.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.muted, width: 1.2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF262320),
      contentTextStyle: const TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.ink,
        height: 1.4,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.lineStrong),
      ),
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.paper,
        textStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.lineStrong),
        textStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentDeep,
        textStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: AppColors.ink,
      side: const BorderSide(color: AppColors.lineStrong),
      labelStyle: const TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: AppColors.muted,
      ),
      secondaryLabelStyle: const TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: AppColors.paper,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.ink
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.paper
              : AppColors.muted,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: AppColors.lineStrong),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.lineStrong,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.accent
            : Colors.transparent,
      ),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: const BorderSide(color: AppColors.lineStrong, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      textStyle: const TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: AppColors.ink,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF16140F),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
    datePickerTheme: const DatePickerThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
    ),
    timePickerTheme: const TimePickerThemeData(
      backgroundColor: AppColors.card,
    ),
  );
}
