import 'package:flutter/material.dart';

import 'screens/bookshelf_screen.dart';
import 'state/app_state.dart';

/// 应用根组件：Material 3 主题 + 全局状态驱动。
class TingApp extends StatelessWidget {
  const TingApp({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '听书熊',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
        ),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          if (!appState.initialized) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return BookshelfScreen(appState: appState);
        },
      ),
    );
  }
}
