import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const SentiNLApp());
}

class SentiNLApp extends StatelessWidget {
  const SentiNLApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SentiNL',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFEB3B),
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}
