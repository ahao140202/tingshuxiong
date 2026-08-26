import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';

/// 章节列表项：展示标题、生成状态与操作按钮。
class ChapterTile extends StatelessWidget {
  const ChapterTile({
    super.key,
    required this.chapter,
    required this.isCurrent,
    required this.isPlaying,
    this.onPlay,
    this.onPause,
    this.onRetry,
  });

  final Chapter chapter;

  /// 是否当前播放/定位章节。
  final bool isCurrent;

  final bool isPlaying;

  /// 播放回调（所有非生成中状态可用：无音频时由上层先生成再播）。
  final VoidCallback? onPlay;

  /// 暂停回调（正在播放的章节显示，点击暂停当前音频）。
  final VoidCallback? onPause;

  /// 重试生成回调（失败章节显示，与播放按钮并存）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = chapter.status;

    final Widget trailing;
    if (status == ChapterStatus.rewriting ||
        status == ChapterStatus.synthesizing) {
      trailing = const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (status == ChapterStatus.failed) {
      // 失败章节仅保留「重试生成」入口：章节级重新生成只生成本章节，
      // 重试成功后状态转为已生成、自动切换为播放按钮，两者互斥不并存。
      // ExcludeSemantics 规避 Flutter tooltip 语义嫁接框架 bug（#187198）：
      // 悬浮/点击触发 AXTree 更新失败日志；提示与点击不受影响。
      trailing = ExcludeSemantics(
        child: IconButton(
          tooltip: '重试生成',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
        ),
      );
    } else {
      trailing = ExcludeSemantics(
        child: IconButton(
          tooltip: isPlaying
              ? '暂停'
              : (status == ChapterStatus.generated ? '播放' : '生成并播放'),
          onPressed: isPlaying ? onPause : onPlay,
          icon: Icon(
            isPlaying ? Icons.pause_circle_outline : Icons.play_circle_outline,
            color: isCurrent ? theme.colorScheme.primary : null,
          ),
        ),
      );
    }

    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          '${chapter.id + 1}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent ? TextStyle(fontWeight: FontWeight.bold) : null,
      ),
      subtitle: Text(
        _statusDescription(status),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: _statusColor(theme, status),
        ),
      ),
      trailing: trailing,
      onTap: isPlaying ? onPause : onPlay,
    );
  }

  String _statusDescription(ChapterStatus status) {
    switch (status) {
      case ChapterStatus.notGenerated:
        return '未生成';
      case ChapterStatus.rewriting:
        return 'AI 修订润色中…';
      case ChapterStatus.synthesizing:
        return '音频合成中…';
      case ChapterStatus.generated:
        return '已生成，可播放';
      case ChapterStatus.failed:
        // 优先展示具体失败原因，便于用户排查（如 API 错误、余额不足等）。
        final reason = chapter.errorMessage;
        return reason == null || reason.isEmpty
            ? '生成失败，点击重试'
            : '生成失败：$reason';
      case ChapterStatus.cancelled:
        return '已取消，可重新生成';
    }
  }

  Color _statusColor(ThemeData theme, ChapterStatus status) {
    switch (status) {
      case ChapterStatus.generated:
        return Colors.green.shade600;
      case ChapterStatus.failed:
        return theme.colorScheme.error;
      case ChapterStatus.rewriting:
      case ChapterStatus.synthesizing:
        return theme.colorScheme.primary;
      default:
        return theme.colorScheme.outline;
    }
  }
}
