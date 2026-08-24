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
              IconButton(
                tooltip: '导出音频',
                icon: const Icon(Icons.ios_share),
                onPressed: () => _exportAudio(context, appState),
              ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(appState: appState),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // 上方：当前章节正文（播放时逐句高亮跟随）。
              Expanded(flex: 3, child: _buildReader(context, appState)),
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
        const SnackBar(content: Text('还没有已生成的音频，请先「全部生成」')),
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
  Widget _buildReader(BuildContext context, AppState appState) {
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
                  final current = position.data ?? Duration.zero;
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
          // 每章都有播放入口：无音频时上层先生成该章再播放，
          // 生成失败时用 SnackBar 反馈；播放中点击可暂停。
          onPlay: () => _playOrGenerate(context, appState, index),
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
                    IconButton(
                      tooltip: appState.isPlaying ? '暂停' : '播放',
                      icon: Icon(
                        appState.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 40,
                      ),
                      onPressed: appState.togglePlay,
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
                              return Slider(
                                value: _sliderValue(current, total),
                                max: total == Duration.zero
                                    ? 1
                                    : total.inMilliseconds.toDouble(),
                                onChanged: total == Duration.zero
                                    ? null
                                    : (value) {
                                        appState.seek(
                                          Duration(milliseconds: value.toInt()),
                                        );
                                      },
                              );
                            },
                          );
                        },
                      ),
                    ),
                    StreamBuilder<Duration>(
                      stream: appState.playerPositionStream,
                      builder: (context, snapshot) {
                        final current = snapshot.data ?? Duration.zero;
                        return Text(
                          _formatDuration(current),
                          style: theme.textTheme.bodySmall,
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                )
              else
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '尚无音频，点击「全部生成」或直接点击章节播放',
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
          const SizedBox(width: 8),
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
        FilledButton.icon(
          onPressed: appState.canGenerate ? appState.generate : null,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('全部生成'),
        ),
        const SizedBox(width: 8),
        // 继续生成：从第一个未完成章节（未生成/失败/已取消）继续，
        // 已生成章节自动跳过、不覆盖已有内容。
        OutlinedButton.icon(
          onPressed: appState.canGenerate
              ? () => _continueGenerate(context, appState)
              : null,
          icon: const Icon(Icons.playlist_play),
          label: const Text('继续生成'),
        ),
        const SizedBox(width: 8),
        // 重新生成：从当前定位章节起按最新配置重做，旧文件转入历史目录。
        OutlinedButton.icon(
          onPressed: appState.canGenerate
              ? () => _confirmRegenerate(context, appState)
              : null,
          icon: const Icon(Icons.replay),
          label: const Text('重新生成'),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// 继续生成：从第一个未完成章节继续；全部已完成时给出提示。
  Future<void> _continueGenerate(
    BuildContext context,
    AppState appState,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await appState.continueGenerate();
    if (!ok && context.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('所有章节都已生成，无需继续')),
      );
    }
  }

  /// 重新生成确认：起点为当前播放/定位章节（无则第 1 章），
  /// 确认后从该章开始重新生成（旧文件转移到历史目录，可回溯）。
  Future<void> _confirmRegenerate(
    BuildContext context,
    AppState appState,
  ) async {
    final book = appState.book;
    if (book == null) return;
    final start = appState.playingIndex >= 0 ? appState.playingIndex : 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新生成'),
        content: Text(
          '将从「${book.chapterAt(start).title}」开始按最新配置重新生成'
          '第 ${start + 1} 章至第 ${book.chapterCount} 章，'
          '原有音频与改写稿将转移到历史目录（可在快照中回溯）。\n'
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
      await appState.regenerateFrom(start);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已从第 ${start + 1} 章开始重新生成，旧文件已转入历史目录',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('重新生成失败：$e')));
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
