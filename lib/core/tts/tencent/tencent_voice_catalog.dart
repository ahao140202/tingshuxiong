import 'dart:convert';

import 'tencent_voices.dart';

/// 腾讯云音色目录加载器：优先从实时数据源拉取，失败回退内置聚合目录。
///
/// 腾讯云未提供音色列表公开接口，[fetcher] 默认为空（直接返回内置目录）；
/// 未来若官方开放接口或接入自建聚合服务，只需注入返回 JSON 的 [fetcher]：
///
/// ```json
/// [
///   {"id": "101001", "name": "智瑜", "scene": "情感女声",
///    "standard": "premium", "languages": "中文", "sampleRates": "8k/16k",
///    "emotion": "中性"}
/// ]
/// ```
class TencentVoiceCatalog {
  TencentVoiceCatalog({this._fetcher});

  final Future<String> Function()? _fetcher;

  /// 拉取音色列表：实时源失败（网络错误/数据非法）时回退内置目录，
  /// 保证设置页始终有可选项。
  Future<List<TencentVoice>> load() async {
    final fetcher = _fetcher;
    if (fetcher != null) {
      try {
        final raw = await fetcher();
        final parsed = _parse(raw);
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {
        // 实时源不可用，走内置目录。
      }
    }
    return tencentBuiltinVoices;
  }

  /// 解析实时源 JSON；跳过缺字段/非法项。
  static List<TencentVoice> _parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map<String, dynamic> &&
            item['id'] is String &&
            item['id'].toString().isNotEmpty &&
            item['name'] is String &&
            item['name'].toString().isNotEmpty)
          TencentVoice.fromJson(item),
    ];
  }
}
