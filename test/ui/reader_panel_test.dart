import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/ui/widgets/reader_panel.dart';

void main() {
  group('estimateSentenceIndex', () {
    test('空句子或总时长为零返回 -1', () {
      expect(
        estimateSentenceIndex(
          position: const Duration(seconds: 1),
          total: const Duration(seconds: 10),
          sentences: const [],
        ),
        -1,
      );
      expect(
        estimateSentenceIndex(
          position: Duration.zero,
          total: Duration.zero,
          sentences: const ['句子'],
        ),
        -1,
      );
    });

    test('进度 0 命中第一句', () {
      expect(
        estimateSentenceIndex(
          position: Duration.zero,
          total: const Duration(seconds: 10),
          sentences: const ['第一句。', '第二句。'],
        ),
        0,
      );
    });

    test('进度按句子字符数加权映射', () {
      // 两句各 4 字符：各占一半时长。
      const sentences = ['一二三四。', '五六七八。'];
      // 播放到 60% 应已越过第一句（50% 边界）。
      expect(
        estimateSentenceIndex(
          position: const Duration(milliseconds: 6000),
          total: const Duration(seconds: 10),
          sentences: sentences,
        ),
        1,
      );
    });

    test('长句占更多权重，进度过半仍在长句中', () {
      // 第一句 18 字符，第二句 2 字符：第一句占 90% 时长。
      const sentences = ['一二三四五六七八九十一二三四五六七八九。', '哦。'];
      expect(
        estimateSentenceIndex(
          position: const Duration(seconds: 5),
          total: const Duration(seconds: 10),
          sentences: sentences,
        ),
        0,
      );
      // 95% 进度：越过第一句（占 90.9%）进入第二句。
      expect(
        estimateSentenceIndex(
          position: const Duration(milliseconds: 9500),
          total: const Duration(seconds: 10),
          sentences: sentences,
        ),
        1,
      );
    });

    test('进度接近结尾时命中最后一句', () {
      expect(
        estimateSentenceIndex(
          position: const Duration(milliseconds: 9990),
          total: const Duration(seconds: 10),
          sentences: const ['一。', '二。', '三。'],
        ),
        2,
      );
    });
  });
}
