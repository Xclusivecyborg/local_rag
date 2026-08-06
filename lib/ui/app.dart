import 'package:flutter/material.dart';
import 'package:local_rag/ui/home_page.dart';

class LocalRagApp extends StatelessWidget {
  const LocalRagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local RAG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}
