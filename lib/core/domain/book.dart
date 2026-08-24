import 'chapter.dart';

/// 一本书（不可变容器）。
///
/// 章节状态更新通过 [replaceChapter] 产生新实例；
/// 阅读/听书进度更新通过 [withPosition] 产生新实例。
class Book {
  const Book({
    required this.id,
    required this.title,
    required this.chapters,
    this.lastChapterIndex = 0,
    this.lastPosition = Duration.zero,
  });

  /// 唯一标识（导入时生成）。
  final String id;

  /// 书名（默认取文件名）。
  final String title;

  /// 章节列表（有序）。
  final List<Chapter> chapters;

  /// 上次播放/阅读章节（0-based）。
  final int lastChapterIndex;

  /// 章节内播放进度。
  final Duration lastPosition;

  int get chapterCount => chapters.length;

  Chapter chapterAt(int index) => chapters[index];

  /// 替换指定章节，返回新 Book 实例。
  Book replaceChapter(int index, Chapter chapter) {
    final list = List<Chapter>.of(chapters);
    list[index] = chapter;
    return Book(
      id: id,
      title: title,
      chapters: list,
      lastChapterIndex: lastChapterIndex,
      lastPosition: lastPosition,
    );
  }

  /// 更新阅读/听书进度，返回新 Book 实例。
  Book withPosition(int chapterIndex, Duration position) {
    return Book(
      id: id,
      title: title,
      chapters: chapters,
      lastChapterIndex: chapterIndex,
      lastPosition: position,
    );
  }
}