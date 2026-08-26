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
    return Scaffold(
      appBar: AppBar(
        title: const Text('听书熊'),
        actions: [
          // ExcludeSemantics 规避 Flutter OverlayPortal 语义嫁接框架 bug
          //（#187198）：tooltip 悬浮/点击时语义子树动态挂载，触发引擎
          // AXTree 更新失败日志；tooltip 提示与按钮点击不受影响。
          ExcludeSemantics(
            child: IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _openSettings(context),
            ),
          ),
        ],
      ),
      // 书架展示全部导入的书籍（最新导入的排最前）。
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final books = appState.books;
          if (books.isEmpty) return _buildEmpty(context);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final book in books) _buildBookCard(context, book),
            ],
          );
        },
      ),
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
    return Card(
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ExcludeSemantics 规避 Flutter OverlayPortal 语义嫁接框架
            // bug（#187198）：tooltip 悬浮时语义子树动态挂载。
            ExcludeSemantics(
              child: IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(context, book),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () {
          // 切换当前书为该卡片对应的书，再进入播放页。
          appState.openBook(book);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerScreen(appState: appState),
            ),
          );
        },
      ),
    );
  }

  /// 删除小说确认对话框：删除不可恢复（记录 + 已生成文件），需确认。
  Future<void> _confirmDelete(BuildContext context, Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除小说'),
        content: Text(
          '将删除《${book.title}》及其全部已生成音频与改写稿，'
          '此操作不可恢复。\n'
          '确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await appState.deleteBook(book.id);
      messenger.showSnackBar(SnackBar(content: Text('已删除《${book.title}》')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(appState: appState),
      ),
    );
  }
}
