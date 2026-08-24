import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:file_selector/file_selector.dart';

/// 选中的 txt 文件内容。
class TxtFile {
  const TxtFile({required this.name, required this.content});

  final String name;
  final String content;
}

/// 文本文件选择抽象：AppState 仅依赖本接口，便于测试注入假实现。
abstract class TxtPicker {
  /// 弹出系统文件选择框；用户取消时返回 null。
  Future<TxtFile?> pick();
}

/// 选择并读取 txt 小说文件；自动识别 UTF-8 / GBK 编码。
class TxtFilePicker implements TxtPicker {
  @override
  Future<TxtFile?> pick() async {
    const typeGroup = XTypeGroup(label: '文本文件', extensions: ['txt', 'text']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return TxtFile(name: file.name, content: decodeText(bytes));
  }

  /// 优先按 UTF-8 解码，失败（如 GBK 编码的中文小说）时回退 GBK。
  static String decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return gbk.decode(bytes);
    }
  }
}
