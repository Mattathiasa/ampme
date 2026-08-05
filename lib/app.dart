import 'package:flutter/material.dart';

import 'features/home/home_screen.dart';

class AmpmeApp extends StatelessWidget {
  const AmpmeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ampme',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
