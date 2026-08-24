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
}
