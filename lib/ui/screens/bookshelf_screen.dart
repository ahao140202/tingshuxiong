import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';
import '../state/app_state.dart';
import '../widgets/bear_logo.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

/// 书架页：导入小说、查看当前书、进入播放页。
class BookshelfScreen extends StatelessWidget {
  const BookshelfScreen({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final book = appState.book;
    return Scaffold(
      appBar: AppBar(
        title: const Text('听书熊'),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: book == null ? _buildEmpty(context) : _buildBookCard(context, book),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await appState.importBook();
          if (context.mounted && appState.book != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerScreen(appState: appState),
              ),
            );
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('导入小说'),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BearLogo(size: 120),
          const SizedBox(height: 16),
          Text('书架空空如也', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点击右下角「导入小说」选择 txt 文件',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookCard(BuildContext context, Book book) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(
              Icons.menu_book,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            subtitle: Text(
              '共 ${book.chapterCount} 章 · 上次读到第 ${book.lastChapterIndex + 1} 章',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerScreen(appState: appState),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(appState: appState),
      ),
    );
  }
}
