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

    test('v3 升级时删除废弃的 snapshots 表', () async {
      // 手工构造 v2 库：books/chapters/snapshots 三张表（旧版 schema）。
      final path = '${tempDir.path}${Platform.pathSeparator}old.db';
      final oldDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE books(
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                last_chapter_index INTEGER NOT NULL DEFAULT 0,
                last_position_ms INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE chapters(
                book_id TEXT NOT NULL,
                chapter_index INTEGER NOT NULL,
                title TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                rewritten_text TEXT,
                rewrite_path TEXT,
                audio_path TEXT,
                error_message TEXT,
                status TEXT NOT NULL,
                PRIMARY KEY (book_id, chapter_index)
              )
            ''');
            await db.execute('''
              CREATE TABLE snapshots(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id TEXT NOT NULL,
                chapter_index INTEGER NOT NULL,
                status TEXT NOT NULL,
                audio_path TEXT,
                rewrite_path TEXT,
                tts_config_json TEXT,
                created_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      await oldDb.execute(
        "INSERT INTO snapshots(book_id, chapter_index, status, created_at) "
        "VALUES ('novel.txt', 0, 'generated', 1)",
      );
      await oldDb.close();

      // 用 BookDatabase（version 3）打开：onUpgrade 触发 DROP snapshots。
      final db = BookDatabase(
        factory: databaseFactoryFfi,
        pathProvider: () async => path,
      );
      await db.init();
      // 旧快照数据随表一起删除。
      final check = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 3),
      );
      final tables = await check.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'snapshots'",
      );
      expect(tables, isEmpty);
      await check.close();
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

    test('deleteBook 删除书及其全部章节记录', () async {
      final db = makeDb();
      await db.init();
      await db.saveBook(makeBook());
      expect(await db.loadBook('novel.txt'), isNotNull);

      await db.deleteBook('novel.txt');

      expect(await db.loadBook('novel.txt'), isNull);
      // 章节记录一并删除：重新保存同 id 书时不应残留旧章节。
      await db.saveBook(makeBook());
      expect((await db.loadBook('novel.txt'))!.chapterCount, 2);
      await db.close();
    });
  });
}
