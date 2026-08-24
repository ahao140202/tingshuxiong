import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/llm/llm.dart';
import 'package:tingshuxiong/core/scheduler/scheduler.dart';
import 'package:tingshuxiong/core/tts/tts.dart';

/// 可配置失败次数的假 LLM：前 [failures] 次调用抛错，之后成功。
class FakeLLM implements LLMProvider {
  FakeLLM({this.failures = 0});

  final int failures;
  int calls = 0;
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
    calls++;
    titles.add(title);
    if (calls <= failures) throw LLMException('模拟改写失败');
    return '改写：$title';
  }
}

/// 挂在 [gate] 上的假 LLM：每次调用等待 gate 完成（用于模拟进行中的任务）。
class GatedLLM implements LLMProvider {
  GatedLLM(this.gate);

  final Completer<String> gate;
  final Completer<void> firstCallStarted = Completer<void>();

  @override
  LLMKind get kind => LLMKind.deepSeek;

  @override
  String get model => 'gated-llm';

  @override
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  }) async {
    if (!firstCallStarted.isCompleted) firstCallStarted.complete();
    return gate.future;
  }
}

/// 可配置失败次数的假 TTS：前 [failures] 次调用抛错，之后成功。
class FakeTTS implements TTSProvider {
  FakeTTS({this.failures = 0});

  final int failures;
  int calls = 0;
  final List<String> texts = [];

  @override
  TTSKind get kind => TTSKind.xunfei;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    calls++;
    texts.add(text);
    if (calls <= failures) throw TTSException('模拟合成失败');
    return Uint8List.fromList(utf8.encode('audio:$text'));
  }
}

/// 挂在 [gate] 上的假 TTS：每次调用等待 gate 完成（用于模拟合成中的任务）。
class GatedTTS implements TTSProvider {
  GatedTTS(this.gate);

  final Completer<Uint8List> gate;
  final Completer<void> firstCallStarted = Completer<void>();

  @override
  TTSKind get kind => TTSKind.xunfei;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    if (!firstCallStarted.isCompleted) firstCallStarted.complete();
    return gate.future;
  }
}

Book makeBook(int chapterCount) {
  return Book(
    id: 'book-1',
    title: '测试书',
    chapters: List.generate(
      chapterCount,
      (i) => Chapter(id: i, title: '第${i + 1}章', rawText: '第${i + 1}章内容'),
    ),
  );
}

void main() {
  group('computeWindow', () {
    test('窗口大小限制：当前章 + 后续 windowSize 章', () {
      final window = SmartScheduler.computeWindow(
        startIndex: 0,
        chapterCount: 10,
        windowSize: 2,
        windowMaxChars: 100000,
        charCountOf: (_) => 100,
      );
      expect(window, [0, 1, 2]);
    });

    test('累计字数上限截断', () {
      final window = SmartScheduler.computeWindow(
        startIndex: 0,
        chapterCount: 10,
        windowSize: 5,
        windowMaxChars: 350,
        charCountOf: (_) => 100,
      );
      // 100+100+100=300 ≤ 350，再加 100 超限 → [0,1,2]
      expect(window, [0, 1, 2]);
    });

    test('当前章超限也必加入', () {
      final window = SmartScheduler.computeWindow(
        startIndex: 5,
        chapterCount: 6,
        windowSize: 2,
        windowMaxChars: 1,
        charCountOf: (_) => 1000,
      );
      expect(window, [5]);
    });

    test('起始越界返回空', () {
      expect(
        SmartScheduler.computeWindow(
          startIndex: 10,
          chapterCount: 5,
          windowSize: 2,
          windowMaxChars: 1000,
          charCountOf: (_) => 1,
        ),
        isEmpty,
      );
    });

    test('includeStart=false 时窗口为纯后续章节（最多 windowSize 章）', () {
      final window = SmartScheduler.computeWindow(
        startIndex: 3,
        chapterCount: 10,
        windowSize: 2,
        windowMaxChars: 100000,
        charCountOf: (_) => 100,
        includeStart: false,
      );
      // 不含起始章：最多 2 章（后续 N 章），而非含起始章时的 3 章。
      expect(window, [3, 4]);
    });
  });

  group('SmartScheduler', () {
    late FakeLLM llm;
    late FakeTTS tts;
    late Map<String, Uint8List> saved;

    SmartScheduler makeScheduler({
      int maxRetries = 3,
      Future<String?> Function(
        String bookId,
        int chapterIndex,
        String text,
      )? saveRewrite,
    }) {
      return SmartScheduler(
        config: const EngineConfig(),
        llm: llm,
        tts: tts,
        maxRetries: maxRetries,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
        saveRewrite: saveRewrite,
      );
    }

    setUp(() {
      llm = FakeLLM();
      tts = FakeTTS();
      saved = {};
    });

    test('preloadWindow 仅生成窗口内章节，不继续整本生成', () async {
      final scheduler = makeScheduler(); // windowSize=2
      await scheduler.preloadWindow(makeBook(8), fromIndex: 3);

      // 窗口 = [3, 4]（后续 2 章），第 5-7 章不生成。
      expect(llm.calls, 2);
      final statuses =
          scheduler.book!.chapters.map((c) => c.status).toList();
      expect(statuses.sublist(0, 3), everyElement(ChapterStatus.notGenerated));
      expect(statuses[3], ChapterStatus.generated);
      expect(statuses[4], ChapterStatus.generated);
      expect(statuses.sublist(5), everyElement(ChapterStatus.notGenerated));
      expect(scheduler.isRunning, isFalse);
    });

    test('preloadWindow 跳过已生成章节且不重复生成', () async {
      final scheduler = makeScheduler();
      final book = makeBook(4);
      await scheduler.preloadWindow(book, fromIndex: 1);
      // 第 1、2 章已生成；复用带状态的书再次预加载同一窗口：
      // 已生成章节自动跳过，不重复调用 LLM。
      final before = llm.calls;
      await scheduler.preloadWindow(scheduler.book!, fromIndex: 1);
      expect(llm.calls, before);
    });

    test('全流程：逐章改写 → 合成 → 落盘，状态机正确流转', () async {
      final scheduler = makeScheduler();
      final emitted = <Book>[];
      scheduler.bookStream.listen(emitted.add);

      await scheduler.start(makeBook(3));

      final book = scheduler.book!;
      for (var i = 0; i < 3; i++) {
        expect(book.chapterAt(i).status, ChapterStatus.generated);
        expect(book.chapterAt(i).rewrittenText, '改写：第${i + 1}章');
        expect(book.chapterAt(i).audioPath, 'book-1-$i.mp3');
      }
      expect(tts.texts, ['改写：第1章', '改写：第2章', '改写：第3章']);
      expect(saved.keys, ['book-1-0', 'book-1-1', 'book-1-2']);
      expect(saved['book-1-0'], utf8.encode('audio:改写：第1章'));
      expect(scheduler.isRunning, isFalse);
      // 状态流包含中间态 rewriting / synthesizing
      final allStatuses = emitted
          .expand((b) => b.chapters)
          .map((c) => c.status)
          .toSet();
      expect(allStatuses, contains(ChapterStatus.rewriting));
      expect(allStatuses, contains(ChapterStatus.synthesizing));
      expect(allStatuses, contains(ChapterStatus.generated));
    });

    test('改写稿经 saveRewrite 落盘并记录 rewritePath', () async {
      final rewrites = <String>[];
      final scheduler = makeScheduler(
        saveRewrite: (bookId, chapterIndex, text) async {
          rewrites.add('$bookId-$chapterIndex:$text');
          return '$bookId-$chapterIndex.txt';
        },
      );
      await scheduler.start(makeBook(1));

      expect(rewrites, ['book-1-0:改写：第1章']);
      expect(scheduler.book!.chapterAt(0).rewritePath, 'book-1-0.txt');
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
    });

    test('改写稿落盘失败不中断主流程，仅不记录路径', () async {
      final scheduler = makeScheduler(
        saveRewrite: (bookId, chapterIndex, text) async {
          throw Exception('改写稿写盘失败');
        },
      );
      await scheduler.start(makeBook(1));

      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(0).rewrittenText, '改写：第1章');
      expect(scheduler.book!.chapterAt(0).rewritePath, isNull);
    });

    test('已生成章节跳过，不重复调用 LLM', () async {
      final book = makeBook(3).replaceChapter(
        0,
        makeBook(3)
            .chapterAt(0)
            .copyWith(rewrittenText: '已有', audioPath: 'a.mp3', status: ChapterStatus.generated),
      );
      final scheduler = makeScheduler();
      await scheduler.start(book);

      expect(llm.titles, ['第2章', '第3章']);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(2).status, ChapterStatus.generated);
    });

    test('从 lastChapterIndex 断点续传', () async {
      final scheduler = makeScheduler();
      await scheduler.start(makeBook(3).withPosition(1, Duration.zero));

      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.notGenerated);
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.generated);
      expect(llm.titles, ['第2章', '第3章']);
    });

    test('失败自动重试成功后标记 generated 且清空错误原因', () async {
      llm = FakeLLM(failures: 1);
      final scheduler = makeScheduler(maxRetries: 2);
      await scheduler.start(makeBook(1));

      expect(llm.calls, 2);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(0).errorMessage, isNull);
    });

    test('重试耗尽标记 failed 并记录失败原因，继续后续章节', () async {
      // 前 2 次调用失败（第 1 章首次 + 重试），之后成功
      llm = FakeLLM(failures: 2);
      final scheduler = makeScheduler(maxRetries: 1);
      await scheduler.start(makeBook(3));

      expect(llm.calls, 4); // 第 1 章×2 + 第 2 章 + 第 3 章
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.failed);
      expect(scheduler.book!.chapterAt(0).errorMessage, contains('模拟改写失败'));
      // 窗口内后续章节继续生成
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(2).status, ChapterStatus.generated);
    });

    test('跳章取消进行中的章节并从新章重新调度', () async {
      final gate = Completer<String>();
      final gatedLlm = GatedLLM(gate);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      final firstRun = scheduler.start(makeBook(3));
      await gatedLlm.firstCallStarted.future; // 第 1 章改写中
      final jumpRun = scheduler.jumpTo(2);
      await pumpEventQueue();
      gate.complete('改写结果');
      await firstRun;
      await jumpRun;

      final book = scheduler.book!;
      expect(book.chapterAt(0).status, ChapterStatus.cancelled);
      expect(book.chapterAt(1).status, ChapterStatus.notGenerated);
      expect(book.chapterAt(2).status, ChapterStatus.generated);
      expect(book.lastChapterIndex, 2);
    });

    test('stop 取消进行中的章节，已生成内容保留', () async {
      final gate = Completer<String>();
      final gatedLlm = GatedLLM(gate);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      // 先让第 1 章完成后停在第 2 章
      final run = scheduler.start(makeBook(3));
      await gatedLlm.firstCallStarted.future;
      gate.complete('改写结果');
      await run;
      // 此时窗口 [0,1,2] 全部完成（门控只挡第一次调用）

      final gate2 = Completer<String>();
      final gatedLlm2 = GatedLLM(gate2);
      final scheduler2 = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm2,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );
      final run2 = scheduler2.start(makeBook(3));
      await gatedLlm2.firstCallStarted.future; // 第 1 章改写中
      await scheduler2.stop();
      gate2.complete('改写结果');
      await run2;

      expect(scheduler2.book!.chapterAt(0).status, ChapterStatus.cancelled);
      expect(scheduler2.isRunning, isFalse);
    });

    test('bookStream 每次状态变化都发出最新 Book', () async {
      final scheduler = makeScheduler();
      final books = <Book>[];
      scheduler.bookStream.listen(books.add);
      await scheduler.start(makeBook(2));
      await pumpEventQueue(); // 等待广播流派发最后一条事件

      expect(books.length, greaterThanOrEqualTo(4)); // start + rewriting*2 + synthesizing*2 + generated*2
      expect(books.last.chapterAt(1).status, ChapterStatus.generated);
    });

    test('TTS 阶段失败自动重试成功后标记 generated', () async {
      tts = FakeTTS(failures: 1);
      final scheduler = makeScheduler(maxRetries: 2);
      await scheduler.start(makeBook(1));

      expect(tts.calls, 2);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
    });

    test('TTS 重试耗尽标记 failed 并记录失败原因', () async {
      tts = FakeTTS(failures: 2);
      final scheduler = makeScheduler(maxRetries: 1);
      await scheduler.start(makeBook(1));

      expect(tts.calls, 2);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.failed);
      expect(scheduler.book!.chapterAt(0).errorMessage, contains('模拟合成失败'));
    });

    test('落盘失败触发重试，成功后生成', () async {
      var saveCalls = 0;
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: llm,
        tts: tts,
        maxRetries: 2,
        saveAudio: (bookId, chapterIndex, audio) async {
          saveCalls++;
          if (saveCalls == 1) throw Exception('模拟磁盘写入失败');
          return 'book-1-0.mp3';
        },
      );
      await scheduler.start(makeBook(1));

      expect(saveCalls, 2);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
    });

    test('生成中重复 start 被忽略且不打断当前任务', () async {
      final gate = Completer<String>();
      final gatedLlm = GatedLLM(gate);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      final firstRun = scheduler.start(makeBook(2));
      await gatedLlm.firstCallStarted.future;
      // 生成中重复调用：直接返回，不递增世代号
      await scheduler.start(makeBook(2));
      expect(scheduler.isRunning, isTrue);
      gate.complete('改写结果');
      await firstRun;

      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.generated);
    });

    test('空书 start 直接完成且不崩溃', () async {
      final scheduler = makeScheduler();
      final emptyBook = Book(id: 'empty', title: '空书', chapters: []);
      await scheduler.start(emptyBook);

      expect(scheduler.book!.chapterCount, 0);
      expect(scheduler.isRunning, isFalse);
      expect(llm.calls, 0);
    });

    test('fromIndex 越界抛 ArgumentError', () async {
      final scheduler = makeScheduler();
      expect(
        () => scheduler.start(makeBook(3), fromIndex: -1),
        throwsArgumentError,
      );
      expect(
        () => scheduler.start(makeBook(3), fromIndex: 3),
        throwsArgumentError,
      );
      // 合法值不受影响
      await scheduler.start(makeBook(3), fromIndex: 1);
      expect(scheduler.book!.lastChapterIndex, 1);
    });

    test('jumpTo 越界抛 ArgumentError', () async {
      final scheduler = makeScheduler();
      await scheduler.start(makeBook(3));

      expect(() => scheduler.jumpTo(-1), throwsArgumentError);
      expect(() => scheduler.jumpTo(3), throwsArgumentError);
    });

    test('TTS 挂起时 stop 将进行中章节标记 cancelled', () async {
      final gate = Completer<Uint8List>();
      final gatedTts = GatedTTS(gate);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: llm,
        tts: gatedTts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      final run = scheduler.start(makeBook(2));
      await gatedTts.firstCallStarted.future; // 第 1 章合成中
      await scheduler.stop();
      gate.complete(Uint8List.fromList([1]));
      await run;

      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.cancelled);
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.notGenerated);
      expect(scheduler.isRunning, isFalse);
      expect(saved, isEmpty); // 被取消的任务不落盘
    });

    test('TTS 挂起时 jumpTo：旧任务不落盘，新任务正常完成', () async {
      final gate = Completer<Uint8List>();
      final gatedTts = GatedTTS(gate);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: llm,
        tts: gatedTts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      final firstRun = scheduler.start(makeBook(3));
      await gatedTts.firstCallStarted.future; // 第 1 章合成中
      final jumpRun = scheduler.jumpTo(2);
      await pumpEventQueue();
      gate.complete(Uint8List.fromList([1]));
      await firstRun;
      await jumpRun;

      final book = scheduler.book!;
      expect(book.chapterAt(0).status, ChapterStatus.cancelled);
      expect(book.chapterAt(1).status, ChapterStatus.notGenerated);
      expect(book.chapterAt(2).status, ChapterStatus.generated);
      // 仅新任务章节落盘（第 3 章），被取消的第 1 章不写入
      expect(saved.keys, ['book-1-2']);
    });

    test('stop 后立即 start 新书：新旧任务不互相干扰', () async {
      final gate1 = Completer<String>();
      final gatedLlm1 = GatedLLM(gate1);
      final scheduler = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm1,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );

      final oldRun = scheduler.start(makeBook(3));
      await gatedLlm1.firstCallStarted.future; // 旧任务第 1 章改写中
      await scheduler.stop();

      // 旧任务仍挂起时立即启动新书
      final gate2 = Completer<String>();
      final gatedLlm2 = GatedLLM(gate2);
      final scheduler2 = SmartScheduler(
        config: const EngineConfig(),
        llm: gatedLlm2,
        tts: tts,
        maxRetries: 1,
        saveAudio: (bookId, chapterIndex, audio) async {
          saved['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );
      final newRun = scheduler2.start(makeBook(1));
      await gatedLlm2.firstCallStarted.future;

      gate1.complete('旧任务结果');
      await oldRun;
      gate2.complete('新任务结果');
      await newRun;

      // 旧任务：被取消章节标记 cancelled，_running 复位不影响新任务
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.cancelled);
      expect(scheduler.isRunning, isFalse);
      // 新任务：正常完成
      expect(scheduler2.book!.chapterAt(0).status, ChapterStatus.generated);
      expect(scheduler2.isRunning, isFalse);
    });
  });

  group('generateChapter', () {
    SmartScheduler makeScheduler({
      required LLMProvider llm,
      required TTSProvider tts,
      Map<String, Uint8List>? saved,
      int maxRetries = 3,
    }) {
      final sink = saved ?? {};
      return SmartScheduler(
        config: const EngineConfig(),
        llm: llm,
        tts: tts,
        maxRetries: maxRetries,
        saveAudio: (bookId, chapterIndex, audio) async {
          sink['$bookId-$chapterIndex'] = audio;
          return '$bookId-$chapterIndex.mp3';
        },
      );
    }

    test('只生成指定章节，不进入窗口循环', () async {
      final llm = FakeLLM();
      final tts = FakeTTS();
      final scheduler = makeScheduler(llm: llm, tts: tts);
      // 未启动过窗口任务时须传入 book，仅处理指定章节。
      await scheduler.generateChapter(1, book: makeBook(3));

      // 仅第 2 章被处理（llm 只调用 1 次）。
      expect(llm.calls, 1);
      expect(llm.titles.single, '第2章');
      expect(scheduler.book!.chapterAt(1).status, ChapterStatus.generated);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.notGenerated);
      expect(scheduler.isRunning, isFalse);
    });

    test('已生成章节直接跳过', () async {
      final llm = FakeLLM();
      final tts = FakeTTS();
      final scheduler = makeScheduler(llm: llm, tts: tts);
      await scheduler.start(makeBook(1));
      final before = llm.calls;

      await scheduler.generateChapter(0);

      expect(llm.calls, before);
      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.generated);
    });

    test('单章失败按重试次数处理并标记 failed', () async {
      final llm = FakeLLM(failures: 2);
      final tts = FakeTTS();
      final scheduler = makeScheduler(llm: llm, tts: tts, maxRetries: 1);
      await scheduler.generateChapter(0, book: makeBook(1));

      expect(scheduler.book!.chapterAt(0).status, ChapterStatus.failed);
      expect(scheduler.book!.chapterAt(0).errorMessage, isNotNull);
      expect(scheduler.isRunning, isFalse);
    });
  });
}
