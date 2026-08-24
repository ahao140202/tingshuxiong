import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/domain/domain.dart';

/// 生成文件快照：每次章节生成成功时记录一条，便于后续回溯
/// （重新生成转移旧文件后，最近一条快照的路径会更新指向历史目录）。
class SnapshotRecord {
  const SnapshotRecord({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.status,
    required this.ttsConfigJson,
    required this.createdAt,
    this.audioPath,
    this.rewritePath,
  });

  final int id;
  final String bookId;
  final int chapterIndex;
  final String status;
  final String? audioPath;
  final String? rewritePath;
  final String ttsConfigJson;
  final DateTime createdAt;

  factory SnapshotRecord.fromMap(Map<String, Object?> map) {
    return SnapshotRecord(
      id: map['id'] as int,
      bookId: map['book_id'] as String,
      chapterIndex: map['chapter_index'] as int,
      status: map['status'] as String,
      audioPath: map['audio_path'] as String?,
      rewritePath: map['rewrite_path'] as String?,
      ttsConfigJson: map['tts_config_json'] as String,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }
}

/// 书 / 章节状态与生成快照的 SQLite 持久化。
///
/// 表结构：
/// - `books`：书元数据与听书进度（每本书一行）；
/// - `chapters`：章节完整状态（正文、改写稿、文件路径、错误信息）；
/// - `snapshots`：生成文件状态快照（每次成功生成一条，时间倒序可回溯）。
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE books(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            last_chapter_index INTEGER NOT NULL DEFAULT 0,
            last_position_ms INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL
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
            tts_config_json TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_snapshots_book ON snapshots(book_id, chapter_index)',
        );
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
  Future<void> saveBook(Book book) async {
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      await txn.insert(
        'books',
        {
          'id': book.id,
          'title': book.title,
          'last_chapter_index': book.lastChapterIndex,
          'last_position_ms': book.lastPosition.inMilliseconds,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
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

  /// 加载最近更新过的书（启动恢复用），无记录时返回 null。
  Future<Book?> loadLatestBook() async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('books', orderBy: 'updated_at DESC', limit: 1);
    if (rows.isEmpty) return null;
    return _bookFromRows(db, rows.first);
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

  /// 记录一次成功生成的文件快照。
  Future<void> insertSnapshot({
    required String bookId,
    required int chapterIndex,
    required String status,
    String? audioPath,
    String? rewritePath,
    required String ttsConfigJson,
  }) async {
    final db = _db;
    if (db == null) return;
    await db.insert('snapshots', {
      'book_id': bookId,
      'chapter_index': chapterIndex,
      'status': status,
      'audio_path': audioPath,
      'rewrite_path': rewritePath,
      'tts_config_json': ttsConfigJson,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 章节文件转移到历史目录后，更新该章最近一条快照的文件路径。
  Future<void> updateSnapshotPaths(
    String bookId,
    int chapterIndex, {
    String? audioPath,
    String? rewritePath,
  }) async {
    final db = _db;
    if (db == null) return;
    final rows = await db.query(
      'snapshots',
      where: 'book_id = ? AND chapter_index = ?',
      whereArgs: [bookId, chapterIndex],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    await db.update(
      'snapshots',
      {'audio_path': audioPath, 'rewrite_path': rewritePath},
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
  }

  /// 查询某书（或某章）的生成快照，按时间倒序。
  Future<List<SnapshotRecord>> loadSnapshots(
    String bookId, {
    int? chapterIndex,
  }) async {
    final db = _db;
    if (db == null) return const [];
    final rows = chapterIndex == null
        ? await db.query(
            'snapshots',
            where: 'book_id = ?',
            whereArgs: [bookId],
            orderBy: 'id DESC',
          )
        : await db.query(
            'snapshots',
            where: 'book_id = ? AND chapter_index = ?',
            whereArgs: [bookId, chapterIndex],
            orderBy: 'id DESC',
          );
    return [for (final r in rows) SnapshotRecord.fromMap(r)];
  }

  /// 关闭数据库（测试清理用）。
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
