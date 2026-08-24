import '../domain/domain.dart';

/// 章节切分器：识别章节标题行，将整本小说文本切割为章节列表。
///
/// 纯逻辑、无状态、可注入正则，便于测试与扩展。
class ChapterSplitter {
  ChapterSplitter({RegExp? pattern}) : pattern = pattern ?? defaultPattern;

  /// 默认章节标题匹配：行首「第 X 章/节/回/卷/集/部/篇」，
  /// 编号支持阿拉伯数字与中文数字。
  static final RegExp defaultPattern = RegExp(
    r'^\s*第\s*[0-9零一二三四五六七八九十百千两]+\s*[章节回卷集部篇].*$',
    multiLine: true,
  );

  final RegExp pattern;

  /// 将全文切分为章节列表；无标题匹配时整本作为一章；空文本返回空列表。
  List<Chapter> split(String fullText) {
    final trimmed = fullText.trim();
    if (trimmed.isEmpty) return const [];

    final lines = trimmed.split('\n');
    if (!lines.any(pattern.hasMatch)) {
      // 全为符号/噪声（如纯分隔线文件）不算书。
      if (!_containsChinese(trimmed)) return const [];
      return [Chapter(id: 0, title: '全文', rawText: trimmed)];
    }
    final result = <Chapter>[];
    var currentTitle = '前言';
    var buffer = <String>[];
    var id = 0;
    var hasContent = false; // 当前缓冲是否已有正文
    var hasTitle = false; // 是否已遇到标题（决定空正文章节是否保留）

    void flush() {
      // 标题即章节边界：即使正文为空也保留章节（标题可见、可重生成）。
      if (hasContent || hasTitle) {
        final body = buffer.join('\n').trim();
        // 第一个标题前的纯符号噪声（如 `------------` 分隔线）不作为章节。
        if (hasContent && !hasTitle && !_containsChinese(body)) {
          // 丢弃
        } else {
          result.add(
            Chapter(
              id: id++,
              title: currentTitle,
              rawText: body,
            ),
          );
        }
      }
      buffer = <String>[];
      hasContent = false;
    }

    for (final line in lines) {
      if (pattern.hasMatch(line)) {
        flush();
        currentTitle = line.trim();
        hasTitle = true;
      } else {
        buffer.add(line);
        hasContent = true;
      }
    }
    flush();

    return result;
  }

  /// 是否包含中文字符（判断正文是否为真实内容而非纯符号噪声）。
  static bool _containsChinese(String text) {
    return text.contains(RegExp(r'[\u4e00-\u9fff]'));
  }
}