import 'dart:convert';
import 'dart:io';

import 'package:tingshuxiong/core/tts/xunfei/xunfei_auth.dart';

/// 验证长文本是否触发讯飞错误（模拟应用内整章合成）。
/// 讯飞 v2 单次合成文本限制 8000 字节（base64 前，UTF-8），
/// 中文约 2666 字。验证超长时的错误码，确认「文本过长」假设。
Future<void> main() async {
  final settingsFile = File(
    r'C:\Users\user\AppData\Roaming\com.example\tingshuxiong\settings.json',
  );
  final s =
      jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
  final tts = s['ttsCredentials'] as Map<String, dynamic>;
  final appId = tts['appId'] as String;
  final apiKey = tts['apiKey'] as String;
  final apiSecret = tts['apiSecret'] as String;

  const path = '/v2/tts';
  final uri = Uri.parse('wss://tts-api.xfyun.cn$path');
  final date = formatHttpDate(DateTime.now().toUtc());
  final authorization = buildAuthorization(
    apiKey: apiKey,
    apiSecret: apiSecret,
    host: uri.host,
    date: date,
    requestLine: 'GET $path HTTP/1.1',
  );

  // 场景：递增文本量，找出讯飞单次合成上限（模拟 LLM 改写后的整章合成）。
  for (final (label, count) in [
    ('2000字', 2000),
    ('3000字', 3000),
    ('4000字', 4000),
    ('5000字', 5000),
    ('6000字', 6000),
  ]) {
    final text = ('测试文本' * ((count / 4).ceil())).substring(0, count);
    stdout.writeln('=== $label bytes=${utf8.encode(text).length} ===');
    final ws = await WebSocket.connect(uri.toString(), headers: {
      'Authorization': authorization,
      'Date': date,
      'Host': uri.host,
    });
    ws.add(jsonEncode({
      'common': {'app_id': appId},
      'business': {
        'aue': 'lame',
        'sfl': 1,
        'auf': 'audio/L16;rate=16000',
        'tte': 'UTF8',
        'vcn': 'xiaoyan',
        'speed': 50,
        'volume': 50,
        'pitch': 50,
      },
      'data': {
        'text': base64Encode(utf8.encode(text)),
        'status': 2,
      },
    }));
    await for (final msg in ws) {
      final j = jsonDecode(msg as String) as Map<String, dynamic>;
      if (j['code'] != 0) {
        stdout.writeln('  ERROR code=${j['code']} message=${j['message']}');
        break;
      }
      final data = j['data'] as Map<String, dynamic>;
      if (data['status'] == 2) {
        final audio = data['audio'] as String? ?? '';
        stdout.writeln('  OK audio-b64-len=${audio.length}');
        break;
      }
    }
    await ws.close();
  }
}
