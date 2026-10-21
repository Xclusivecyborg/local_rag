import 'package:flutter/material.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/ui/home_page.dart';
import 'package:local_rag/ui/theme/app_theme.dart';

class LocalRagApp extends StatelessWidget {
  const LocalRagApp({super.key, this.recipe = RagRecipe.optimized});
  final RagRecipe recipe;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local RAG',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: HomePage(recipe: recipe),
    );
  }
}
