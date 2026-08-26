import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/tts/tencent/tencent_voice_catalog.dart';
import 'package:tingshuxiong/core/tts/tencent/tencent_voices.dart';

void main() {
  group('TencentVoiceCatalog', () {
    test('无实时数据源时返回内置聚合目录（48 个，按音色标准分组）', () async {
      final catalog = TencentVoiceCatalog();

      final voices = await catalog.load();

      expect(voices, tencentBuiltinVoices);
      expect(voices, hasLength(48));
      expect(
        voices.where((v) => v.standard == TencentVoiceStandard.superNatural).length,
        17,
      );
      expect(
        voices.where((v) => v.standard == TencentVoiceStandard.largeModel).length,
        17,
      );
      expect(
        voices.where((v) => v.standard == TencentVoiceStandard.premium).length,
        14,
      );
      // 默认音色 101001 智瑜（情感女声，精品音色）在目录中。
      expect(voices.any((v) => v.id == '101001' && v.name == '智瑜'), isTrue);
    });

    test('内置目录音色 ID 唯一且均为纯数字', () {
      final ids = tencentBuiltinVoices.map((v) => v.id).toSet();
      expect(ids, hasLength(tencentBuiltinVoices.length));
      for (final v in tencentBuiltinVoices) {
        expect(int.tryParse(v.id), isNotNull, reason: '音色 ${v.id} 应为数字 ID');
      }
    });

    test('实时数据源返回合法 JSON 时使用实时列表', () async {
      final catalog = TencentVoiceCatalog(
        fetcher: () async =>
            '[{"id":"101001","name":"智瑜","scene":"情感女声","standard":"premium",'
            '"languages":"中文","sampleRates":"8k/16k","emotion":"中性"},'
            '{"id":"501000","name":"智斌","scene":"阅读男声","standard":"largeModel"}]',
      );

      final voices = await catalog.load();

      expect(voices, hasLength(2));
      expect(voices[0].standard, TencentVoiceStandard.premium);
      expect(voices[0].languages, '中文');
      expect(voices[1].standard, TencentVoiceStandard.largeModel);
      expect(voices[1].sampleRates, '8k/16k/24k'); // 缺省字段回退默认
    });

    test('实时数据源失败时回退内置目录', () async {
      final catalog = TencentVoiceCatalog(
        fetcher: () async => throw Exception('网络不可用'),
      );

      final voices = await catalog.load();

      expect(voices, tencentBuiltinVoices);
    });

    test('实时数据源返回非法 JSON 时回退内置目录', () async {
      final catalog = TencentVoiceCatalog(fetcher: () async => 'not-json');

      final voices = await catalog.load();

      expect(voices, tencentBuiltinVoices);
    });

    test('实时数据源缺少必填字段的条目被跳过', () async {
      final catalog = TencentVoiceCatalog(
        fetcher: () async =>
            '[{"id":"101001","name":"智瑜","scene":"x","standard":"premium"},'
            '{"id":"","name":"空id","scene":"x","standard":"premium"},'
            '{"name":"缺id","scene":"x","standard":"premium"}]',
      );

      final voices = await catalog.load();

      expect(voices, hasLength(1));
      expect(voices.single.id, '101001');
    });
  });
}
