import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/facade/facade.dart';
import 'package:tingshuxiong/platform/platform.dart';
import 'package:tingshuxiong/ui/state/app_state.dart';

import '../helpers/fakes.dart';

void main() {
  late Directory tempDir;
  late File settingsFile;
  late FakeAudio player;
  late AudioStore audioStore;
  late SettingsStore settingsStore;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_state_test');
    settingsFile = File('${tempDir.path}${Platform.pathSeparator}settings.json');
    player = FakeAudio();
    audioStore = AudioStore(rootProvider: () async => tempDir);
    settingsStore = SettingsStore(fileProvider: () async => settingsFile);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  AppState makeState({
    TxtPicker? picker,
    TingEngine? engine,
    BookDatabase? database,
    AudioExporter? audioExporter,
  }) {
    return AppState(
      engine: engine ??
          TingEngine(
            llmRegistry: const FakeLLMRegistry(),
            ttsRegistry: const FakeTTSRegistry(),
          ),
      settingsStore: settingsStore,
      audioStore: audioStore,
      filePicker: picker ?? FakeTxtPicker(null),
      player: player,
      database: database,
      audioExporter: audioExporter,
    );
  }

  test('init 加载默认设置并装配引擎', () async {
    final state = makeState();
    expect(state.initialized, isFalse);

    await state.init();

    expect(state.initialized, isTrue);
    expect(state.settings, const AppSettings());
    expect(state.canGenerate, isFalse);
  });

  test('importBook 切分章节并更新 book', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文\n第二章 离别\n正文'),
      ),
    );
    await state.init();
    expect(state.book, isNull);

    await state.importBook();

    expect(state.book!.title, 'novel.txt');
    expect(state.book!.chapterCount, 2);
  });

  test('importBook 取消选择时不改变状态', () async {
    final state = makeState(picker: FakeTxtPicker(null));
    await state.init();
    await state.importBook();
    expect(state.book, isNull);
  });

  test('applySettings 持久化并更新 canGenerate', () async {
    final state = makeState();
    await state.init();

    const settings = AppSettings(
      llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
      ttsCredentialsByKind: {
        'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
      },
    );
    await state.applySettings(settings);

    expect(state.settings, settings);
    expect(state.canGenerate, isFalse); // 尚未导入书
    // 已持久化
    expect((await settingsStore.load()).llmCredentials, {'apiKey': 'sk-1'});
  });

  test('generate 全流程生成章节音频并落盘', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    expect(state.canGenerate, isTrue);

    await state.generate();

    final chapter = state.book!.chapterAt(0);
    expect(chapter.status, ChapterStatus.generated);
    expect(chapter.rewrittenText, '改写：第一章 相遇');
    expect(
      chapter.audioPath,
      endsWith('${Platform.pathSeparator}${p.join('novel.txt', 'audio', '0.mp3')}'),
    );
    expect(state.isGenerating, isFalse);
    // 音频真实落盘
    expect(await File(chapter.audioPath!).exists(), isTrue);
  });

  test('凭据缺失时 generate 不执行', () async {
    final state = makeState(
      picker: FakeTxtPicker(const TxtFile(name: 'b.txt', content: '第一章 开始\n内容')),
    );
    await state.init();
    await state.importBook();

    await state.generate();

    expect(state.book!.chapterAt(0).status, ChapterStatus.notGenerated);
  });

  test('playChapter 播放章节音频', () async {
    final state = makeState(
      picker: FakeTxtPicker(const TxtFile(name: 'b.txt', content: '第一章 开始\n内容')),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();

    await state.playChapter(0);

    expect(state.playingIndex, 0);
    expect(player.playedPath, state.book!.chapterAt(0).audioPath);
  });

  test('playOrGenerate 无音频章节先生成再播放并预加载窗口', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容\n第三章 结束\n内容',
        ),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );

    // 未预生成，直接点播放：先生成第 0 章并播放。
    final ok = await state.playOrGenerate(0);
    expect(ok, isTrue);
    expect(state.playingIndex, 0);
    expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
    expect(player.playedPath, state.book!.chapterAt(0).audioPath);

    // 预加载窗口：后续章节后台生成（FakeLLM/FakeTTS 同步完成，等一轮事件循环）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(state.book!.chapterAt(1).status, ChapterStatus.generated);
  });

  test('playOrGenerate 已有音频时直接播放并预加载窗口', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容',
        ),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();

    final ok = await state.playOrGenerate(0);
    expect(ok, isTrue);
    expect(player.playedPath, state.book!.chapterAt(0).audioPath);
  });

  test('playOrGenerate 无凭据时返回 false 不播放', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
    );
    await state.init();
    await state.importBook();

    final ok = await state.playOrGenerate(0);
    expect(ok, isFalse);
    expect(player.playedPath, isNull);
    expect(state.book!.chapterAt(0).status, ChapterStatus.notGenerated);
  });

  test('togglePlay 在无播放时不动作', () async {
    final state = makeState();
    await state.init();

    await state.togglePlay();
    expect(player.pauseCalls, 0);
    expect(player.resumeCalls, 0);
  });

  test('stopGenerating 取消进行中章节', () async {
    final gate = Completer<String>();
    final llm = FakeLLM(gate: gate);
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );

    final generateFuture = state.generate();
    await llm.firstCallStarted.future; // 改写挂起中
    expect(state.isGenerating, isTrue);

    await state.stopGenerating();
    gate.complete('改写结果');
    await generateFuture;

    expect(state.book!.chapterAt(0).status, ChapterStatus.cancelled);
    expect(state.isGenerating, isFalse);
  });

  test('regenerateChapter 重试失败章节并成功', () async {
    final llm = FakeLLM(failures: 4); // 首次 + 默认 3 次重试全部失败
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );

    await state.generate();
    expect(state.book!.chapterAt(0).status, ChapterStatus.failed);

    await state.regenerateChapter(0);

    expect(llm.calls, 5);
    expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
  });

  test('outputRoot 设置后生成文件写入自定义根目录', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
        outputRoot:
            '${tempDir.path}${Platform.pathSeparator}custom-root',
      ),
    );
    await state.generate();

    final audioPath = state.book!.chapterAt(0).audioPath!;
    expect(
      audioPath,
      startsWith(
        '${tempDir.path}${Platform.pathSeparator}custom-root',
      ),
    );
    expect(await File(audioPath).exists(), isTrue);
  });

  test('clearAll 删除全部已生成文件并重置状态（不触发生成）', () async {
    final llm = FakeLLM();
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
      database: db,
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    // 等待异步落库完成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final audioPath = state.book!.chapterAt(0).audioPath!;
    final rewritePath = state.book!.chapterAt(0).rewritePath!;
    expect(await File(audioPath).exists(), isTrue);
    expect(await File(rewritePath).exists(), isTrue);

    await state.clearAll();

    // 文件已删除、状态重置为未生成（不触发生成，LLM 调用次数不变）。
    expect(await File(audioPath).exists(), isFalse);
    expect(await File(rewritePath).exists(), isFalse);
    expect(llm.calls, 1);
    final chapter = state.book!.chapterAt(0);
    expect(chapter.status, ChapterStatus.notGenerated);
    expect(chapter.audioPath, isNull);
    expect(chapter.rewritePath, isNull);
    expect(chapter.rewrittenText, isNull);
    expect(chapter.errorMessage, isNull);

    // 等待落库完成后重启恢复：清空状态已持久化。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restored = makeState(database: db);
    await restored.init();
    expect(restored.book!.chapterAt(0).status, ChapterStatus.notGenerated);
  });

  test('deleteBook 删除书架记录与生成文件，当前书复位', () async {
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
      database: db,
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    // 等待异步落库完成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final audioPath = state.book!.chapterAt(0).audioPath!;
    final rewritePath = state.book!.chapterAt(0).rewritePath!;
    expect(await File(audioPath).exists(), isTrue);
    expect(state.books, hasLength(1));

    await state.deleteBook('novel.txt');

    // 书架清空、当前书复位、文件全部删除。
    expect(state.books, isEmpty);
    expect(state.book, isNull);
    expect(await File(audioPath).exists(), isFalse);
    expect(await File(rewritePath).exists(), isFalse);

    // 等待落库完成后重启恢复：数据库记录已删除，不残留该书。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restored = makeState(database: db);
    await restored.init();
    expect(restored.books, isEmpty);
    expect(restored.book, isNull);
  });

  test('togglePlay 播放中暂停、暂停后恢复', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();

    await state.playChapter(0);
    expect(state.isPlaying, isTrue);

    await state.togglePlay();
    expect(player.pauseCalls, 1);
    expect(state.isPlaying, isFalse);

    await state.togglePlay();
    expect(player.resumeCalls, 1);
    expect(state.isPlaying, isTrue);
  });

  test('seek 代理到播放器并立即同步 UI 位置（绕过节流）', () async {
    final state = makeState();
    await state.init();
    final received = <Duration>[];
    final sub = state.playerPositionStream.listen(received.add);

    // 先发射一个位置事件，300ms 后仍处于 500ms 节流窗口内。
    player.emitPosition(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // seek 的目标位置必须立即出现在 UI 流（不被节流窗口吞掉），
    // 否则拖动进度条后正文高亮与时间显示不会更新。
    await state.seek(const Duration(seconds: 30));
    expect(player.seekCalls, 1);
    expect(player.lastSeekPosition, const Duration(seconds: 30));
    expect(received, contains(const Duration(seconds: 30)));
    await sub.cancel();
  });

  test('seek 后播放器旧位置事件不覆盖 UI 同步位置', () async {
    final state = makeState();
    await state.init();
    final received = <Duration>[];
    final sub = state.playerPositionStream.listen(received.add);

    await state.seek(const Duration(seconds: 30));
    // 播放器 seek 完成后可能立即上报 seek 前/期间的位置（底层竞态），
    // 该事件落在节流窗口内应被吞掉，不覆盖刚同步的目标位置。
    player.emitPosition(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(received.last, const Duration(seconds: 30));
    await sub.cancel();
  });

  test('播放器 seek 抛异常时不向上抛，UI 位置仍同步', () async {
    final state = makeState();
    await state.init();
    player.failSeek = true;
    final received = <Duration>[];
    final sub = state.playerPositionStream.listen(received.add);

    // 播放器底层 seek 失败不应导致应用崩溃，UI 仍按目标位置同步。
    await state.seek(const Duration(seconds: 30));
    expect(player.seekCalls, 1);
    expect(received.last, const Duration(seconds: 30));
    await sub.cancel();
  });

  test('进度流按 500ms 节流，降低 UI 刷新频率', () async {
    final state = makeState();
    final received = <Duration>[];
    final sub = state.playerPositionStream.listen(received.add);
    // 连续快速发射：节流窗口内只放行首个事件。
    player.emitPosition(const Duration(seconds: 1));
    player.emitPosition(const Duration(seconds: 2));
    player.emitPosition(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(received, [const Duration(seconds: 1)]);
    // 间隔足够后新事件正常放行。
    player.emitPosition(const Duration(seconds: 4));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(received, [const Duration(seconds: 1), const Duration(seconds: 4)]);
    await sub.cancel();
  });

  test('重复 init 幂等且不抛错', () async {
    final state = makeState();
    await state.init();
    await state.init();
    expect(state.initialized, isTrue);
    expect(state.settings, const AppSettings());
  });

  test('generateOrContinue 无生成记录时从第 1 章整本生成', () async {
    final llm = FakeLLM();
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容\n第三章 尾声\n内容',
        ),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );

    // 无任何生成记录：从第 1 章起整本生成。
    final ok = await state.generateOrContinue();
    expect(ok, isTrue);
    expect(llm.calls, 3);
    expect(
      state.book!.chapters.map((c) => c.status),
      everyElement(ChapterStatus.generated),
    );

    // 全部完成后再次调用返回 false（调用方提示无需继续）。
    expect(await state.generateOrContinue(), isFalse);
  });

  test('generateOrContinue 有记录时从最后一个已生成章节之后继续', () async {
    // failOnCalls {3,4,5,6}：第 2 章初始 + 3 次重试全部失败 → failed；
    // 第 0、1 章正常生成。
    final llm = FakeLLM(failOnCalls: {3, 4, 5, 6});
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容\n第三章 尾声\n内容',
        ),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    expect(llm.calls, 6);
    expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
    expect(state.book!.chapterAt(1).status, ChapterStatus.generated);
    expect(state.book!.chapterAt(2).status, ChapterStatus.failed);

    // 有生成记录：从最后一个已生成章节（第 1 章）之后继续，
    // 仅重做第 2 章，已生成的 0、1 章不被重复调用。
    final ok = await state.generateOrContinue();
    expect(ok, isTrue);
    expect(llm.calls, 7);
    expect(
      state.book!.chapters.map((c) => c.status),
      everyElement(ChapterStatus.generated),
    );
  });

  test('generateOrContinue 最后生成章节之后无未完成章节时返回 false', () async {
    // failOnCalls {2,3,4,5}：第 1 章初始 + 3 次重试全部失败 → failed；
    // 第 2 章（调用 6）正常生成 → [已生成, 失败, 已生成]。
    final llm = FakeLLM(failOnCalls: {2, 3, 4, 5});
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容\n第三章 尾声\n内容',
        ),
      ),
      engine: TingEngine(
        llmRegistry: FakeLLMRegistry(llm),
        ttsRegistry: const FakeTTSRegistry(),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    expect(state.book!.chapterAt(1).status, ChapterStatus.failed);
    expect(state.book!.chapterAt(2).status, ChapterStatus.generated);

    // 最后一个已生成章节是第 2 章，其后无未完成章节：按「从最后生成
    // 记录之后继续」的语义返回 false；其之前的失败章节保持原状，
    // 可由章节卡片单独重试，不被静默跳过也不被自动重做。
    expect(await state.generateOrContinue(), isFalse);
    expect(llm.calls, 6);
    expect(state.book!.chapterAt(1).status, ChapterStatus.failed);
  });

  test('自动连播：播放完成后按章节顺序播下一章', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容',
        ),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    await state.playChapter(0);
    expect(state.playingIndex, 0);

    // 模拟第 0 章自然播放完成：自动切到下一章播放。
    player.emitComplete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(state.playingIndex, 1);
    expect(player.playedPath, state.book!.chapterAt(1).audioPath);
  });

  test('自动连播：最后一章播完停止', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容',
        ),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    await state.playChapter(1);
    final lastPath = player.playedPath;

    player.emitComplete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 已到最后一章：不继续连播，播放位置与文件均不变。
    expect(state.playingIndex, 1);
    expect(player.playedPath, lastPath);
  });

  test('播放触发预加载仅生成窗口内章节，不整本生成', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 一\n内容\n第二章 二\n内容\n第三章 三\n内容\n第四章 四\n内容',
        ),
      ),
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
        windowSize: 1,
      ),
    );

    // 未预生成，点播放先生成第 0 章并播放；预加载窗口=后续 1 章。
    final ok = await state.playOrGenerate(0);
    expect(ok, isTrue);
    expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 仅窗口内（第 1 章）被后台生成，第 2、3 章保持未生成。
    expect(state.book!.chapterAt(1).status, ChapterStatus.generated);
    expect(state.book!.chapterAt(2).status, ChapterStatus.notGenerated);
    expect(state.book!.chapterAt(3).status, ChapterStatus.notGenerated);
  });

  test('exportAudio 未导入书时抛错，导入后委托导出器导出', () async {
    // 未导入书：直接抛 StateError（调用方负责提示）。
    final empty = makeState();
    await empty.init();
    await expectLater(empty.exportAudio(), throwsStateError);

    // 导入书后：导出请求转发给注入的导出器并返回其结果。
    final exporter = FakeAudioExporter(
      const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
    );
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
      audioExporter: exporter,
    );
    await state.init();
    await state.importBook();
    final result = await state.exportAudio();
    expect(result.exported, 1);
    expect(result.targetDir, '/tmp/export');
    expect(exporter.exportedBook, same(state.book));
  });

  test('mergeExportAudio 未导入书时抛错，导入后委托导出器聚合', () async {
    // 未导入书：直接抛 StateError（调用方负责提示）。
    final empty = makeState();
    await empty.init();
    await expectLater(empty.mergeExportAudio(), throwsStateError);

    // 导入书后：聚合请求转发给注入的导出器并返回其结果。
    final exporter = FakeAudioExporter(
      const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
      mergeResult: const AudioMergeResult(
        filePaths: ['/tmp/merge/novel.txt_聚合_001_第1-1章.mp3'],
        mergedCount: 1,
        targetDir: '/tmp/merge',
      ),
    );
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
      audioExporter: exporter,
    );
    await state.init();
    await state.importBook();
    final result = await state.mergeExportAudio();
    expect(result.mergedCount, 1);
    expect(result.targetDir, '/tmp/merge');
    expect(exporter.mergedBook, same(state.book));
  });

  test('importBook 后书架列表立即包含新书（无数据库时仅内存）', () async {
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
    );
    await state.init();
    expect(state.books, isEmpty);

    await state.importBook();

    expect(state.books.map((b) => b.id), ['novel.txt']);
  });

  test('init 加载书架全部书籍并按导入时间倒序', () async {
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);

    // 依次导入两本书（a 先、b 后），等待异步落库完成。
    final first = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'a.txt', content: '第一章 开始\n内容'),
      ),
      database: db,
    );
    await first.init();
    await first.importBook();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final second = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
      database: db,
    );
    await second.init();
    await second.importBook();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // 新状态启动：书架恢复全部书，后导入的 b.txt 排最前（导入时间倒序）。
    final restored = makeState(database: db);
    await restored.init();
    expect(restored.books.map((b) => b.id), ['b.txt', 'a.txt']);
    // 上次打开的书同时恢复。
    expect(restored.book!.id, 'b.txt');
  });

  test('openBook 切换当前书为书架中的书并重置播放位置', () async {
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);

    final first = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'a.txt', content: '第一章 开始\n内容'),
      ),
      database: db,
    );
    await first.init();
    await first.importBook();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      ),
      database: db,
    );
    await second.init();
    await second.importBook();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final state = makeState(database: db);
    await state.init();
    expect(state.book!.id, 'b.txt'); // 恢复最近打开的书

    // 点击书架中的 a.txt：切换当前书，播放位置重置。
    final aBook = state.books.firstWhere((b) => b.id == 'a.txt');
    state.openBook(aBook);
    expect(state.book!.id, 'a.txt');
    expect(state.playingIndex, -1);

    // 再次打开同一本书：幂等，不重复切换。
    state.openBook(aBook);
    expect(state.book!.id, 'a.txt');
  });

  test('init 从数据库恢复上次打开的书与章节状态', () async {
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);

    // 第一个状态导入书并等待异步落库完成。
    final first = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'novel.txt',
          content: '第一章 相遇\n正文\n第二章 离别\n正文',
        ),
      ),
      database: db,
    );
    await first.init();
    await first.importBook();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 新状态（同一数据库）init 时恢复上次的书：标题、章节数、章节内容一致。
    final restored = makeState(database: db);
    expect(restored.book, isNull);
    await restored.init();
    expect(restored.book, isNotNull);
    expect(restored.book!.title, 'novel.txt');
    expect(restored.book!.chapterCount, 2);
    expect(restored.book!.chapterAt(0).title, '第一章 相遇');
    expect(restored.book!.chapterAt(1).rawText, '正文');
  });

  test('播放进度按 5 秒节流写入数据库，playerStateStream 反映播放状态', () async {
    final db = BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
    addTearDown(db.close);
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(name: 'novel.txt', content: '第一章 相遇\n正文'),
      ),
      database: db,
    );
    await state.init();
    await state.importBook();
    await state.applySettings(
      const AppSettings(
        llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
        ttsCredentialsByKind: {
          'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        },
      ),
    );
    await state.generate();
    // 先订阅再播放：broadcast 流不缓存事件，状态变更在 playChapter 内发射。
    final playingEvent = state.playerStateStream.first;
    await state.playChapter(0);
    // playerStateStream 透传播放器状态流。
    expect(await playingEvent, PlayerState.playing);

    // 首次位置事件：距上次保存（初始为 epoch）远超 5 秒 → 立即落库。
    player.emitPosition(const Duration(seconds: 6));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      (await db.loadLatestBook())!.lastPosition,
      const Duration(seconds: 6),
    );

    // 节流窗口内（真实时间不足 5 秒）的位置事件不重复落库。
    player.emitPosition(const Duration(seconds: 7));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      (await db.loadLatestBook())!.lastPosition,
      const Duration(seconds: 6),
    );
  });
}
