import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/facade/facade.dart';
import 'package:tingshuxiong/platform/platform.dart';
import 'package:tingshuxiong/ui/app.dart';
import 'package:tingshuxiong/ui/state/app_state.dart';
import 'package:tingshuxiong/ui/widgets/chapter_tile.dart';

import '../helpers/fakes.dart';

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

  Future<AppState> makeState(WidgetTester tester, {TxtFile? file}) async {
    final state = AppState(
      engine: TingEngine(
        llmRegistry: const FakeLLMRegistry(),
        ttsRegistry: const FakeTTSRegistry(),
      ),
      settingsStore: SettingsStore(
        fileProvider: () async =>
            File('${tempDir.path}${Platform.pathSeparator}settings.json'),
      ),
      audioStore: AudioStore(rootProvider: () async => tempDir),
      filePicker: FakeTxtPicker(file),
      player: player,
    );
    // init 涉及真实文件 IO，需在 runAsync 中执行
    await tester.runAsync(() => state.init());
    return state;
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
      expect(find.text('全部生成'), findsOneWidget);
      expect(find.text('第一章 相遇'), findsOneWidget);
      expect(find.text('第二章 离别'), findsOneWidget);
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
        find.widgetWithText(FilledButton, '全部生成'),
      );
      expect(button.onPressed, isNull);
      // 重新生成按钮同样禁用
      final regen = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '重新生成'),
      );
      expect(regen.onPressed, isNull);
      // 继续生成按钮同样禁用
      final cont = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '继续生成'),
      );
      expect(cont.onPressed, isNull);
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
            llmCredentials: {'apiKey': 'sk-1'},
            ttsCredentials: {
              'appId': 'app',
              'apiKey': 'key',
              'apiSecret': 'secret',
            },
          ),
        ),
      );
      await tester.pumpWidget(TingApp(appState: state));
      await tester.tap(find.text('导入小说'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '全部生成'),
      );
      expect(button.onPressed, isNotNull);
      // 重新生成按钮与「全部生成」并列可用
      final regen = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '重新生成'),
      );
      expect(regen.onPressed, isNotNull);
      // 继续生成按钮与「全部生成」并列可用
      final cont = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '继续生成'),
      );
      expect(cont.onPressed, isNotNull);
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
      expect(find.text('保存'), findsOneWidget);
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
      expect(find.text('AI 口语化改写中…'), findsOneWidget);
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
