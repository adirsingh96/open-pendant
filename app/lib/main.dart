import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'macos/sandbox_migrate.dart';
import 'ui/app_theme.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS || Platform.isMacOS) {
    await FlutterBluePlus.setOptions(restoreState: true);
  }
  await migrateMacosSandboxData();
  runApp(const OpenPendantApp());
}

class OpenPendantApp extends StatelessWidget {
  const OpenPendantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: openPendantTheme(),
      // Every size in this UI was hand-tuned on a Mac window at desktop
      // viewing distance. A phone is held much closer, so iOS's own type
      // scale runs noticeably larger than what looks right on a monitor —
      // without this, identical point sizes read as "too small" on a real
      // device. Bump the effective scale on phones, still honoring the
      // user's own Dynamic Type setting on top, within a safe range so nothing
      // overflows the tight icon+label rows.
      builder: (context, child) {
        final isPhone = Platform.isIOS || Platform.isAndroid;
        final base = isPhone ? 1.16 : 1.0;
        final userFactor = MediaQuery.textScalerOf(context).scale(100) / 100;
        final effective = (base * userFactor).clamp(0.9, 1.4);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(effective),
          ),
          child: child!,
        );
      },
      home: const HomePage(),
    );
  }
}
