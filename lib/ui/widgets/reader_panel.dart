import 'package:flutter/material.dart';

/// 根据播放进度估算当前朗读到的句子序号（-1 表示无法估算）。
///
/// 句子按字符数加权分配时长（长句朗读更久），返回累计权重首次
/// 覆盖进度比例的句子下标；无句子或总时长为 0 时返回 -1。
int estimateSentenceIndex({
  required Duration position,
  required Duration total,
  required List<String> sentences,
}) {
  if (sentences.isEmpty || total <= Duration.zero) return -1;
  final progress =
      position.inMilliseconds / total.inMilliseconds;
  final weights = [for (final s in sentences) s.runes.length];
  final sum = weights.fold<int>(0, (a, b) => a + b);
  if (sum == 0) return 0;
  var acc = 0;
  for (var i = 0; i < sentences.length; i++) {
    acc += weights[i];
    if (progress * sum <= acc) return i;
  }
  return sentences.length - 1;
}

/// 正文阅读面板：逐句展示章节文本，当前播放句高亮并自动滚动跟随。
///
/// [currentIndex] 为 -1 时不高亮（未播放/无时长信息）。
class ReaderPanel extends StatefulWidget {
  const ReaderPanel({
    super.key,
    required this.sentences,
    this.currentIndex = -1,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final List<String> sentences;

  /// 当前高亮句序号（-1 不高亮）。
  final int currentIndex;

  final EdgeInsets padding;

  @override
  State<ReaderPanel> createState() => _ReaderPanelState();
}

class _ReaderPanelState extends State<ReaderPanel> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _currentKey = GlobalKey();

  @override
  void didUpdateWidget(ReaderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != oldWidget.currentIndex &&
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.sentences.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _currentKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
            alignment: 0.35,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sentences = widget.sentences;
    final highlight = theme.colorScheme.primaryContainer;
    return ListView.builder(
      controller: _controller,
      padding: widget.padding,
      itemCount: sentences.length,
      itemBuilder: (context, index) {
        final isCurrent = index == widget.currentIndex;
        return Container(
          key: isCurrent ? _currentKey : null,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: isCurrent
              ? BoxDecoration(
                  color: highlight.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Text(
            sentences[index],
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.7,
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        );
      },
    );
  }
}
