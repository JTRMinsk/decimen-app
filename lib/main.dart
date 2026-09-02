import 'package:flutter/material.dart';

import 'src/app/home_screen.dart';

void main() {
  runApp(const DecimenApp());
}

class DecimenApp extends StatelessWidget {
  const DecimenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decimen 光传',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2962FF)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
