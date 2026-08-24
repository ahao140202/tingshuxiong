import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 生成文件落盘：把改写稿（中间文件）与合成音频（最终文件）写入
/// 可配置的输出根目录，重新生成时把旧文件转移到历史子目录。
///
/// 目录结构（[setRoot] 配置根目录，默认 `<appSupport>/generated`）：
/// - `<root>/<bookId>/rewrite/<chapterIndex>.txt`   改写稿
/// - `<root>/<bookId>/audio/<chapterIndex>.mp3`     合成音频
/// - `<root>/<bookId>/history/<index>-<时间戳>.mp3`  重新生成时转移的旧文件
/// bookId 中的非法路径字符会被替换为下划线。
class AudioStore {
  AudioStore({Future<Directory> Function()? rootProvider})
      : _defaultRootProvider = rootProvider ?? _defaultRoot;

  final Future<Directory> Function() _defaultRootProvider;
  String? _rootOverride;

  /// 配置输出根目录（应用设置中的「生成文件根目录」）；传 null 恢复默认。
  void setRoot(String? path) => _rootOverride = path;

  Future<Directory> _root() async {
    final override = _rootOverride;
    if (override != null && override.isNotEmpty) {
      return Directory(override);
    }
    return _defaultRootProvider();
  }

  static Future<Directory> _defaultRoot() async {
    final dir = await getApplicationSupportDirectory();
    return Directory(p.join(dir.path, 'generated'));
  }

  Future<Directory> _bookDir(String bookId) async {
    final root = await _root();
    return Directory(p.join(root.path, _sanitize(bookId)));
  }

  /// 保存改写稿（中间文件）并返回文件绝对路径。
  Future<String> saveRewrite(
    String bookId,
    int chapterIndex,
    String text,
  ) async {
    final dir = Directory(p.join((await _bookDir(bookId)).path, 'rewrite'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$chapterIndex.txt'));
    await file.writeAsString(text);
    return file.path;
  }

  /// 保存合成音频并返回文件绝对路径。
  Future<String> saveAudio(
    String bookId,
    int chapterIndex,
    Uint8List audio,
  ) async {
    final dir = Directory(p.join((await _bookDir(bookId)).path, 'audio'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$chapterIndex.mp3'));
    await file.writeAsBytes(audio);
    return file.path;
  }

  /// 把章节的旧生成文件（音频/改写稿）转移到历史子目录，返回新的历史路径。
  ///
  /// 文件带时间戳命名，同一章多次重新生成互不覆盖；
  /// 源文件不存在时对应历史路径返回 null。
  Future<({String? audioPath, String? rewritePath})> moveToHistory(
    String bookId,
    int chapterIndex, {
    String? audioPath,
    String? rewritePath,
  }) async {
    final dir = Directory(p.join((await _bookDir(bookId)).path, 'history'));
    await dir.create(recursive: true);
    final stamp = _timestamp(DateTime.now());

    String? newAudio;
    if (audioPath != null && await File(audioPath).exists()) {
      newAudio = p.join(dir.path, '$chapterIndex-$stamp.mp3');
      await File(audioPath).rename(newAudio);
    }
    String? newRewrite;
    if (rewritePath != null && await File(rewritePath).exists()) {
      newRewrite = p.join(dir.path, '$chapterIndex-$stamp.txt');
      await File(rewritePath).rename(newRewrite);
    }
    return (audioPath: newAudio, rewritePath: newRewrite);
  }

  /// 生成历史文件名时间戳（yyyyMMddHHmmss）。
  static String _timestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 替换 Windows 非法路径字符。
  static String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
