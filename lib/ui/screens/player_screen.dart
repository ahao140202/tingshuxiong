import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';
import '../../core/text/text.dart';
import '../state/app_state.dart';
import '../widgets/chapter_tile.dart';
import '../widgets/reader_panel.dart';
import 'settings_screen.dart';

/// 播放页：章节列表（生成状态）、生成控制、音频播放控制。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// 拖动进度条时的本地预览位置（null 表示未拖动，跟随播放器实际位置）。
  ///
  /// 拖动中不调用播放器 seek：Windows 底层 Media Foundation 在高频
  /// seek 下会崩溃，本地预览保证界面即时反馈，松手时统一跳转一次。
  Duration? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final book = appState.book;
        if (book == null) {
          return const Scaffold(body: Center(child: Text('未导入书籍')));
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(book.title, overflow: TextOverflow.ellipsis),
            actions: [
              // ExcludeSemantics 规避 Flutter OverlayPortal 语义嫁接框架
              // bug（#187198）：tooltip 悬浮/点击时触发 AXTree 更新失败日志；
              // tooltip 提示与按钮点击不受影响。
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '导出音频',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => _exportAudio(context, appState),
                ),
              ),
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '聚合并导出',
                  icon: const Icon(Icons.merge_type),
                  onPressed: () => _mergeExportAudio(context, appState),
                ),
              ),
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(appState: appState),
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // 上方：当前章节正文（播放时逐句高亮跟随，拖动进度条时实时预览）。
              Expanded(
                flex: 3,
                child: _buildReader(context, appState, _dragPosition),
              ),
              const Divider(height: 1),
              // 下方：章节列表（生成状态 / 播放入口）。
              Expanded(flex: 2, child: _buildChapterList(context, book)),
              _buildControlBar(context, appState),
            ],
          ),
        );
      },
    );
  }

  /// 导出已生成章节音频：确认后选目录（桌面端）或文档目录（移动端），结果用 SnackBar 反馈。
  Future<void> _exportAudio(BuildContext context, AppState appState) async {
    final book = appState.book;
    if (book == null) return;
    final generated = book.chapters
        .where((c) => c.status == ChapterStatus.generated)
        .length;
    if (generated == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有已生成的音频，请先「离线缓存」')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出音频'),
        content: Text(
          '将导出 $generated 个已生成章节（mp3）到所选目录，'
          '未生成的章节自动跳过。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择目录并导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await appState.exportAudio();
      messenger.showSnackBar(
        SnackBar(
          content: Text('已导出 ${result.exported} 个章节 → ${result.targetDir}'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /// 正文阅读面板：展示当前播放章节文本，按播放进度估算并高亮当前句。
  ///
  /// [previewPosition] 非空时（拖动进度条中）用它代替播放器位置估算，
  /// 实现拖动时正文实时预览；松开后由 [AppState.seek] 同步真实位置。
  Widget _buildReader(
    BuildContext context,
    AppState appState,
    Duration? previewPosition,
  ) {
    final theme = Theme.of(context);
    final book = appState.book;
    if (book == null || appState.playingIndex < 0) {
      return Center(
        child: Text(
          '点击下方章节开始播放，正文将随音频同步展示并高亮',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }
    final chapter = book.chapterAt(appState.playingIndex);
    // 播放音频对应改写稿；未生成时展示原文。
    final text = chapter.rewrittenText ?? chapter.rawText;
    final sentences = splitSentences(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            chapter.title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<Duration>(
            stream: appState.playerPositionStream,
            builder: (context, position) {
              return StreamBuilder<Duration>(
                stream: appState.playerDurationStream,
                builder: (context, duration) {
                  // 拖动进度条时优先用本地预览值，松开后回落到播放器位置。
                  final current =
                      previewPosition ?? position.data ?? Duration.zero;
                  final total = duration.data ?? Duration.zero;
                  final index = estimateSentenceIndex(
                    position: current,
                    total: total,
                    sentences: sentences,
                  );
                  return ReaderPanel(sentences: sentences, currentIndex: index);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChapterList(BuildContext context, Book book) {
    final appState = widget.appState;
    return ListView.builder(
      itemCount: book.chapterCount,
      itemBuilder: (context, index) {
        final chapter = book.chapterAt(index);
        final isCurrent = index == appState.playingIndex;
        final isPlaying = isCurrent && appState.isPlaying;
        return ChapterTile(
          chapter: chapter,
          isCurrent: isCurrent,
          isPlaying: isPlaying,
          // 每章都有播放入口：无音频时上层先生成该章再播放，生成失败时
          // 用 SnackBar 反馈；播放中点击可暂停。
          // 凭据不齐时未生成章节不可点（避免点击后仅弹提示）；
          // 已生成章节本地有音频，不受凭据限制。
          onPlay:
              chapter.hasAudio || appState.canGenerate
                  ? () => _playOrGenerate(context, appState, index)
                  : null,
          onPause: isPlaying ? appState.togglePlay : null,
          onRetry: chapter.status.isRunnable
              ? () => appState.regenerateChapter(index)
              : null,
        );
      },
    );
  }

  /// 点击播放：无音频先生成再播；失败（无凭据/生成失败）时给出提示。
  Future<void> _playOrGenerate(
    BuildContext context,
    AppState appState,
    int index,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await appState.playOrGenerate(index);
    if (!ok && context.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            appState.canGenerate
                ? '第 ${index + 1} 章生成失败，请查看章节状态后重试'
                : '请先在设置中填写 API 凭据',
          ),
        ),
      );
    }
  }

  Widget _buildControlBar(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    final book = appState.book;
    final hasAudio = book != null &&
        appState.playingIndex >= 0 &&
        book.chapterAt(appState.playingIndex).hasAudio;

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildGenerateRow(context, appState),
              const Divider(height: 8),
              if (hasAudio)
                Row(
                  children: [
                    // ExcludeSemantics 同上：规避 tooltip 语义嫁接框架 bug。
                    ExcludeSemantics(
                      child: IconButton(
                        tooltip: appState.isPlaying ? '暂停' : '播放',
                        icon: Icon(
                          appState.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 40,
                        ),
                        onPressed: appState.togglePlay,
                      ),
                    ),
                    Expanded(
                      child: StreamBuilder<Duration>(
                        stream: appState.playerPositionStream,
                        builder: (context, position) {
                          final current = position.data ?? Duration.zero;
                          return StreamBuilder<Duration>(
                            stream: appState.playerDurationStream,
                            builder: (context, duration) {
                              final total = duration.data ?? Duration.zero;
                              final enabled = total != Duration.zero;
                              // 拖动中显示本地预览值，否则跟随播放器位置。
                              final display = _dragPosition ?? current;
                              return Slider(
                                value: _sliderValue(display, total),
                                max: enabled
                                    ? total.inMilliseconds.toDouble()
                                    : 1,
                                // 拖动中只更新本地预览，不调用播放器 seek：
                                // 高频 seek 会让 Windows Media Foundation 崩溃，
                                // 且 seek 后的位置事件会被节流吞掉导致不同步。
                                onChangeStart: enabled
                                    ? (_) =>
                                        setState(() => _dragPosition = current)
                                    : null,
                                onChanged: enabled
                                    ? (value) => setState(() {
                                          _dragPosition = Duration(
                                            milliseconds: value.toInt(),
                                          );
                                        })
                                    : null,
                                // 松手时一次性跳转：seek 内部会把目标位置
                                // 立即同步到 UI 流，正文高亮随之更新。
                                onChangeEnd: enabled
                                    ? (value) {
                                        setState(() => _dragPosition = null);
                                        appState.seek(
                                          Duration(milliseconds: value.toInt()),
                                        );
                                      }
                                    : null,
                              );
                            },
                          );
                        },
                      ),
                    ),
                    StreamBuilder<Duration>(
                      stream: appState.playerPositionStream,
                      builder: (context, snapshot) {
                        final current =
                            _dragPosition ?? snapshot.data ?? Duration.zero;
                        return Text(
                          _formatDuration(current),
                          style: theme.textTheme.bodySmall,
                        );
                      },
                    ),
                    // 与生成行右侧留白一致，保证控制栏右缘对齐。
                    const SizedBox(width: 16),
                  ],
                )
              else
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '尚无音频，点击「离线缓存」或直接点击章节播放',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGenerateRow(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    if (appState.isGenerating) {
      return Row(
        children: [
          const SizedBox(width: 16),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('正在生成中…', style: theme.textTheme.bodyMedium),
          ),
          TextButton.icon(
            onPressed: appState.stopGenerating,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('停止'),
          ),
          // 尾部留白与左侧对齐，保持行内对称。
          const SizedBox(width: 16),
        ],
      );
    }
    return Row(
      children: [
        const SizedBox(width: 16),
        Expanded(
          child: appState.canGenerate
              ? Text(
                  '生成进度：${_generatedCount(appState)}/${appState.book!.chapterCount}',
                  style: theme.textTheme.bodyMedium,
                )
              : Text(
                  '请先在设置中填写 API 凭据',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
        ),
        // 离线缓存：无记录时整本生成，有记录时从最后一个已生成章节之后
        // 继续（跳过已生成、不覆盖），不受预加载窗口限制。
        FilledButton.icon(
          onPressed: appState.canGenerate
              ? () => _generateOrContinue(context, appState)
              : null,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('离线缓存'),
        ),
        const SizedBox(width: 8),
        // 全部清空：删除本小说全部已生成内容（仅已有生成记录时可点，
        // 防止误触），清空后可从「离线缓存」从头再来。
        OutlinedButton.icon(
          onPressed: _generatedCount(appState) > 0
              ? () => _confirmClearAll(context, appState)
              : null,
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('全部清空'),
        ),
        // 尾部留白与左侧对齐，保持行内对称。
        const SizedBox(width: 16),
      ],
    );
  }

  /// 离线缓存入口：无记录整本生成，有记录从最后一个已生成章节之后继续；
  /// 全部章节均已生成时给出提示。
  Future<void> _generateOrContinue(
    BuildContext context,
    AppState appState,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await appState.generateOrContinue();
    if (!ok && context.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('所有章节都已生成，无需继续')),
      );
    }
  }

  /// 全部清空确认：删除本小说全部已生成音频与改写稿（不触发生成），
  /// 章节状态重置为未生成，之后可从「离线缓存」从头再来。
  Future<void> _confirmClearAll(
    BuildContext context,
    AppState appState,
  ) async {
    final book = appState.book;
    if (book == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('全部清空'),
        content: Text(
          '将删除本小说全部 ${book.chapterCount} 章的已生成音频与改写稿，'
          '章节状态重置为未生成。\n'
          '确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await appState.clearAll();
      messenger.showSnackBar(
        const SnackBar(content: Text('已清空全部已生成内容')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('清空失败：$e')));
    }
  }

  /// 聚合并导出：按设置的大小上限（默认 100MB）把已生成章节按顺序合并
  /// 为数量更少的大文件，超出上限自动分卷，导出到所选目录。
  Future<void> _mergeExportAudio(
    BuildContext context,
    AppState appState,
  ) async {
    final book = appState.book;
    if (book == null) return;
    final generated = _generatedCount(appState);
    if (generated == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有已生成的音频，请先「离线缓存」')),
      );
      return;
    }
    final maxSizeMb = appState.settings.mergeFileSizeMb;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('聚合并导出'),
        content: Text(
          '将把 $generated 个已生成章节按顺序合并为不超过 $maxSizeMb MB 的 '
          'mp3 大文件（超出上限自动分卷），导出到所选目录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择目录并导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await appState.mergeExportAudio();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已聚合 ${result.mergedCount} 个章节 → ${result.filePaths.length} '
            '个文件，导出到 ${result.targetDir}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('聚合导出失败：$e')));
    }
  }

  int _generatedCount(AppState appState) {
    final book = appState.book;
    if (book == null) return 0;
    return book.chapters
        .where((c) => c.status == ChapterStatus.generated)
        .length;
  }

  double _sliderValue(Duration position, Duration duration) {
    if (duration == Duration.zero) return 0;
    final millis = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    return millis;
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
