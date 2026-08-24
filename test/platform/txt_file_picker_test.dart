import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/platform/txt_file_picker.dart';

void main() {
  group('TxtFilePicker.decodeText', () {
    test('UTF-8 编码正常解码', () {
      final bytes = utf8.encode('第一章 相遇\n正文内容');
      expect(TxtFilePicker.decodeText(bytes), '第一章 相遇\n正文内容');
    });

    test('GBK 编码回退解码', () {
      final bytes = gbk.encode('第一章 相遇\n正文内容');
      expect(TxtFilePicker.decodeText(bytes), '第一章 相遇\n正文内容');
    });

    test('GBK 编码按 UTF-8 解码会失败并回退', () {
      // 中文字符 GBK 字节通常不是合法 UTF-8 序列
      final bytes = gbk.encode('你好世界');
      // 直接 utf8.decode 应抛异常（保证测试覆盖回退分支）
      expect(() => utf8.decode(bytes), throwsFormatException);
      expect(TxtFilePicker.decodeText(bytes), '你好世界');
    });

    test('ASCII 文本两种编码结果一致', () {
      final bytes = utf8.encode('hello world 123');
      expect(TxtFilePicker.decodeText(bytes), 'hello world 123');
    });
  });
}
