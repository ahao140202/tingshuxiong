import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/domain/domain.dart';

/// 书 / 章节状态的 SQLite 持久化。
///
/// 表结构：
/// - `books`：书元数据与听书进度（每本书一行）；
/// - `chapters`：章节完整状态（正文、改写稿、文件路径、错误信息）。
///
/// 桌面端（Windows/Linux）使用 FFI 实现；移动端使用 sqflite 原生实现；
/// 测试可注入 [factory] 使用内存库。
class BookDatabase {
  BookDatabase({Future<String> Function()? pathProvider, this._factory})
      : _pathProvider = pathProvider ?? _defaultPath;

  final Future<String> Function() _pathProvider;
  final DatabaseFactory? _factory;
  Database? _db;

  static Future<String> _defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'books.db');
  }

  /// 打开数据库并建表（幂等）。
  Future<void> init() async {
    if (_db != null) return;
    final path = await _pathProvider();
    final factory = _factory ?? _desktopFactory();
    final options = OpenDatabaseOptions(
      version: 3,
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // 老库补 created_at（导入时间）：先用 0 占位，再以现有
          // updated_at 回填（历史书的导入时间无从考证，取近似值）。
          await db.execute(
            'ALTER TABLE books ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'UPDATE books SET created_at = updated_at WHERE created_at = 0',
          );
        }
        if (oldVersion < 3) {
          // v3 废弃历史生成功能：删除 snapshots 快照表（不再记录生成历史）。
          await db.execute('DROP TABLE IF EXISTS snapshots');
        }
      },
    );
    _db = factory != null
        ? await factory.openDatabase(path, options: options)
        : await openDatabase(path, options: options);
  }

  /// 桌面端（Windows/Linux）走 FFI；移动端返回 null（使用 sqflite 默认工厂）。
  static DatabaseFactory? _desktopFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return null;
  }

  /// 保存整本书（书元数据 + 全部章节），事务内 upsert。
  ///
  /// [created_at]（导入时间）只在首次插入时写入：重复保存（生成/进度
  /// 更新）不刷新它，保证书架排序稳定。
  Future<void> saveBook(Book book) async {
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'books',
        columns: ['created_at'],
        where: 'id = ?',
        whereArgs: [book.id],
      );
      final createdAt = rows.isEmpty
          ? DateTime.now().millisecondsSinceEpoch
          : rows.first['created_at'] as int;
      await txn.insert(
        'books',
        {
          'id': book.id,
          'title': book.title,
          'last_chapter_index': book.lastChapterIndex,
          'last_position_ms': book.lastPosition.inMilliseconds,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'created_at': createdAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (var i = 0; i < book.chapterCount; i++) {
        final chapter = book.chapterAt(i);
        await txn.insert(
          'chapters',
          {
            'book_id': book.id,
            'chapter_index': i,
            'title': chapter.title,
            'raw_text': chapter.rawText,
            'rewritten_text': chapter.rewrittenText,
            'rewrite_path': chapter.rewritePath,
            'audio_path': chapter.audioPath,
            'error_message': chapter.errorMessage,
            'status': chapter.status.name,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 更新听书进度（轻量独立更新，不触发整书保存）。
  Future<void> updateProgress(
    String bookId,
    int chapterIndex,
    Duration position,
  ) async {
    final db = _db;
    if (db == null) return;
    await db.update(
      'books',
      {
        'last_chapter_index': chapterIndex,
        'last_position_ms': position.inMilliseconds,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// 删除书及其全部章节记录（「删除小说」用），事务内执行。
  Future<void> deleteBook(String id) async {
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      await txn.delete('chapters', where: 'book_id = ?', whereArgs: [id]);
      await txn.delete('books', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 加载最近更新过的书（启动恢复用），无记录时返回 null。
  Future<Book?> loadLatestBook() async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('books', orderBy: 'updated_at DESC', limit: 1);
    if (rows.isEmpty) return null;
    return _bookFromRows(db, rows.first);
  }

  /// 加载全部书，按导入时间倒序（书架展示用：最新导入的排最前）。
  Future<List<Book>> loadBooks() async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'books',
      orderBy: 'created_at DESC, updated_at DESC',
    );
    return [for (final row in rows) await _bookFromRows(db, row)];
  }

  /// 按 id 加载书（书架历史回溯用），无记录时返回 null。
  Future<Book?> loadBook(String id) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _bookFromRows(db, rows.first);
  }

  Future<Book> _bookFromRows(Database db, Map<String, Object?> row) async {
    final bookId = row['id'] as String;
    final chapterRows = await db.query(
      'chapters',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'chapter_index ASC',
    );
    final chapters = <Chapter>[];
    for (final r in chapterRows) {
      var status =
          ChapterStatus.values.asNameMap()[r['status']] ?? ChapterStatus.notGenerated;
      var audioPath = r['audio_path'] as String?;
      var rewritePath = r['rewrite_path'] as String?;
      // 音频文件已被删除/根目录变更：重置为未生成，避免播放失败。
      if (status == ChapterStatus.generated &&
          (audioPath == null || !await File(audioPath).exists())) {
        status = ChapterStatus.notGenerated;
        audioPath = null;
      }
      if (rewritePath != null && !await File(rewritePath).exists()) {
        rewritePath = null;
      }
      chapters.add(Chapter(
        id: r['chapter_index'] as int,
        title: r['title'] as String,
        rawText: r['raw_text'] as String,
        rewrittenText: r['rewritten_text'] as String?,
        rewritePath: rewritePath,
        audioPath: audioPath,
        errorMessage: r['error_message'] as String?,
        status: status,
      ));
    }
    return Book(
      id: bookId,
      title: row['title'] as String,
      chapters: chapters,
      lastChapterIndex: row['last_chapter_index'] as int? ?? 0,
      lastPosition:
          Duration(milliseconds: row['last_position_ms'] as int? ?? 0),
    );
  }

  /// 关闭数据库（测试清理用）。
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
