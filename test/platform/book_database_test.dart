import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/platform/platform.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('book_database_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  BookDatabase makeDb() {
    return BookDatabase(
      factory: databaseFactoryFfi,
      pathProvider: () async =>
          '${tempDir.path}${Platform.pathSeparator}books.db',
    );
  }

  Book makeBook({int chapters = 2}) {
    return Book(
      id: 'novel.txt',
      title: 'novel.txt',
      chapters: [
        for (var i = 0; i < chapters; i++)
          Chapter(id: i, title: '第${i + 1}章', rawText: '正文$i'),
      ],
    );
  }

  group('BookDatabase', () {
    test('saveBook 后 loadLatestBook 还原书与章节状态', () async {
      final db = makeDb();
      addTearDown(db.close);
      await db.init();
      // 恢复校验要求文件真实存在，否则 generated 会被重置。
      final audioFile = File('${tempDir.path}${Platform.pathSeparator}0.mp3');
      final rewriteFile = File('${tempDir.path}${Platform.pathSeparator}0.txt');
      await audioFile.writeAsBytes([1, 2, 3]);
      await rewriteFile.writeAsString('改写0');
      final book = makeBook().replaceChapter(
        0,
        makeBook().chapterAt(0).copyWith(
              status: ChapterStatus.generated,
              rewrittenText: '改写0',
              rewritePath: rewriteFile.path,
              audioPath: audioFile.path,
            ),
      );
      await db.saveBook(book);

      final restored = await db.loadLatestBook();
      expect(restored, isNotNull);
      expect(restored!.id, 'novel.txt');
      expect(restored.title, 'novel.txt');
      expect(restored.chapterCount, 2);
      final c0 = restored.chapterAt(0);
      expect(c0.status, ChapterStatus.generated);
      expect(c0.rewrittenText, '改写0');
      expect(c0.rewritePath, rewriteFile.path);
      expect(c0.audioPath, audioFile.path);
      expect(restored.chapterAt(1).status, ChapterStatus.notGenerated);
    });

    test('多本书时 loadLatestBook 返回最近更新的', () async {
      final db = makeDb();
      await db.init();
      await db.saveBook(makeBook());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.saveBook(
        Book(
          id: 'b2.txt',
          title: 'b2.txt',
          chapters: const [Chapter(id: 0, title: 'c', rawText: 'x')],
        ),
      );

      final restored = await db.loadLatestBook();
      expect(restored!.id, 'b2.txt');
      await db.close();
    });

    test('generated 章节音频文件缺失时恢复为 notGenerated', () async {
      final db = makeDb();
      await db.init();
      final book = makeBook().replaceChapter(
        0,
        makeBook().chapterAt(0).copyWith(
              status: ChapterStatus.generated,
              rewrittenText: '改写',
              audioPath:
                  '${tempDir.path}${Platform.pathSeparator}missing.mp3',
            ),
      );
      await db.saveBook(book);

      final restored = await db.loadLatestBook();
      expect(restored!.chapterAt(0).status, ChapterStatus.notGenerated);
      expect(restored.chapterAt(0).audioPath, isNull);
      // 改写稿文本保留（仅音频失效）。
      expect(restored.chapterAt(0).rewrittenText, '改写');
      await db.close();
    });

    test('updateProgress 独立更新进度字段', () async {
      final db = makeDb();
      await db.init();
      await db.saveBook(makeBook());
      await db.updateProgress(
        'novel.txt',
        1,
        const Duration(seconds: 30),
      );

      final restored = await db.loadLatestBook();
      expect(restored!.lastChapterIndex, 1);
      expect(restored.lastPosition, const Duration(seconds: 30));
      await db.close();
    });

    test('快照：插入/查询/转移后更新最近一条路径', () async {
      final db = makeDb();
      await db.init();
      await db.insertSnapshot(
        bookId: 'novel.txt',
        chapterIndex: 0,
        status: 'generated',
        audioPath: '/a/0.mp3',
        rewritePath: '/r/0.txt',
        ttsConfigJson: '{}',
      );
      await db.insertSnapshot(
        bookId: 'novel.txt',
        chapterIndex: 0,
        status: 'generated',
        audioPath: '/a/0-new.mp3',
        rewritePath: '/r/0-new.txt',
        ttsConfigJson: '{"voice":"xiaoyan"}',
      );

      var snapshots = await db.loadSnapshots('novel.txt');
      expect(snapshots, hasLength(2));
      // 时间倒序：最近一条在前。
      expect(snapshots.first.audioPath, '/a/0-new.mp3');
      expect(snapshots.first.ttsConfigJson, contains('xiaoyan'));

      // 转移到历史目录后：仅最近一条路径更新，旧快照保留原路径。
      await db.updateSnapshotPaths(
        'novel.txt',
        0,
        audioPath: '/h/0-1.mp3',
        rewritePath: '/h/0-1.txt',
      );
      snapshots = await db.loadSnapshots('novel.txt', chapterIndex: 0);
      expect(snapshots.first.audioPath, '/h/0-1.mp3');
      expect(snapshots.last.audioPath, '/a/0.mp3');
      await db.close();
    });

    test('快照按章节过滤', () async {
      final db = makeDb();
      await db.init();
      await db.insertSnapshot(
        bookId: 'b',
        chapterIndex: 0,
        status: 'generated',
        ttsConfigJson: '{}',
      );
      await db.insertSnapshot(
        bookId: 'b',
        chapterIndex: 1,
        status: 'generated',
        ttsConfigJson: '{}',
      );

      final one = await db.loadSnapshots('b', chapterIndex: 1);
      expect(one, hasLength(1));
      expect(one.single.chapterIndex, 1);
      await db.close();
    });

    test('loadBook 按 id 查询，未记录时返回 null', () async {
      final db = makeDb();
      await db.init();
      expect(await db.loadBook('nope.txt'), isNull);
      await db.saveBook(makeBook());
      expect((await db.loadBook('novel.txt'))!.chapterCount, 2);
      await db.close();
    });
  });
}
