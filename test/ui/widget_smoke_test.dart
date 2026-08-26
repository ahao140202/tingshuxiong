import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/facade/facade.dart';
import 'package:tingshuxiong/platform/platform.dart';
import 'package:tingshuxiong/ui/app.dart';
import 'package:tingshuxiong/ui/state/app_state.dart';
import 'package:tingshuxiong/ui/widgets/chapter_tile.dart';
import 'package:tingshuxiong/ui/widgets/reader_panel.dart';

import '../helpers/fakes.dart';

/// 返回「标题 + 换行 + 正文」的假 LLM：改写稿含多个句子，
/// 便于断言阅读面板高亮随播放进度/进度条拖动切换。
class MultiSentenceLLM extends FakeLLM {
  @override
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  }) async {
    return '改写：$title\n$rawText';
  }
}

/// 带完整凭据的设置（生成与播放链路可用）。
const AppSettings _fullSettings = AppSettings(
  llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
  ttsCredentialsByKind: {
    'xunfei': {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
  },
);

/// 按顺序返回预设文件的文件选择桩（书架多书导入测试用）。
class QueueTxtPicker implements TxtPicker {
  QueueTxtPicker(this.files);

  final List<TxtFile?> files;
  int _index = 0;

  @override
  Future<TxtFile?> pick() async {
    if (_index >= files.length) return null;
    return files[_index++];
  }
}

void main() {
  late Directory tempDir;
  late FakeAudio player;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('widget_smoke_test');
    player = FakeAudio();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<AppState> makeState(
    WidgetTester tester, {
    TxtFile? file,
    TingEngine? engine,
    AudioExporter? audioExporter,
    TxtPicker? picker,
  }) async {
    final state = AppState(
      engine: engine ??
          TingEngine(
            llmRegistry: const FakeLLMRegistry(),
            ttsRegistry: const FakeTTSRegistry(),
          ),
      settingsStore: SettingsStore(
        fileProvider: () async =>
            File('${tempDir.path}${Platform.pathSeparator}settings.json'),
      ),
      audioStore: AudioStore(rootProvider: () async => tempDir),
      filePicker: picker ?? FakeTxtPicker(file),
      player: player,
      audioExporter: audioExporter,
    );
    // init 涉及真实文件 IO，需在 runAsync 中执行
    await tester.runAsync(() => state.init());
    return state;
  }

  /// 构造「第一章已生成并正在播放」的播放页。
  ///
  /// 走真实生成链路（假 LLM/TTS 即时成功 + 音频落盘），文件 IO 需在
  /// runAsync 中执行；随后模拟上报音频总时长以激活进度条。
  ///
  /// 注意：duration 事件经 broadcast StreamController 异步派发（microtask），
  /// 必须用带时钟推进的 pump 让其送达 StreamBuilder；裸 pump() 不推进
  /// 时钟、不清 microtask 队列，事件会滞留导致时长始终为 0（进度条禁用）。
  Future<void> pumpPlaying(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(TingApp(appState: state));
    await tester.tap(find.text('导入小说'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => state.playOrGenerate(0));
    await tester.pumpAndSettle();
    player.emitDuration(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  /// 阅读面板中当前加粗（w600）的句子文本，用于断言高亮跟随。
  String? boldSentence(WidgetTester tester) {
    final texts = tester.widgetList<Text>(find.descendant(
      of: find.byType(ReaderPanel),
      matching: find.byType(Text),
    ));
    for (final t in texts) {
      if (t.style?.fontWeight == FontWeight.w600) return t.data;
    }
    return null;
  }

  group('TingApp 冒烟', () {
    testWidgets('初始化完成后直接进入书架页', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));
      expect(find.text('书架空空如也'), findsOneWidget);
    });

    testWidgets('书架空状态渲染', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));
      expect(find.text('书架空空如也'), findsOneWidget);
      expect(find.text('点击右下角「导入小说」选择 txt 文件'), findsOneWidget);
      expect(find.text('导入小说'), findsOneWidget);
    });

    testWidgets('导入书籍后书架卡片展示书名与章节数', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(
          name: 'novel.txt',
          content: '第一章 相遇\n正文一\n第二章 离别\n正文二',
        ),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.pumpAndSettle();
      expect(find.text('书架空空如也'), findsOneWidget);

      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 导入后自动进入播放页：标题栏与章节列表可见
      expect(find.text('书架空空如也'), findsNothing);
      expect(find.text('novel.txt'), findsOneWidget);
      expect(find.text('离线缓存'), findsOneWidget);
      expect(find.text('第一章 相遇'), findsOneWidget);
      expect(find.text('第二章 离别'), findsOneWidget);
    });

    testWidgets('书架展示全部导入书籍，按导入时间倒序，点击切换当前书', (tester) async {
      final state = await makeState(
        tester,
        picker: QueueTxtPicker([
          const TxtFile(name: 'a.txt', content: '第一章 开始\n内容'),
          const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        ]),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.pumpAndSettle();
      expect(find.text('书架空空如也'), findsOneWidget);

      // 导入第一本 → 自动进入播放页，返回后书架显示 1 张卡片。
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      expect(find.text('a.txt'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('书架空空如也'), findsNothing);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('共 1 章 · 上次读到第 1 章'), findsOneWidget);

      // 导入第二本 → 播放页 → 返回书架。
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      expect(find.text('b.txt'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // 书架展示两本，最新导入的 b.txt 排最前（y 坐标更小）。
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('b.txt'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('b.txt')).dy,
        lessThan(tester.getTopLeft(find.text('a.txt')).dy),
      );

      // 点击 a.txt 卡片：切换当前书并进入播放页。
      await tester.tap(find.text('a.txt'));
      await tester.pumpAndSettle();
      expect(state.book!.id, 'a.txt');
      expect(find.text('第一章 开始'), findsOneWidget); // 播放页章节列表
    });

    testWidgets('删除小说需确认：取消保留，确认后卡片移除并提示', (tester) async {
      final state = await makeState(
        tester,
        picker: QueueTxtPicker([
          const TxtFile(name: 'a.txt', content: '第一章 开始\n内容'),
          const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        ]),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.pumpAndSettle();

      // 导入两本 → 返回书架。
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('b.txt'), findsOneWidget);

      // 定位 a.txt 卡片内的删除按钮 → 确认对话框（含书名与不可恢复提示）。
      final deleteA = find.descendant(
        of: find.widgetWithText(Card, 'a.txt'),
        matching: find.byIcon(Icons.delete_outline),
      );
      await tester.tap(deleteA);
      await tester.pumpAndSettle();
      expect(find.text('删除小说'), findsOneWidget);
      expect(find.textContaining('将删除《a.txt》'), findsOneWidget);

      // 取消：对话框关闭且不删除。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('a.txt'), findsOneWidget);
      expect(state.books, hasLength(2));

      // 再次打开并确认：删除完成（真实文件 IO 清理书目录），
      // 卡片移除 + SnackBar 反馈。
      await tester.tap(deleteA);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      for (var i = 0; i < 40 && state.books.any((b) => b.id == 'a.txt'); i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(state.books.any((b) => b.id == 'a.txt'), isFalse);
      expect(find.text('a.txt'), findsNothing);
      expect(find.text('b.txt'), findsOneWidget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('已删除《a.txt》'), findsOneWidget);
    });
  });

  group('PlayerScreen 冒烟', () {
    testWidgets('无凭据时显示提示且生成按钮禁用', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      expect(find.text('请先在设置中填写 API 凭据'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '离线缓存'),
      );
      expect(button.onPressed, isNull);
      // 无生成记录：全部清空按钮同样禁用（防止误触）。
      final clear = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '全部清空'),
      );
      expect(clear.onPressed, isNull);
      // 章节列表渲染
      expect(find.text('第一章 开始'), findsOneWidget);
      expect(find.text('未生成'), findsOneWidget);
    });

    testWidgets('凭据齐全后可点击生成', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      );
      await tester.runAsync(
        () => state.applySettings(
          const AppSettings(
            llmCredentialsByKind: {'deepSeek': {'apiKey': 'sk-1'}},
            ttsCredentialsByKind: {
              'xunfei': {
                'appId': 'app',
                'apiKey': 'key',
                'apiSecret': 'secret',
              },
            },
          ),
        ),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '离线缓存'),
      );
      expect(button.onPressed, isNotNull);
      // 全部清空仅在已有生成记录时可点：无记录时禁用。
      final clear = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '全部清空'),
      );
      expect(clear.onPressed, isNull);
    });

    testWidgets('无音频时不显示进度条并提示', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 尚未生成/播放任何章节：控制条给出引导文案，进度条不可用。
      expect(
        find.text('尚无音频，点击「离线缓存」或直接点击章节播放'),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('拖动进度条时仅本地预览，松手才 seek', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(MultiSentenceLLM()),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await pumpPlaying(tester, state);
      expect(find.byType(Slider), findsOneWidget);
      final seekCallsBefore = player.seekCalls;
      // 按住滑块向右拖：拖动过程中不触发 seek（高频 seek 会让
      // Windows 底层 Media Foundation 崩溃，必须松手后统一跳转）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(player.seekCalls, seekCallsBefore);
      // 松手：一次性 seek 到目标位置。
      await gesture.up();
      await tester.pumpAndSettle();
      expect(player.seekCalls, seekCallsBefore + 1);
      expect(player.lastSeekPosition, isNotNull);
      expect(player.lastSeekPosition!, greaterThan(Duration.zero));
    });

    testWidgets('拖动进度条时正文高亮与时间实时预览，松手后同步', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(MultiSentenceLLM()),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await pumpPlaying(tester, state);
      // 初始（未播放位置）：高亮第一句。
      expect(boldSentence(tester), '改写：第一章 开始\n');

      // 直接驱动滑块回调（模拟拖动到 90%：总时长 10s → 9s）。
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(0);
      slider.onChanged!(9000);
      await tester.pump();
      // 拖动中不 seek，但正文高亮与时间文本已按预览值更新。
      expect(player.seekCalls, 0);
      expect(boldSentence(tester), '内容');
      expect(find.text('00:09'), findsOneWidget);

      // 松手：seek 一次，正文与时间保持同步（seek 强制推送位置，
      // 不被 500ms 节流窗口吞掉，这正是拖动后内容不同步的修复点）。
      slider.onChangeEnd!(9000);
      await tester.pumpAndSettle();
      expect(player.seekCalls, 1);
      expect(player.lastSeekPosition, const Duration(seconds: 9));
      expect(boldSentence(tester), '内容');
      expect(find.text('00:09'), findsOneWidget);
    });

    testWidgets('播放位置更新时正文高亮自动前进', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(MultiSentenceLLM()),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await pumpPlaying(tester, state);

      // 30% 进度：仍在第一句（权重 9/11）。
      player.emitPosition(const Duration(seconds: 3));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pump();
      expect(boldSentence(tester), '改写：第一章 开始\n');
      // 90% 进度：越过第一句进入第二句。
      player.emitPosition(const Duration(seconds: 9));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pump();
      expect(boldSentence(tester), '内容');
    });

    testWidgets('无凭据时未生成章节播放按钮禁用', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 凭据不齐时未生成章节的播放按钮不可点（onPressed 为 null），
      // 避免点击后仅弹提示；已生成章节本地有音频则不受此限制。
      final playButton = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(ChapterTile),
          matching: find.widgetWithIcon(
            IconButton,
            Icons.play_circle_outline,
          ),
        ),
      );
      expect(playButton.onPressed, isNull);
      // 点击禁用按钮无任何效果：仅控制栏一处提示，无 SnackBar。
      await tester.tap(find.byTooltip('生成并播放'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('请先在设置中填写 API 凭据'), findsOneWidget);
    });

    testWidgets('生成记录出现后按钮文案不变，全部已生成时点击离线缓存给出提示', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(MultiSentenceLLM()),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 无生成记录：入口固定为「离线缓存」，按钮不随生成记录切换。
      expect(find.text('离线缓存'), findsOneWidget);

      // 生成第一章后：按钮文案保持不变，全部清空变为可点。
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();
      expect(find.text('离线缓存'), findsOneWidget);
      final clear = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '全部清空'),
      );
      expect(clear.onPressed, isNotNull);

      // 点击离线缓存：唯一章节已生成 → 提示无需继续。
      await tester.tap(find.text('离线缓存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('所有章节都已生成，无需继续'), findsOneWidget);
    });

    testWidgets('播放页设置按钮打开设置页', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 播放页 AppBar 的设置按钮进入设置页（书架页按钮在路由下层，
      // 默认 finder 跳过 offstage 组件，不会误命中）。
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('API 凭据'), findsOneWidget);
    });

    testWidgets('生成中显示进度与停止按钮，停止后恢复', (tester) async {
      // 门控 LLM：让改写请求挂起，制造「生成中」状态窗口。
      final gate = Completer<String>();
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(FakeLLM(gate: gate)),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('离线缓存'));
      await tester.pump();
      // 生成中：控制条切换为进行中文案与停止按钮。
      expect(find.text('正在生成中…'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);

      // 点击停止：任务取消后生成状态结束（纯内存异步链，pump 即可推进，
      // 不能用 runAsync 轮询——FakeAsync zone 的 microtask 需 pump 触发）。
      await tester.tap(find.text('停止'));
      for (var i = 0; i < 10 && state.isGenerating; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(state.isGenerating, isFalse);
      expect(find.text('正在生成中…'), findsNothing);
      // 章节回到未生成状态，播放按钮 tooltip 仍为「生成并播放」。
      expect(find.byTooltip('生成并播放'), findsOneWidget);

      // 释放挂起的改写请求，避免遗留未完成 future。
      gate.complete('改写：第一章 开始');
      await tester.pump();
    });

    testWidgets('全部清空需确认：无记录时禁用，生成后确认清空全部', (tester) async {
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(MultiSentenceLLM()),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 无生成记录：全部清空禁用（不可点击）。
      final clear = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '全部清空'),
      );
      expect(clear.onPressed, isNull);

      // 生成并播放第一章后：全部清空可点，弹出确认对话框。
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();
      final audioPath = state.book!.chapterAt(0).audioPath!;
      expect(await tester.runAsync(() => File(audioPath).exists()), isTrue);

      await tester.tap(find.text('全部清空'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('将删除本小说全部 1 章的已生成音频与改写稿'),
        findsOneWidget,
      );
      // 取消：对话框关闭且不执行清空。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(state.book!.chapterAt(0).status, ChapterStatus.generated);

      // 再次打开并确认：清空完成（真实文件删除），SnackBar 反馈。
      await tester.tap(find.text('全部清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      // clearAll 走真实文件删除（IO）：交替推进假时钟与真实事件循环，
      // 直到章节状态重置为未生成。
      for (var i = 0;
          i < 40 &&
              state.book!.chapterAt(0).status != ChapterStatus.notGenerated;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(state.book!.chapterAt(0).status, ChapterStatus.notGenerated);
      expect(await tester.runAsync(() => File(audioPath).exists()), isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('已清空全部已生成内容'), findsOneWidget);

      // 清空后全部清空按钮回到禁用。
      await tester.pumpAndSettle();
      final clearAfter = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '全部清空'),
      );
      expect(clearAfter.onPressed, isNull);
    });

    testWidgets('导出音频：无已生成音频时提示，生成后可导出', (tester) async {
      final exporter = FakeAudioExporter(
        const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
      );
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        audioExporter: exporter,
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpAndSettle();

      // 尚无已生成章节：点导出直接提示，不弹对话框。
      await tester.tap(find.byTooltip('导出音频'));
      await tester.pump();
      expect(find.text('还没有已生成的音频，请先「离线缓存」'), findsOneWidget);
      // 推掉该 SnackBar：展示期（4s）Timer 在入场动画完成后才启动，
      // pumpAndSettle 不推进挂起 Timer，残留的旧提示会让后续导出结果的
      // SnackBar 排队不显示，因此循环推进假时钟直到其完全移除。
      for (var i = 0;
          i < 20 && find.byType(SnackBar).evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);

      // 生成并播放第一章后：导出对话框显示章节数与跳过说明。
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('导出音频'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '将导出 1 个已生成章节（mp3）到所选目录，未生成的章节自动跳过。',
        ),
        findsOneWidget,
      );
      // 取消：不执行导出。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(exporter.exportedBook, isNull);

      // 确认导出：结果经 SnackBar 反馈。
      await tester.tap(find.byTooltip('导出音频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目录并导出'));
      // 导出为同步返回桩：pump 两帧让 SnackBar 显示（pumpAndSettle
      // 会推完 4 秒展示期导致断言落空）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('已导出 1 个章节'), findsOneWidget);
      expect(exporter.exportedBook, isNotNull);
    });

    testWidgets('导出音频失败时提示失败原因', (tester) async {
      final exporter = FakeAudioExporter(
        const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
        error: StateError('磁盘已满'),
      );
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        audioExporter: exporter,
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();

      // 确认导出：导出器抛错 → SnackBar 反馈失败原因（不崩溃）。
      await tester.tap(find.byTooltip('导出音频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目录并导出'));
      // 同步抛错链：pump 两帧让 SnackBar 显示（pumpAndSettle 会推完展示期）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('导出失败：'), findsOneWidget);
      expect(find.textContaining('磁盘已满'), findsOneWidget);
    });

    testWidgets('聚合并导出：无音频时提示，生成后确认并反馈结果', (tester) async {
      final exporter = FakeAudioExporter(
        const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
        mergeResult: const AudioMergeResult(
          filePaths: ['/tmp/merge/b.txt_聚合_001_第1-1章.mp3'],
          mergedCount: 1,
          targetDir: '/tmp/merge',
        ),
      );
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        audioExporter: exporter,
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpAndSettle();

      // 尚无已生成章节：点聚合并导出直接提示，不弹对话框。
      await tester.tap(find.byTooltip('聚合并导出'));
      await tester.pump();
      expect(find.text('还没有已生成的音频，请先「离线缓存」'), findsOneWidget);
      // 推掉该 SnackBar（展示期 Timer 不被 pumpAndSettle 推进，循环推时钟）。
      for (var i = 0;
          i < 20 && find.byType(SnackBar).evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);

      // 生成并播放第一章后：确认对话框显示聚合信息（含大小上限）。
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('聚合并导出'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '将把 1 个已生成章节按顺序合并为不超过 100 MB 的 mp3 大文件'
          '（超出上限自动分卷），导出到所选目录。',
        ),
        findsOneWidget,
      );
      // 取消：不执行聚合导出。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(exporter.mergedBook, isNull);

      // 确认导出：结果经 SnackBar 反馈。
      await tester.tap(find.byTooltip('聚合并导出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目录并导出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('已聚合 1 个章节'), findsOneWidget);
      expect(exporter.mergedBook, isNotNull);
    });

    testWidgets('聚合导出失败时提示失败原因', (tester) async {
      final exporter = FakeAudioExporter(
        const AudioExportResult(exported: 1, targetDir: '/tmp/export'),
        error: StateError('磁盘已满'),
      );
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        audioExporter: exporter,
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.playOrGenerate(0));
      await tester.pumpAndSettle();

      // 确认导出：导出器抛错 → SnackBar 反馈失败原因（不崩溃）。
      await tester.tap(find.byTooltip('聚合并导出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择目录并导出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('聚合导出失败：'), findsOneWidget);
      expect(find.textContaining('磁盘已满'), findsOneWidget);
    });

    testWidgets('章节生成失败提示并可点击重试成功', (tester) async {
      // failures=4：初始 1 次 + 默认 maxRetries=3 重试全部失败 → failed。
      final llm = FakeLLM(failures: 4);
      final state = await makeState(
        tester,
        file: const TxtFile(name: 'b.txt', content: '第一章 开始\n内容'),
        engine: TingEngine(
          llmRegistry: FakeLLMRegistry(llm),
          ttsRegistry: const FakeTTSRegistry(),
        ),
      );
      await tester.runAsync(() => state.applySettings(_fullSettings));
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      // 点击「生成并播放」：改写反复失败 → 播放失败 SnackBar + 章节 failed。
      await tester.tap(find.byTooltip('生成并播放'));
      // 失败链路无真实 IO（改写抛错即止），pump 推进 microtask 完成调度；
      // 循环内推进的假时钟（<4s）不会让 SnackBar 提前消失。
      for (var i = 0;
          i < 20 &&
              state.book!.chapterAt(0).status != ChapterStatus.failed;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.book!.chapterAt(0).status, ChapterStatus.failed);
      // 失败 SnackBar 由 playOrGenerate 返回 false 后弹出：循环退出时
      // microtask 已 flush 但 SnackBar 首帧未构建，补两帧让其入场。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('第 1 章生成失败，请查看章节状态后重试'), findsOneWidget);
      // 失败原因（LLMException 消息）非空，章节卡片显示「生成失败：原因」。
      expect(find.textContaining('生成失败：'), findsOneWidget);

      // 点击重试：重新生成成功（TTS 落盘走真实 IO，交替推进假时钟与
      // 真实事件循环，直到章节状态回到 generated）。
      await tester.tap(find.byTooltip('重试生成'));
      for (var i = 0;
          i < 40 &&
              state.book!.chapterAt(0).status != ChapterStatus.generated;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(state.book!.chapterAt(0).status, ChapterStatus.generated);
      // 章节卡片显示「播放」入口（控制栏播放按钮 tooltip 同为「播放」，
      // 因此限定在 ChapterTile 范围内断言）。
      expect(
        find.descendant(
          of: find.byType(ChapterTile),
          matching: find.byTooltip('播放'),
        ),
        findsOneWidget,
      );
    });
  });

  group('SettingsScreen 冒烟', () {
    testWidgets('设置页渲染全部配置项', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      expect(find.text('API 凭据'), findsOneWidget);
      expect(find.text('DeepSeek API Key'), findsOneWidget);
      expect(find.text('讯飞 APPID'), findsOneWidget);
      expect(find.text('讯飞 API Key'), findsOneWidget);
      expect(find.text('讯飞 API Secret'), findsOneWidget);
      expect(find.text('TTS 参数'), findsOneWidget);
      expect(find.text('发音人'), findsOneWidget);
      // 设置项较多，滚动到生成参数区再断言（TextField 内部也有 Scrollable，需指定 ListView）
      await tester.dragUntilVisible(
        find.text('生成参数'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('生成参数'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('聚合文件大小上限（MB）'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('聚合文件大小上限（MB）'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('切换腾讯云后渲染腾讯云凭据与音色分组', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      // TTS 提供商下拉选择「腾讯云」。
      await tester.tap(find.text('讯飞'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('腾讯云').last);
      await tester.pumpAndSettle();

      // 腾讯云凭据字段（讯飞字段不再显示）。
      expect(find.text('腾讯云 SecretId'), findsOneWidget);
      expect(find.text('腾讯云 SecretKey'), findsOneWidget);
      expect(find.text('讯飞 APPID'), findsNothing);
      // 腾讯云音色下拉：按音色标准分组的 48 个音色。
      expect(find.text('音色（VoiceType）'), findsOneWidget);
      // label 文本不可命中，点击下拉控件本体打开菜单。
      final voiceField = find.ancestor(
        of: find.text('音色（VoiceType）'),
        matching: find.byType(DropdownButtonFormField<String>),
      );
      await tester.ensureVisible(voiceField);
      await tester.pumpAndSettle();
      await tester.tap(voiceField);
      await tester.pumpAndSettle();
      // 菜单为懒加载列表，且打开时会自动滚动到当前选中音色附近，
      // 先回滚到顶部再按分组逐段断言（3 组头 + 48 音色）。
      await tester.dragUntilVisible(
        find.text('超自然大模型音色（17）'),
        find.byType(ListView).last,
        const Offset(0, 300),
      );
      expect(find.text('超自然大模型音色（17）'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('大模型音色（17）'),
        find.byType(ListView).last,
        const Offset(0, -150),
      );
      expect(find.text('大模型音色（17）'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('精品音色（14）'),
        find.byType(ListView).last,
        const Offset(0, -150),
      );
      expect(find.text('精品音色（14）'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('智瑜 · 情感女声'),
        find.byType(ListView).last,
        const Offset(0, -150),
      );
      // 页面下拉按钮与菜单中各有一处。
      expect(find.text('智瑜 · 情感女声'), findsWidgets);
      // 腾讯云接口不支持音高调节，音高滑杆隐藏。
      expect(find.text('音高'), findsNothing);
    });

    testWidgets('设置页编辑腾讯云凭据保存后生效', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      // TTS 提供商切换为腾讯云。
      await tester.tap(find.text('讯飞'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('腾讯云').last);
      await tester.pumpAndSettle();

      // SecretId 与 SecretKey 同为敏感凭据，均以密文框展示（掩码）。
      expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, '腾讯云 SecretId'))
            .obscureText,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, '腾讯云 SecretKey'))
            .obscureText,
        isTrue,
      );

      // 输入腾讯云凭据（回归：此前凭据输入框的控制器 key 缺少提供商
      // 维度，输入内容不写入控制器，保存时读到旧值导致配置不生效）。
      await tester.enterText(
        find.widgetWithText(TextField, '腾讯云 SecretId'),
        'AKIDtest123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '腾讯云 SecretKey'),
        'sk-secret',
      );
      await tester.tap(find.text('保存'));
      // applySettings 先更新内存再异步落盘（真实 IO），交替推进假时钟
      // 与真实事件循环，直到保存生效、设置页关闭。
      for (var i = 0;
          i < 40 &&
              state.settings
                      .ttsCredentialsFor(TTSKind.tencent)['secretId'] ==
                  null;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }

      // 保存后凭据已写入状态（按提供商维度存储，互不覆盖）。
      final creds = state.settings.ttsCredentialsFor(TTSKind.tencent);
      expect(creds['secretId'], 'AKIDtest123');
      expect(creds['secretKey'], 'sk-secret');
    });

    testWidgets('敏感字段掩码按住展示、松开恢复', (tester) async {
      final state = await makeState(tester);
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      // DeepSeek API Key 为敏感字段：默认掩码展示。
      final keyField = find.widgetWithText(TextField, 'DeepSeek API Key');
      expect(tester.widget<TextField>(keyField).obscureText, isTrue);

      // 按下「展示」按钮：明文显示（obscureText 关闭）。
      final revealIcon = find.descendant(
        of: keyField,
        matching: find.byIcon(Icons.visibility_outlined),
      );
      final gesture = await tester.startGesture(tester.getCenter(revealIcon));
      await tester.pump();
      expect(tester.widget<TextField>(keyField).obscureText, isFalse);

      // 松开：立即恢复掩码。
      await gesture.up();
      await tester.pump();
      expect(tester.widget<TextField>(keyField).obscureText, isTrue);
    });
  });

  group('ChapterTile 冒烟', () {
    Widget wrap(
      Chapter chapter, {
      bool isCurrent = false,
      bool isPlaying = false,
      VoidCallback? onPlay,
      VoidCallback? onPause,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ChapterTile(
            chapter: chapter,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            onPlay: onPlay,
            onPause: onPause,
          ),
        ),
      );
    }

    Chapter makeChapter(ChapterStatus status) => Chapter(
          id: 0,
          title: '第一章',
          rawText: '内容',
          status: status,
        );

    testWidgets('各状态渲染对应文案与控件', (tester) async {
      await tester.pumpWidget(wrap(makeChapter(ChapterStatus.notGenerated)));
      expect(find.text('未生成'), findsOneWidget);

      await tester.pumpWidget(wrap(makeChapter(ChapterStatus.rewriting)));
      expect(find.text('AI 修订润色中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(wrap(makeChapter(ChapterStatus.synthesizing)));
      expect(find.text('音频合成中…'), findsOneWidget);

      await tester.pumpWidget(wrap(makeChapter(ChapterStatus.failed)));
      expect(find.text('生成失败，点击重试'), findsOneWidget);
      expect(find.byTooltip('重试生成'), findsOneWidget);

      await tester.pumpWidget(wrap(makeChapter(ChapterStatus.cancelled)));
      expect(find.text('已取消，可重新生成'), findsOneWidget);
    });

    testWidgets('已生成章节显示播放按钮，播放中显示暂停图标并可暂停', (tester) async {
      final generated = makeChapter(ChapterStatus.generated)
          .copyWith(audioPath: '/tmp/0.mp3');
      await tester.pumpWidget(wrap(generated));
      expect(find.byTooltip('播放'), findsOneWidget);

      var pauseCalls = 0;
      await tester.pumpWidget(
        wrap(
          generated,
          isCurrent: true,
          isPlaying: true,
          onPause: () => pauseCalls++,
        ),
      );
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);

      // 点击暂停按钮触发 onPause。
      await tester.tap(find.byIcon(Icons.pause_circle_outline));
      expect(pauseCalls, 1);
    });
  });
}
