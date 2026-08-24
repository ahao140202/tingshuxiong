import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/domain/domain.dart';

/// 音频导出结果。
class AudioExportResult {
  const AudioExportResult({required this.exported, required this.targetDir});

  /// 成功导出的章节数。
  final int exported;

  /// 导出目标目录。
  final String targetDir;
}

/// 音频导出：把已生成章节的 mp3 复制到目标目录，文件名 `001-章节标题.mp3`。
///
/// 桌面端（Windows/macOS/Linux）弹出系统目录选择框；
/// 移动端不支持目录选择（file_selector 返回 null），回退导出到
/// 应用文档目录 `<文档>/听书熊导出/<书名>/`，便于后续通过文件分享转发。
class AudioExporter {
  AudioExporter({
    Future<Directory> Function()? fallbackDir,
    Future<String?> Function()? pickDirectory,
  })  : _fallbackDir = fallbackDir ?? _defaultFallback,
        _pickDirectory = pickDirectory ?? _defaultPickDirectory;

  final Future<Directory> Function() _fallbackDir;
  final Future<String?> Function() _pickDirectory;

  /// 桌面端弹系统目录选择框；移动端返回 null（走回退目录）。
  static Future<String?> _defaultPickDirectory() async {
    try {
      return await getDirectoryPath();
    } on UnimplementedError {
      return null;
    }
  }

  static Future<Directory> _defaultFallback() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, '听书熊导出'));
  }

  /// 导出全部已生成章节；未生成音频的章节自动跳过。
  Future<AudioExportResult> exportBook(Book book) async {
    final chosen = await _pickDirectory();
    final target = Directory(
      chosen != null && chosen.isNotEmpty
          ? chosen
          : p.join((await _fallbackDir()).path, _sanitize(book.title)),
    );
    await target.create(recursive: true);

    var exported = 0;
    for (var i = 0; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      if (!chapter.hasAudio) continue;
      final name =
          '${(i + 1).toString().padLeft(3, '0')}-${_sanitize(chapter.title)}.mp3';
      await File(chapter.audioPath!).copy(p.join(target.path, name));
      exported++;
    }
    return AudioExportResult(exported: exported, targetDir: target.path);
  }

  /// 替换文件名非法字符（Windows 路径字符全平台统一替换）。
  static String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
