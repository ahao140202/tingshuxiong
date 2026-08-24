import 'dart:convert';
import 'dart:io';

import 'package:tingshuxiong/core/tts/xunfei/xunfei_auth.dart';

/// 临时验证脚本：真实调用讯飞 WebSocket TTS，确认协议与凭据可用。
/// 验证后删除，不进入版本库。
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

  final ws = await WebSocket.connect(uri.toString(), headers: {
    'Authorization': authorization,
    'Date': date,
    'Host': uri.host,
  });
  stdout.writeln('WS connected');

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
      'text': base64Encode(utf8.encode('TingShuXiong TTS test')),
      'status': 2,
    },
  }));

  final audio = StringBuffer();
  await for (final msg in ws) {
    final j = jsonDecode(msg as String) as Map<String, dynamic>;
    if (j['code'] != 0) {
      stdout.writeln('ERROR code=${j['code']} message=${j['message']}');
      break;
    }
    final data = j['data'] as Map<String, dynamic>;
    if (data['audio'] != null) audio.write(data['audio']);
    if (data['status'] == 2) {
      stdout.writeln('DONE status=2 audio-b64-len=${audio.length}');
      break;
    }
    stdout.writeln('frame status=${data['status']}');
  }

  if (audio.isNotEmpty) {
    final raw = base64Decode(audio.toString());
    stdout.writeln('audio bytes=${raw.length}');
    await File(r'd:\tingshuxiong\windows\out\_verify.mp3').writeAsBytes(raw);
    stdout.writeln('saved _verify.mp3');
  }
  await ws.close();
}
