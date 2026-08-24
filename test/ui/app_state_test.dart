import 'dart:async';
import 'dart:io';

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

  AppState makeState({TxtPicker? picker, TingEngine? engine, BookDatabase? database}) {
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
      llmCredentials: {'apiKey': 'sk-1'},
      ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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

  test('regenerateFrom 转移旧文件到历史目录并按最新配置重新生成', () async {
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
        },
      ),
    );
    await state.generate();
    // 等待快照落库（insertSnapshot 为异步任务）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final audioPath = state.book!.chapterAt(0).audioPath!;
    final rewritePath = state.book!.chapterAt(0).rewritePath!;
    expect(await File(audioPath).exists(), isTrue);
    expect(await File(rewritePath).exists(), isTrue);

    await state.regenerateFrom(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 从第 1 章重新生成（LLM 被再次调用），状态回到 generated。
    expect(llm.calls, 2);
    final chapter = state.book!.chapterAt(0);
    expect(chapter.status, ChapterStatus.generated);
    // 新文件写到原位置（旧文件已被转移走）。
    expect(chapter.audioPath, audioPath);
    expect(await File(chapter.audioPath!).exists(), isTrue);
    expect(await File(audioPath).exists(), isTrue);

    // 旧文件已转移到历史目录（带时间戳命名，互不覆盖）。
    final historyDir = Directory(p.join(tempDir.path, 'novel.txt', 'history'));
    final historyNames = (await historyDir.list().toList())
        .map((e) => p.basename(e.path))
        .toList();
    expect(historyNames, hasLength(2));
    expect(
      historyNames.any((n) => RegExp(r'^0-\d{14}\.mp3$').hasMatch(n)),
      isTrue,
    );
    expect(
      historyNames.any((n) => RegExp(r'^0-\d{14}\.txt$').hasMatch(n)),
      isTrue,
    );

    // 快照回溯：最新一条指向当前文件，历史快照指向 history 目录。
    final snapshots = await db.loadSnapshots('novel.txt', chapterIndex: 0);
    expect(snapshots, hasLength(2));
    expect(snapshots.first.audioPath, audioPath);
    expect(snapshots.first.rewritePath, rewritePath);
    expect(snapshots.last.audioPath, startsWith(historyDir.path));
    expect(snapshots.last.rewritePath, startsWith(historyDir.path));
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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

  test('seek 代理到播放器', () async {
    final state = makeState();
    await state.init();

    await state.seek(const Duration(seconds: 30));
    expect(player.seekCalls, 1);
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

  test('continueGenerate 从第一个未完成章节继续，已生成章节不重复生成', () async {
    // 第 0 章成功、第 1 章两次调用均失败（maxRetries=1）→ failed、
    // 第 2 章成功：制造「中间断点」场景。
    final llm = FakeLLM(failOnCalls: {2, 3});
    final state = makeState(
      picker: FakeTxtPicker(
        const TxtFile(
          name: 'b.txt',
          content: '第一章 开始\n内容\n第二章 继续\n内容\n第三章 结束\n内容',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
        },
        maxRetries: 1,
      ),
    );

    await state.generate();
    expect(llm.calls, 4);
    expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
    expect(state.book!.chapterAt(1).status, ChapterStatus.failed);
    expect(state.book!.chapterAt(2).status, ChapterStatus.generated);

    // 继续生成：跳过已生成的 0、2 章，仅重做第 1 章。
    final ok = await state.continueGenerate();
    expect(ok, isTrue);
    expect(llm.calls, 5);
    expect(
      state.book!.chapters.map((c) => c.status),
      everyElement(ChapterStatus.generated),
    );

    // 全部完成后再次调用返回 false。
    expect(await state.continueGenerate(), isFalse);
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {
          'appId': 'app',
          'apiKey': 'key',
          'apiSecret': 'secret',
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
}
