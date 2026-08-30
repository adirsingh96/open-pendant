import 'package:flutter/material.dart';

class AppColors {
  static const paper = Color(0xFFF4F6FA);
  static const canvas = Color(0xFFC9D8EE);
  static const ink = Color(0xFF1C1C1E);
  static const muted = Color(0xFF6B7280);
  static const line = Color(0xFFD1D5DB);
  static const rule = Color(0xFF007AFF);
  static const live = Color(0xFFFF3B30);
  static const liveSoft = Color(0x33FF3B30);
  static const bolt = Color(0xFFFFCC00);
  static const teal = Color(0xFF007AFF);
  static const tealDark = Color(0xFF0A84FF);
  static const mint = Color(0xFFE8EEF8);
  static const mintBadge = Color(0xFFDCE6F5);
}

ThemeData openPendantTheme() {
  const ink = AppColors.ink;
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.rule,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.rule,
      onPrimary: Colors.white,
      surface: AppColors.paper,
      onSurface: ink,
      surfaceContainerHighest: AppColors.mint,
    ),
    scaffoldBackgroundColor: AppColors.paper,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: ink,
      displayColor: ink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.muted,
      textColor: AppColors.ink,
      subtitleTextStyle: TextStyle(color: AppColors.muted, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xE6FFFFFF),
      labelStyle: const TextStyle(color: AppColors.muted),
      hintStyle: const TextStyle(color: AppColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: const Color(0x33007AFF),
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final on = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
          color: on ? AppColors.rule : AppColors.muted,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final on = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: on ? AppColors.rule : AppColors.muted,
        );
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.rule,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
      ),
    ),
  );
}
