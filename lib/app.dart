import 'package:flutter/material.dart';

import 'features/home/home_screen.dart';
import 'theme/app_theme.dart';

class AmpmeApp extends StatelessWidget {
  const AmpmeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ampme',
      debugShowCheckedModeBanner: false,
      // Respect the system appearance: dark theme in dark mode, light theme in
      // light mode (both share the same brand palette).
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
