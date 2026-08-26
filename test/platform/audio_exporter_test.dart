import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/platform/audio_exporter.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tsx_exporter_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Book makeBook() {
    final srcDir = Directory('${tempDir.path}/src')..createSync();
    final src1 = File('${srcDir.path}/src0.mp3')..writeAsBytesSync([1, 2, 3]);
    final src2 = File('${srcDir.path}/src2.mp3')..writeAsBytesSync([4, 5]);
    return Book(
      id: 'book-1',
      title: '测试书',
      chapters: [
        const Chapter(id: 0, title: '第1章 开始', rawText: 'a'),
        Chapter(
          id: 1,
          title: '第2章 失败章',
          rawText: 'b',
          status: ChapterStatus.failed,
        ),
        Chapter(
          id: 2,
          title: '第3章: 特殊/字符',
          rawText: 'c',
          audioPath: src2.path,
          status: ChapterStatus.generated,
        ),
        Chapter(
          id: 3,
          title: '第4章 可播放',
          rawText: 'd',
          audioPath: src1.path,
          status: ChapterStatus.generated,
        ),
      ],
    );
  }

  test('只导出已生成章节，文件名带序号并清理非法字符', () async {
    final exporter = AudioExporter(
      // 模拟移动端：目录选择不可用，走回退目录。
      pickDirectory: () async => null,
      fallbackDir: () async => tempDir,
    );

    final result = await exporter.exportBook(makeBook());

    expect(result.exported, 2);
    final outDir = Directory('${tempDir.path}/测试书');
    final files = outDir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(files, hasLength(2));
    expect(
      files.any((f) => f.endsWith('003-第3章_ 特殊_字符.mp3')),
      isTrue,
      reason: '非法字符应替换为下划线',
    );
    expect(files.any((f) => f.endsWith('004-第4章 可播放.mp3')), isTrue);
  });

  test('用户选择目录时导出到所选目录', () async {
    final chosen = Directory('${tempDir.path}/chosen')..createSync();
    final exporter = AudioExporter(
      pickDirectory: () async => chosen.path,
      fallbackDir: () async => tempDir,
    );

    final result = await exporter.exportBook(makeBook());

    expect(result.exported, 2);
    expect(result.targetDir, chosen.path);
    final files = chosen
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(files, hasLength(2));
  });

  test('无已生成音频时导出 0 个', () async {
    final exporter = AudioExporter(
      pickDirectory: () async => null,
      fallbackDir: () async => tempDir,
    );
    final book = Book(
      id: 'empty',
      title: '空书',
      chapters: [const Chapter(id: 0, title: '第1章', rawText: 'x')],
    );

    final result = await exporter.exportBook(book);

    expect(result.exported, 0);
  });

  /// 带 ID3v2 标签的音频字节：10 字节头（'ID3' + v2.3 + 无扩展头 flag）+
  /// [tagSize] 字节标签体 + [frames] 帧数据。
  List<int> withId3Tag(List<int> frames, {int tagSize = 5}) {
    return [
      0x49, 0x44, 0x33, 3, 0, 0, // 'ID3' + v2.3 + flags（无扩展头）
      0, 0, 0, tagSize, // synchsafe 大小
      ...List<int>.filled(tagSize, 0),
      ...frames,
    ];
  }

  test('mergeBook 按序拼接章节并跳过每段 ID3v2 标签', () async {
    final srcDir = Directory('${tempDir.path}/src')..createSync();
    final src0 = File('${srcDir.path}/src0.mp3')
      ..writeAsBytesSync(withId3Tag([1, 2, 3]));
    final src1 = File('${srcDir.path}/src1.mp3')..writeAsBytesSync([4, 5]);
    final src2 = File('${srcDir.path}/src2.mp3')
      ..writeAsBytesSync(withId3Tag([6, 7, 8, 9], tagSize: 3));
    final book = Book(
      id: 'book-1',
      title: '测试书',
      chapters: [
        for (var i = 0; i < 3; i++)
          Chapter(
            id: i,
            title: '第${i + 1}章',
            rawText: '$i',
            audioPath: [src0, src1, src2][i].path,
            status: ChapterStatus.generated,
          ),
      ],
    );
    final exporter = AudioExporter(
      pickDirectory: () async => null,
      fallbackDir: () async => tempDir,
    );

    final result = await exporter.mergeBook(book);

    // 3 章合并为 1 个文件，内容为去标签后的顺序拼接。
    expect(result.mergedCount, 3);
    expect(result.filePaths, hasLength(1));
    final outFile = File(result.filePaths.single);
    expect(outFile.path.endsWith('测试书_聚合_001_第1-3章.mp3'), isTrue);
    expect(outFile.readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('mergeBook 超过大小上限时自动分卷，文件名体现章节范围', () async {
    final srcDir = Directory('${tempDir.path}/src')..createSync();
    // 第 1-3 章共 900KB → 卷 1；第 4 章放不进卷 1（超 1MB）单独成卷；
    // 第 5-6 章共 900KB → 卷 3。共 3 个文件。
    final sizes = [
      300 * 1024, 300 * 1024, 300 * 1024, // 第1-3章 → 卷1（900KB）
      300 * 1024, // 第4章 → 卷2（单独）
      800 * 1024, 100 * 1024, // 第5-6章 → 卷3（900KB）
    ];
    final paths = <String>[];
    for (var i = 0; i < sizes.length; i++) {
      final f = File('${srcDir.path}/src$i.mp3')
        ..writeAsBytesSync(List<int>.filled(sizes[i], i + 1));
      paths.add(f.path);
    }
    final book = Book(
      id: 'book-1',
      title: '测试书',
      chapters: [
        for (var i = 0; i < paths.length; i++)
          Chapter(
            id: i,
            title: '第${i + 1}章',
            rawText: '$i',
            audioPath: paths[i],
            status: ChapterStatus.generated,
          ),
      ],
    );
    final exporter = AudioExporter(
      pickDirectory: () async => null,
      fallbackDir: () async => tempDir,
    );

    final result = await exporter.mergeBook(book, maxSizeMb: 1);

    expect(result.mergedCount, 6);
    expect(result.filePaths, hasLength(3));
    // 文件名体现章节范围：多章区间用 `第X-Y章`，单章省略区间。
    expect(result.filePaths[0].endsWith('测试书_聚合_001_第1-3章.mp3'), isTrue);
    expect(result.filePaths[1].endsWith('测试书_聚合_002_第4章.mp3'), isTrue);
    expect(result.filePaths[2].endsWith('测试书_聚合_003_第5-6章.mp3'), isTrue);
    // 各卷大小与预期一致（单章卷不拆分，其余卷不超过上限）。
    final actual = [for (final f in result.filePaths) File(f).lengthSync()];
    expect(actual, [900 * 1024, 300 * 1024, 900 * 1024]);
  });

  test('mergeBook 无已生成音频时抛错', () async {
    final exporter = AudioExporter(
      pickDirectory: () async => null,
      fallbackDir: () async => tempDir,
    );
    final book = Book(
      id: 'empty',
      title: '空书',
      chapters: [const Chapter(id: 0, title: '第1章', rawText: 'x')],
    );

    await expectLater(exporter.mergeBook(book), throwsStateError);
  });
}
