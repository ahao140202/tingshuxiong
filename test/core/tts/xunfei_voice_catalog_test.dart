import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/tts/xunfei/xunfei_voice_catalog.dart';
import 'package:tingshuxiong/core/tts/xunfei/xunfei_voices.dart';

void main() {
  group('XunfeiVoiceCatalog', () {
    test('无实时数据源时返回内置聚合目录（基础 + 特色）', () async {
      final catalog = XunfeiVoiceCatalog();

      final voices = await catalog.load();

      expect(voices, xunfeiBuiltinVoices);
      expect(voices.where((v) => v.kind == XunfeiVoiceKind.basic).length, 5);
      expect(voices.where((v) => v.kind == XunfeiVoiceKind.featured).length, 5);
    });

    test('实时数据源返回合法 JSON 时使用实时列表', () async {
      final catalog = XunfeiVoiceCatalog(
        fetcher: () async =>
            '[{"code":"v1","name":"音色一","description":"女声","kind":"basic"},'
            '{"code":"v2","name":"音色二","description":"男声","kind":"featured"}]',
      );

      final voices = await catalog.load();

      expect(voices, hasLength(2));
      expect(voices[0].code, 'v1');
      expect(voices[0].kind, XunfeiVoiceKind.basic);
      expect(voices[1].kind, XunfeiVoiceKind.featured);
    });

    test('实时数据源失败时回退内置目录', () async {
      final catalog = XunfeiVoiceCatalog(
        fetcher: () async => throw Exception('网络不可用'),
      );

      final voices = await catalog.load();

      expect(voices, xunfeiBuiltinVoices);
    });

    test('实时数据源返回非法 JSON 时回退内置目录', () async {
      final catalog = XunfeiVoiceCatalog(
        fetcher: () async => 'not-json',
      );

      final voices = await catalog.load();

      expect(voices, xunfeiBuiltinVoices);
    });

    test('实时数据源缺少必填字段的条目被跳过', () async {
      final catalog = XunfeiVoiceCatalog(
        fetcher: () async =>
            '[{"code":"ok","name":"可用","description":"x"},'
            '{"code":"","name":"空code","description":"x"},'
            '{"name":"缺code","description":"x"}]',
      );

      final voices = await catalog.load();

      expect(voices, hasLength(1));
      expect(voices.single.code, 'ok');
    });
  });
}
