import 'dart:convert';

/// 句末标点/换行：句子切分边界。
final RegExp _sentenceEnd = RegExp(r'[。！？!?；;\n]');

/// 按句末标点/换行切分为句子（保留分隔符）。
///
/// 供正文展示（阅读面板逐句高亮）与 TTS 分块共用。
List<String> splitSentences(String text) {
  final sentences = <String>[];
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(char);
    if (_sentenceEnd.hasMatch(char)) {
      sentences.add(buffer.toString());
      buffer.clear();
    }
  }
  if (buffer.isNotEmpty) sentences.add(buffer.toString());
  return sentences;
}

/// 文本切分器：将超长文本按句子切分并贪心合并，保证每段不超过 [maxBytes] 字节。
///
/// 用途：科大讯飞在线语音合成单次调用文本需小于 8000 字节（base64 编码前）。
/// 纯逻辑、无状态、可单测。
class TextChunker {
  const TextChunker({this.maxBytes = 8000});

  /// 单段上限（UTF-8 字节数）。
  final int maxBytes;


  /// 将文本切分为不超过 [maxBytes] 字节的片段，顺序拼接等于原文。
  List<String> chunk(String text) {
    if (text.isEmpty) return const [];
    final result = <String>[];
    final buffer = StringBuffer();
    var bufferBytes = 0;

    void flush() {
      if (buffer.isNotEmpty) {
        result.add(buffer.toString());
        buffer.clear();
        bufferBytes = 0;
      }
    }

    for (final sentence in splitSentences(text)) {
      final bytes = utf8.encode(sentence).length;
      if (bytes > maxBytes) {
        flush();
        result.addAll(_hardSplit(sentence));
      } else if (bufferBytes + bytes <= maxBytes) {
        buffer.write(sentence);
        bufferBytes += bytes;
      } else {
        flush();
        buffer.write(sentence);
        bufferBytes = bytes;
      }
    }
    flush();
    return result;
  }

  /// 单句超限时按字符硬切，保证不切断 UTF-8 字符。
  List<String> _hardSplit(String sentence) {
    final result = <String>[];
    final buffer = StringBuffer();
    var bufferBytes = 0;
    for (final rune in sentence.runes) {
      final char = String.fromCharCode(rune);
      final charBytes = utf8.encode(char).length;
      if (bufferBytes + charBytes > maxBytes) {
        result.add(buffer.toString());
        buffer.clear();
        bufferBytes = 0;
      }
      buffer.write(char);
      bufferBytes += charBytes;
    }
    if (buffer.isNotEmpty) result.add(buffer.toString());
    return result;
  }
}