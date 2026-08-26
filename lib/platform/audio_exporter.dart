import 'dart:io';
import 'dart:typed_data';

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

/// 聚合并导出结果。
class AudioMergeResult {
  const AudioMergeResult({
    required this.filePaths,
    required this.mergedCount,
    required this.targetDir,
  });

  /// 生成的聚合文件列表（按章节顺序，每个不超过大小上限）。
  final List<String> filePaths;

  /// 参与聚合的章节数。
  final int mergedCount;

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
    final target = await _resolveTarget(book);
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

  /// 聚合并导出：把全部已生成章节的 mp3 按章节顺序打包为不超过
  /// [maxSizeMb]（默认 100MB）的聚合大文件，文件名带章节范围
  /// `书名_聚合_001_第1-3章.mp3`（单章省略区间，如 `第5章`），
  /// 保存到所选目录（桌面端）或回退文档目录。
  ///
  /// 打包策略：按顺序累积章节字节，当前文件超过大小上限时开新文件，
  /// 使大文件数量最少；单个章节超过上限时单独成文件（不拆分）。
  /// mp3 为帧序列格式，按序二进制拼接即可被播放器顺序播放，
  /// 每段开头的 ID3v2 标签会被跳过（避免标签干扰帧解析）。
  ///
  /// 没有已生成音频时抛 [StateError]（调用方负责提示）。
  Future<AudioMergeResult> mergeBook(Book book, {int maxSizeMb = 100}) async {
    final target = await _resolveTarget(book);
    await target.create(recursive: true);

    final limitBytes = maxSizeMb * 1024 * 1024;
    final filePaths = <String>[];
    var merged = 0;
    var fileIndex = 1;
    IOSink? sink;
    String? currentPath;
    var currentBytes = 0;
    // 当前聚合文件覆盖的章节范围（1-based，文件名展示用）。
    var fileStartChapter = 0;
    var fileEndChapter = 0;

    /// 打开新聚合文件：先以序号写入临时名，收尾时再重命名为
    /// 带章节范围的名字（避免打开时还不知道结束章节）。
    void openNextFile(int chapterIndex) {
      fileStartChapter = chapterIndex + 1;
      fileEndChapter = fileStartChapter;
      final path = p.join(
        target.path,
        '${_sanitize(book.title)}_聚合_'
        '${fileIndex.toString().padLeft(3, '0')}.mp3',
      );
      fileIndex++;
      currentPath = path;
      sink = File(path).openWrite();
      currentBytes = 0;
    }

    /// 收尾当前文件：关闭流并把临时名改为
    /// `书名_聚合_序号_第X-Y章.mp3`（单章省略区间）。
    Future<void> finishFile() async {
      await sink!.close();
      sink = null;
      final tmpPath = currentPath!;
      final range = fileStartChapter == fileEndChapter
          ? '第$fileStartChapter章'
          : '第$fileStartChapter-$fileEndChapter章';
      final finalPath = p.join(
        target.path,
        '${_sanitize(book.title)}_聚合_'
        '${(fileIndex - 1).toString().padLeft(3, '0')}_$range.mp3',
      );
      await File(tmpPath).rename(finalPath);
      currentPath = finalPath;
      filePaths.add(finalPath);
    }

    try {
      for (var i = 0; i < book.chapterCount; i++) {
        final chapter = book.chapterAt(i);
        if (!chapter.hasAudio) continue;
        final bytes = _stripId3v2(await File(chapter.audioPath!).readAsBytes());
        // 当前文件放不下本章时先收尾，再开新文件。
        if (sink != null && currentBytes + bytes.length > limitBytes) {
          await finishFile();
        }
        if (sink == null) openNextFile(i);
        sink!.add(bytes);
        currentBytes += bytes.length;
        fileEndChapter = i + 1;
        merged++;
      }
      if (sink != null) await finishFile();
    } catch (_) {
      // 失败时清理已写入的聚合文件，避免残留半成品。
      await sink?.close();
      for (final f in filePaths) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      final pending = currentPath;
      if (pending != null) {
        try {
          await File(pending).delete();
        } catch (_) {}
      }
      rethrow;
    }

    if (merged == 0) {
      throw StateError('没有已生成的音频可聚合');
    }
    return AudioMergeResult(
      filePaths: filePaths,
      mergedCount: merged,
      targetDir: target.path,
    );
  }

  /// 解析导出目标目录：用户选择的目录优先，否则回退文档目录下的
  /// `听书熊导出/<书名>/`。
  Future<Directory> _resolveTarget(Book book) async {
    final chosen = await _pickDirectory();
    return Directory(
      chosen != null && chosen.isNotEmpty
          ? chosen
          : p.join((await _fallbackDir()).path, _sanitize(book.title)),
    );
  }

  /// 去掉 mp3 开头的 ID3v2 标签（如存在），返回纯音频帧数据。
  static Uint8List _stripId3v2(Uint8List bytes) {
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final size = ((bytes[6] & 0x7F) << 21) |
          ((bytes[7] & 0x7F) << 14) |
          ((bytes[8] & 0x7F) << 7) |
          (bytes[9] & 0x7F);
      // 标签总长 = 10 字节头 + 标签体 + 可能的扩展头（flags 0x10）。
      final tagLen = 10 + size + ((bytes[5] & 0x10) != 0 ? 10 : 0);
      if (tagLen <= bytes.length) {
        return Uint8List.sublistView(bytes, tagLen);
      }
    }
    return bytes;
  }

  /// 替换文件名非法字符（Windows 路径字符全平台统一替换）。
  static String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
