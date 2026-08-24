import 'chapter_status.dart';

/// 小说章节（不可变）。
///
/// 状态更新通过 [copyWith] 产生新实例，保证 UI 层可安全观察。
class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    required this.rawText,
    this.rewrittenText,
    this.rewritePath,
    this.audioPath,
    this.errorMessage,
    this.status = ChapterStatus.notGenerated,
  });

  /// 章节序号（0-based，展示时 +1）。
  final int id;

  /// 章节标题（原文标题行，未匹配到时为生成标题）。
  final String title;

  /// 原文内容（未改写）。
  final String rawText;

  /// 口语化改写稿（DeepSeek 输出，未生成时为 null）。
  final String? rewrittenText;

  /// 改写稿落盘路径（中间文件，未生成时为 null）。
  final String? rewritePath;

  /// 本地音频文件绝对路径（TTS 合成后写入，未生成时为 null）。
  final String? audioPath;

  /// 最近一次失败原因（仅失败/重试中的章节可能有值，成功时清空）。
  final String? errorMessage;

  /// 当前生成状态。
  final ChapterStatus status;

  /// 是否已具备可播放音频。
  bool get hasAudio => status == ChapterStatus.generated && audioPath != null;

  /// 返回状态更新后的新章节实例。
  ///
  /// [rewrittenText] / [rewritePath] / [audioPath] / [errorMessage] 传入 `null` 可显式清空（默认保留原值）。
  Chapter copyWith({
    String? title,
    String? rawText,
    Object? rewrittenText = _unset,
    Object? rewritePath = _unset,
    Object? audioPath = _unset,
    Object? errorMessage = _unset,
    ChapterStatus? status,
  }) {
    return Chapter(
      id: id,
      title: title ?? this.title,
      rawText: rawText ?? this.rawText,
      rewrittenText: identical(rewrittenText, _unset)
          ? this.rewrittenText
          : rewrittenText as String?,
      rewritePath: identical(rewritePath, _unset)
          ? this.rewritePath
          : rewritePath as String?,
      audioPath: identical(audioPath, _unset)
          ? this.audioPath
          : audioPath as String?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      status: status ?? this.status,
    );
  }

  /// 哨兵值：区分「未传参（保留原值）」与「显式传 null（清空）」。
  static const Object _unset = Object();
}