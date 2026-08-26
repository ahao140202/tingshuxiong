import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 生成文件落盘：把改写稿（中间文件）与合成音频（最终文件）写入
/// 可配置的输出根目录，整本重新生成时删除旧文件后从头生成。
///
/// 目录结构（[setRoot] 配置根目录，默认 `<appSupport>/generated`）：
/// - `<root>/<bookId>/rewrite/<chapterIndex>.txt`   改写稿
/// - `<root>/<bookId>/audio/<chapterIndex>.mp3`     合成音频
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

  /// 删除章节的旧生成文件（音频/改写稿）——整本重新生成时清空旧产物。
  ///
  /// 源文件不存在时静默跳过；删除失败抛异常（调用方负责提示），
  /// 避免残留旧文件与新生成内容混用。
  Future<void> deleteChapterFiles({
    String? audioPath,
    String? rewritePath,
  }) async {
    if (audioPath != null && await File(audioPath).exists()) {
      await File(audioPath).delete();
    }
    if (rewritePath != null && await File(rewritePath).exists()) {
      await File(rewritePath).delete();
    }
  }

  /// 删除整本书的生成目录（`<root>/<bookId>/`，含 audio 与 rewrite
  /// 子目录），用于「删除小说」彻底清理。
  ///
  /// 目录不存在时静默跳过；删除失败抛异常（调用方负责提示）。
  Future<void> deleteBookFiles(String bookId) async {
    final dir = await _bookDir(bookId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 替换 Windows 非法路径字符。
  static String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
