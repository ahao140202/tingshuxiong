import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';

void main() {
  group('Chapter', () {
    const chapter = Chapter(
      id: 0,
      title: '第一章',
      rawText: '正文',
      rewrittenText: '改写稿',
      audioPath: '/tmp/0.mp3',
      status: ChapterStatus.generated,
    );

    test('copyWith 修改指定字段并保留其余', () {
      final updated = chapter.copyWith(status: ChapterStatus.failed);
      expect(updated.status, ChapterStatus.failed);
      expect(updated.rewrittenText, '改写稿');
      expect(updated.audioPath, '/tmp/0.mp3');
      expect(updated.id, 0);
      expect(updated.title, '第一章');
    });

    test('copyWith 无参数时返回等价新实例', () {
      final copied = chapter.copyWith();
      expect(copied.rewrittenText, chapter.rewrittenText);
      expect(copied.status, chapter.status);
      expect(copied.audioPath, chapter.audioPath);
      expect(copied.errorMessage, chapter.errorMessage);
    });

    test('errorMessage 设置与显式清空', () {
      const failed = Chapter(id: 0, title: 't', rawText: 'r');
      // 设置
      final withError = failed.copyWith(errorMessage: 'LLMException: 请求失败');
      expect(withError.errorMessage, 'LLMException: 请求失败');
      // 未传参保留
      expect(withError.copyWith(status: ChapterStatus.failed).errorMessage,
          'LLMException: 请求失败');
      // 显式 null 清空
      expect(withError.copyWith(errorMessage: null).errorMessage, isNull);
    });

    test('hasAudio 仅在 generated 且存在路径时为 true', () {
      expect(chapter.hasAudio, isTrue);
      expect(
        chapter.copyWith(status: ChapterStatus.notGenerated).hasAudio,
        isFalse,
      );
      expect(chapter.copyWith(audioPath: null).hasAudio, isFalse);
      // 有路径但状态未生成也不可播放
      expect(
        chapter.copyWith(status: ChapterStatus.rewriting).hasAudio,
        isFalse,
      );
    });
  });

  group('ChapterStatus', () {
    test('isDone 覆盖 generated / failed / cancelled', () {
      expect(ChapterStatus.generated.isDone, isTrue);
      expect(ChapterStatus.failed.isDone, isTrue);
      expect(ChapterStatus.cancelled.isDone, isTrue);
      expect(ChapterStatus.notGenerated.isDone, isFalse);
      expect(ChapterStatus.rewriting.isDone, isFalse);
      expect(ChapterStatus.synthesizing.isDone, isFalse);
    });

    test('isRunnable 允许未生成/失败/已取消重新调度', () {
      expect(ChapterStatus.notGenerated.isRunnable, isTrue);
      expect(ChapterStatus.failed.isRunnable, isTrue);
      expect(ChapterStatus.cancelled.isRunnable, isTrue);
      expect(ChapterStatus.rewriting.isRunnable, isFalse);
      expect(ChapterStatus.synthesizing.isRunnable, isFalse);
      expect(ChapterStatus.generated.isRunnable, isFalse);
    });

    test('每个状态都有中文展示文案', () {
      for (final status in ChapterStatus.values) {
        expect(status.label, isNotEmpty);
      }
    });
  });

  group('Book', () {
    List<Chapter> chapters(int n) => List.generate(
          n,
          (i) => Chapter(id: i, title: '第${i + 1}章', rawText: '内容$i'),
        );

    test('replaceChapter 只替换目标章节且不修改原实例', () {
      final book = Book(id: 'b', title: 't', chapters: chapters(3));
      final updated = book.replaceChapter(
        1,
        book.chapterAt(1).copyWith(status: ChapterStatus.failed),
      );

      expect(updated.chapterAt(1).status, ChapterStatus.failed);
      expect(book.chapterAt(1).status, ChapterStatus.notGenerated);
      expect(updated.chapterCount, 3);
      expect(identical(updated.chapters, book.chapters), isFalse);
    });

    test('withPosition 更新进度并保留章节内容', () {
      final book = Book(id: 'b', title: 't', chapters: chapters(3));
      final updated = book.withPosition(2, const Duration(minutes: 5));

      expect(updated.lastChapterIndex, 2);
      expect(updated.lastPosition, const Duration(minutes: 5));
      expect(updated.chapterCount, 3);
      expect(book.lastChapterIndex, 0);
    });

    test('chapterCount 与 chapterAt 边界', () {
      final book = Book(id: 'b', title: 't', chapters: chapters(2));
      expect(book.chapterCount, 2);
      expect(book.chapterAt(0).id, 0);
      expect(book.chapterAt(1).id, 1);
      expect(() => book.chapterAt(2), throwsRangeError);
    });
  });

  group('EngineConfig / TTSConfig', () {
    test('EngineConfig 默认值', () {
      const config = EngineConfig();
      expect(config.llmKind, LLMKind.deepSeek);
      expect(config.ttsKind, TTSKind.xunfei);
      expect(config.windowSize, 2);
      expect(config.windowMaxChars, 15000);
      expect(config.maxTokens, 1500);
      expect(config.temperature, 0.7);
      expect(config.tts.voice, 'xiaoyan');
    });

    test('TTSConfig copyWith 保留未修改字段', () {
      const base = TTSConfig(voice: 'aisjiu', speed: 60);
      final updated = base.copyWith(pitch: 80);
      expect(updated.voice, 'aisjiu');
      expect(updated.speed, 60);
      expect(updated.volume, 50);
      expect(updated.pitch, 80);
    });
  });
}
