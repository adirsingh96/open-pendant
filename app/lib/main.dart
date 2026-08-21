import 'package:flutter/material.dart';

import 'macos/sandbox_migrate.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await migrateMacosSandboxData();
  runApp(const OpenPendantApp());
}

class OpenPendantApp extends StatelessWidget {
  const OpenPendantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
