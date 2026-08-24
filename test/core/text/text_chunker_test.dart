import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/text/text_chunker.dart';

void main() {
  const chunker = TextChunker();

  group('TextChunker', () {
    test('空文本返回空列表', () {
      expect(chunker.chunk(''), isEmpty);
    });

    test('短文本保持单段', () {
      final text = '这是一段短文本。';
      expect(chunker.chunk(text), [text]);
    });

    test('超长文本按句切分且每段不超过 8000 字节', () {
      final sentence = '这是一句话。';
      final text = sentence * 800; // 4000 字，约 12000 字节
      final chunks = chunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(8000));
      }
      expect(chunks.join(), text);
    });

    test('无标点单句超长时硬切且不破坏 UTF-8 字符', () {
      final text = '啊' * 5000; // 15000 字节，无标点单句
      final chunks = chunker.chunk(text);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(8000));
      }
      expect(chunks.join(), text);
    });

    test('恰好等于上限时保持单段', () {
      final text = 'a' * 8000; // 8000 字节
      expect(chunker.chunk(text), [text]);
    });

    test('超过上限一字节时切为两段', () {
      final text = 'a' * 8001;
      final chunks = chunker.chunk(text);
      expect(chunks.length, 2);
      expect(utf8.encode(chunks[0]).length, 8000);
      expect(chunks[1], 'a');
    });

    test('中英混合文本不丢字符', () {
      final sentence = '中文句子。English sentence!';
      final text = sentence * 400; // 混合，超 8000 字节
      final chunks = chunker.chunk(text);
      expect(chunks.join(), text);
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(8000));
      }
    });

    test('自定义 maxBytes 生效', () {
      const small = TextChunker(maxBytes: 100);
      final text = 'a' * 250;
      final chunks = small.chunk(text);
      expect(chunks.length, 3);
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(100));
      }
      expect(chunks.join(), text);
    });

    test('emoji 多字节字符不被切断', () {
      // emoji 为 4 字节 UTF-8 序列，硬切边界不能截断
      const emojiChunker = TextChunker(maxBytes: 6);
      final text = '😀😀😀😀';
      final chunks = emojiChunker.chunk(text);
      expect(chunks.join(), text);
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(6));
        // 每个 chunk 都由完整 emoji 组成
        expect(c.runes.every((r) => r == 0x1F600), isTrue);
      }
    });

    test('换行作为切分点，短文本仍贪心合并为单段', () {
      final text = '第一句。\n第二句。\n第三句。';
      final chunks = chunker.chunk(text);
      expect(chunks, [text]);
    });

    test('换行切分点在超限时生效', () {
      // 句 A≈28B、句 B≈31B、句 C≈13B，上限 60：A+B 合并，C 单独成段
      const small = TextChunker(maxBytes: 60);
      final text = '第一句内容比较多。\n第二句内容也比较多。\n第三句。\n';
      final chunks = small.chunk(text);
      expect(chunks.join(), text);
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(60));
      }
      expect(chunks.length, 2);
    });
  });

  group('splitSentences', () {
    test('按句末标点与换行切分并保留分隔符', () {
      const text = '第一句。第二句！第三句？\n第四句；第五句。';
      // 换行作为分隔符保留为独立句子（保证顺序拼接等于原文）。
      expect(
        splitSentences(text),
        ['第一句。', '第二句！', '第三句？', '\n', '第四句；', '第五句。'],
      );
    });

    test('无句末标点时不切分', () {
      const text = '这是一段没有标点的文本';
      expect(splitSentences(text), [text]);
    });

    test('空文本返回空列表', () {
      expect(splitSentences(''), isEmpty);
    });

    test('顺序拼接等于原文', () {
      const text = '山重水复疑无路，柳暗花明又一村。春色满园关不住，一枝红杏出墙来。';
      expect(splitSentences(text).join(), text);
    });
  });
}