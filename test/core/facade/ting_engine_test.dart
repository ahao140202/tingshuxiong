import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/facade/facade.dart';
import 'package:tingshuxiong/core/llm/llm.dart';
import 'package:tingshuxiong/core/tts/tts.dart';

import '../../helpers/fakes.dart' as helpers;

class FakeLLM implements LLMProvider {
  final List<String> titles = [];

  @override
  LLMKind get kind => LLMKind.deepSeek;

  @override
  String get model => 'fake-llm';

  @override
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  }) async {
    titles.add(title);
    return '改写：$title';
  }
}

class FakeTTS implements TTSProvider {
  @override
  TTSKind get kind => TTSKind.xunfei;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    return Uint8List.fromList(utf8.encode('audio:$text'));
  }
}

class FakeLLMRegistry extends LLMRegistry {
  const FakeLLMRegistry();

  @override
  LLMProvider providerFor(
    LLMKind kind, {
    required Map<String, String> credentials,
  }) {
    return FakeLLM();
  }
}

class FakeTTSRegistry extends TTSRegistry {
  const FakeTTSRegistry();

  @override
  TTSProvider providerFor(
    TTSKind kind, {
    required Map<String, String> credentials,
  }) {
    return FakeTTS();
  }
}

void main() {
  final engine = TingEngine(
    llmRegistry: const FakeLLMRegistry(),
    ttsRegistry: const FakeTTSRegistry(),
  );

  group('TingEngine', () {
    test('未配置时控制方法与 book 抛 StateError，bookStream 可安全订阅', () {
      expect(() => engine.start(Book(id: 'b', title: 't', chapters: [])),
          throwsStateError);
      expect(() => engine.book, throwsStateError);
      // bookStream 为稳定流，配置前订阅不抛错
      expect(engine.bookStream, isA<Stream<Book>>());
    });

    test('importBook 切分章节', () {
      final book = engine.importBook(
        id: 'novel.txt',
        title: '小说',
        fullText: '第一章 相遇\n正文一\n第二章 离别\n正文二',
      );
      expect(book.id, 'novel.txt');
      expect(book.title, '小说');
      expect(book.chapterCount, 2);
      expect(book.chapterAt(0).title, '第一章 相遇');
      expect(book.chapterAt(0).status, ChapterStatus.notGenerated);
    });

    test('configure 后全流程生成', () async {
      final saved = <String, Uint8List>{};
      engine.configure(
        llmKind: LLMKind.deepSeek,
        llmCredentials: {'apiKey': 'sk-test'},
        ttsKind: TTSKind.xunfei,
        ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );
      expect(engine.isConfigured, isTrue);

      final book = engine.importBook(
        id: 'novel.txt',
        title: '小说',
        fullText: '第一章 相遇\n正文一\n第二章 离别\n正文二',
      );
      await engine.start(book);

      expect(engine.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(engine.book!.chapterAt(0).rewrittenText, '改写：第一章 相遇');
      expect(engine.book!.chapterAt(0).audioPath, 'novel.txt-0.mp3');
      expect(saved.keys, ['novel.txt-0', 'novel.txt-1']);
      expect(engine.isRunning, isFalse);
    });

    test('重新 configure 可更换凭据', () async {
      engine.configure(
        llmKind: LLMKind.deepSeek,
        llmCredentials: {'apiKey': 'sk-new'},
        ttsKind: TTSKind.xunfei,
        ttsCredentials: {
          'appId': 'app-new',
          'apiKey': 'key-new',
          'apiSecret': 'secret-new',
        },
        saveAudio: (bookId, chapterIndex, audio) async => 'x.mp3',
      );
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 开始\n内容',
      );
      await engine.start(book);
      expect(engine.book!.chapterAt(0).status, ChapterStatus.generated);
    });

    test('start(fromIndex) 从指定章节开始，跳过之前的章节', () async {
      final llm = FakeLLM();
      final engine = _makeEngine(llm);
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 相遇\n正文\n第二章 离别\n正文\n第三章 重逢\n正文',
      );

      await engine.start(book, fromIndex: 1);

      expect(llm.titles, ['第二章 离别', '第三章 重逢']);
      expect(engine.book!.chapterAt(0).status, ChapterStatus.notGenerated);
      expect(engine.book!.chapterAt(1).status, ChapterStatus.generated);
      expect(engine.book!.lastChapterIndex, 1);
    });

    test('jumpTo 取消进行中任务并从新章重新调度', () async {
      final engine = _makeEngine();
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 相遇\n正文\n第二章 离别\n正文\n第三章 重逢\n正文',
      );
      await engine.start(book);
      expect(engine.book!.chapterAt(0).status, ChapterStatus.generated);

      // 已生成后跳章：从第 2 章重新生成（仍为 generated）
      await engine.jumpTo(1);
      expect(engine.book!.lastChapterIndex, 1);
      expect(engine.book!.chapterAt(1).status, ChapterStatus.generated);
    });

    test('stop 停止生成，已生成内容保留', () async {
      final engine = _makeEngine();
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 相遇\n正文\n第二章 离别\n正文',
      );
      await engine.start(book);
      expect(engine.isRunning, isFalse);

      await engine.stop();
      expect(engine.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(engine.isRunning, isFalse);
    });

    test('重新 configure 后既有订阅者仍持续收到更新（流转接）', () async {
      final engine = _makeEngine();
      final books = <Book>[];
      engine.bookStream.listen(books.add);

      // 第一次 configure + start
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 相遇\n正文',
      );
      await engine.start(book);
      expect(books.last.chapterAt(0).status, ChapterStatus.generated);

      // 重新 configure（重建调度器）后再次 start，旧订阅者仍能收到
      engine.configure(
        llmKind: LLMKind.deepSeek,
        llmCredentials: {'apiKey': 'sk-again'},
        ttsKind: TTSKind.xunfei,
        ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        saveAudio: (bookId, chapterIndex, audio) async => 'x.mp3',
      );
      final before = books.length;
      await engine.start(book);
      expect(books.length, greaterThan(before));
      expect(books.last.chapterAt(0).status, ChapterStatus.generated);
    });

    test('configure 重建时取消进行中的旧任务（不再继续落盘）', () async {
      final llm = helpers.FakeLLM(gate: Completer<String>());
      final engine = TingEngine(
        llmRegistry: helpers.FakeLLMRegistry(llm),
        ttsRegistry: const helpers.FakeTTSRegistry(),
      );
      final books = <Book>[];
      engine.bookStream.listen(books.add);
      var savedCount = 0;

      void doConfigure() {
        engine.configure(
          llmKind: LLMKind.deepSeek,
          llmCredentials: {'apiKey': 'sk-test'},
          ttsKind: TTSKind.xunfei,
          ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
          saveAudio: (bookId, chapterIndex, audio) async {
            savedCount++;
            return '$bookId-$chapterIndex.mp3';
          },
        );
      }

      doConfigure();
      final book = engine.importBook(
        id: 'b',
        title: 't',
        fullText: '第一章 相遇\n正文',
      );
      final startFuture = engine.start(book);
      await llm.firstCallStarted.future;
      expect(engine.isRunning, isTrue);

      // 重建配置：旧调度器任务被取消（章节标记 cancelled），不再继续合成与落盘
      doConfigure();
      llm.gate!.complete('改写：第一章 相遇');

      await startFuture;
      expect(savedCount, 0);
      expect(books.last.chapterAt(0).status, ChapterStatus.cancelled);
    });

    test('jumpTo / stop 未配置时抛 StateError', () {
      final engine = TingEngine(
        llmRegistry: const FakeLLMRegistry(),
        ttsRegistry: const FakeTTSRegistry(),
      );
      expect(() => engine.stop(), throwsStateError);
      expect(() => engine.jumpTo(0), throwsStateError);
    });
  });
}

/// 构造已 [configure] 的引擎（隔离测试间状态），LLM 使用 [llm] 或新建。
TingEngine _makeEngine([FakeLLM? llm]) {
  final engine = TingEngine(
    llmRegistry: _FakeLLMRegistry(llm ?? FakeLLM()),
    ttsRegistry: const FakeTTSRegistry(),
  );
  engine.configure(
    llmKind: LLMKind.deepSeek,
    llmCredentials: {'apiKey': 'sk-test'},
    ttsKind: TTSKind.xunfei,
    ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
    saveAudio: (bookId, chapterIndex, audio) async {
      return '$bookId-$chapterIndex.mp3';
    },
  );
  return engine;
}

class _FakeLLMRegistry extends LLMRegistry {
  const _FakeLLMRegistry(this.provider);

  final FakeLLM provider;

  @override
  LLMProvider providerFor(
    LLMKind kind, {
    required Map<String, String> credentials,
  }) {
    return provider;
  }
}
