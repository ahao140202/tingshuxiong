import 'package:flutter/material.dart';
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

    test('position 超过 total 时钳制到 100% 并命中最后一句', () {
      // 播放器上报的位置可能瞬时越过总时长（如 seek 竞态），
      // 估算结果应钳制在最后一句而不是越界。
      expect(
        estimateSentenceIndex(
          position: const Duration(seconds: 20),
          total: const Duration(seconds: 10),
          sentences: const ['一。', '二。', '三。'],
        ),
        2,
      );
    });

    test('单句列表任意进度均命中该句', () {
      expect(
        estimateSentenceIndex(
          position: const Duration(seconds: 5),
          total: const Duration(seconds: 10),
          sentences: const ['唯一一句。'],
        ),
        0,
      );
    });

    test('全部句子为空串（权重和为 0）时返回 0', () {
      // 空串不占权重：按「累计权重首次覆盖进度」找不到边界，
      // 约定返回 0（命中首句），避免返回 -1 造成无高亮。
      expect(
        estimateSentenceIndex(
          position: const Duration(seconds: 5),
          total: const Duration(seconds: 10),
          sentences: const ['', ''],
        ),
        0,
      );
    });

    test('进度恰好在句子累计权重边界时命中该句（含等号）', () {
      // 两句各 5 权重（含句号）：50% 进度恰好等于第一句累计权重，
      // 应命中第一句（progress * sum <= acc 含等号）。
      expect(
        estimateSentenceIndex(
          position: const Duration(milliseconds: 5000),
          total: const Duration(seconds: 10),
          sentences: const ['一二三四。', '五六七八。'],
        ),
        0,
      );
    });

    test('空句子不占权重，不影响后续句子估算', () {
      // 权重 [0, 5, 5]：60% 越过第二句边界（5/10）进入第三句。
      expect(
        estimateSentenceIndex(
          position: const Duration(milliseconds: 6000),
          total: const Duration(seconds: 10),
          sentences: const ['', '一二三四。', '五六七八。'],
        ),
        2,
      );
    });
  });

  group('ReaderPanel 渲染', () {
    Widget wrap(ReaderPanel panel) =>
        MaterialApp(home: Scaffold(body: panel));

    testWidgets('逐句渲染且当前句加粗高亮', (tester) async {
      await tester.pumpWidget(wrap(const ReaderPanel(
        sentences: ['第一句。', '第二句。'],
        currentIndex: 0,
      )));

      expect(find.text('第一句。'), findsOneWidget);
      expect(find.text('第二句。'), findsOneWidget);
      final first = tester.widget<Text>(find.text('第一句。'));
      final second = tester.widget<Text>(find.text('第二句。'));
      expect(first.style?.fontWeight, FontWeight.w600);
      expect(second.style?.fontWeight, isNot(FontWeight.w600));
    });

    testWidgets('正文不暴露语义节点（ExcludeSemantics），避免无障碍树高频增删', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(const ReaderPanel(
        sentences: ['第一句。', '第二句。'],
        currentIndex: 0,
      )));

      // 正文逐句列表对读屏无独立价值（朗读内容即音频本身），
      // 排除语义后滚动不再增删语义节点，根除 Windows
      // accessibility_bridge 的「Nodes left pending」错误日志。
      expect(find.bySemanticsLabel('第一句。'), findsNothing);
      expect(find.bySemanticsLabel('第二句。'), findsNothing);
      handle.dispose();
    });

    testWidgets('currentIndex 变化时自动滚动跟随到当前句', (tester) async {
      final sentences = [for (var i = 0; i < 60; i++) '第 $i 句。'];
      await tester.pumpWidget(wrap(ReaderPanel(sentences: sentences)));
      // 跳到末尾句子：应自动滚动，列表滚动位置离开顶部。
      await tester.pumpWidget(wrap(ReaderPanel(
        sentences: sentences,
        currentIndex: 59,
      )));
      await tester.pumpAndSettle();

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.pixels, greaterThan(0));
    });

    testWidgets('currentIndex 越界时不滚动不崩溃', (tester) async {
      await tester.pumpWidget(wrap(const ReaderPanel(
        sentences: ['一句。'],
        currentIndex: 99,
      )));
      // 越界索引不参与高亮与滚动，页面正常渲染。
      expect(find.text('一句。'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('一句。')).style?.fontWeight,
        isNot(FontWeight.w600),
      );
    });
  });
}
