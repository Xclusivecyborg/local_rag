import 'package:flutter/material.dart';

import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/ui/app.dart';

void main() {
  // The RAG every tutorial builds: chunk, embed, top five, paste, answer.
  var recipe = RagRecipe.naive;

  // Uncomment to start with every optimization on, then hot restart.
  // The "Optimize" switch on the sidebar's recipe card flips it live too.
  // recipe = RagRecipe.optimized;

  runApp(LocalRagApp(recipe: recipe));
}
