import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/domain.dart';
import '../../text/text.dart';
import '../tts_provider.dart';
import 'xunfei_auth.dart';

/// 科大讯飞在线语音合成实现（WebAPI v2，WebSocket 协议）。
///
/// 讯飞 v2 接口为 `wss://tts-api.xfyun.cn/v2/tts`（WebSocket），
/// 请求帧包含 `common`（app_id）、`business`（合成参数）、`data`（base64 文本）；
/// 响应分多帧返回（status 0/1/2），本类自动拼接音频并解码。
///
/// 鉴权凭据（appId / apiKey / apiSecret）由上层（facade / 设置页）注入。
/// 单次合成文本限制 13000 字节（base64 前，实测超出返回 code=10163），
/// 超长文本由本类内部按 [TextChunker] 自动分块合成并拼接，调用方无需关心。
class XunfeiTTSProvider implements TTSProvider {
  XunfeiTTSProvider({
    required this.appId,
    required this.apiKey,
    required this.apiSecret,
    Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers})?
        connect,
    this._baseUrl = defaultBaseUrl,
  }) : _connect = connect ?? _defaultConnect;

  /// 默认连接器：dart:io WebSocket（允许携带 Date/Authorization 等自定义头）。
  static Future<WebSocket> _defaultConnect(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) {
    return WebSocket.connect(uri.toString(), headers: headers);
  }

  /// 在线合成 WebAPI 地址（WebSocket）。
  static const String defaultBaseUrl = 'wss://tts-api.xfyun.cn/v2/tts';

  /// 单次合成文本上限（UTF-8 字节）。
  ///
  /// 实测讯飞 v2 返回 `10163 param validate error: '$.data.text' length must
  /// be less or equal than 13000`，此处取 12000 留安全余量。
  static const int maxTextBytes = 12000;

  final String appId;
  final String apiKey;
  final String apiSecret;
  final String _baseUrl;
  final Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers})
      _connect;

  @override
  TTSKind get kind => TTSKind.xunfei;

  /// 输出 MP3 格式（aue=lame），流式返回（sfl=1）。
  static const Map<String, dynamic> _defaultBusiness = {
    'aue': 'lame',
    'sfl': 1,
    'auf': 'audio/L16;rate=16000',
    'tte': 'UTF8',
  };

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    // 单次合成有 13000 字节上限：超限时按句分块、逐块合成并拼接 MP3
    // （MP3 帧自包含，顺序拼接即可正常播放）。
    final chunks = TextChunker(maxBytes: maxTextBytes).chunk(text);
    if (chunks.length == 1) {
      return _synthesizeOnce(text: text, config: config);
    }
    final audio = BytesBuilder();
    for (final chunk in chunks) {
      audio.add(await _synthesizeOnce(text: chunk, config: config));
    }
    return audio.takeBytes();
  }

  /// 单次合成（文本已满足长度限制）。
  Future<Uint8List> _synthesizeOnce({
    required String text,
    required TTSConfig config,
  }) async {
    final uri = Uri.parse(_baseUrl);
    final date = formatHttpDate(DateTime.now().toUtc());
    final authorization = buildAuthorization(
      apiKey: apiKey,
      apiSecret: apiSecret,
      host: uri.host,
      date: date,
      requestLine: 'GET ${uri.path} HTTP/1.1',
    );

    final WebSocket ws;
    try {
      ws = await _connect(
        uri,
        headers: {
          'Authorization': authorization,
          'Date': date,
          'Host': uri.host,
        },
      );
    } on Exception catch (e) {
      throw TTSException('讯飞连接失败: $e', e);
    }

    try {
      ws.add(jsonEncode({
        'common': {'app_id': appId},
        'business': {
          ..._defaultBusiness,
          'vcn': config.voice,
          'speed': config.speed,
          'volume': config.volume,
          'pitch': config.pitch,
        },
        'data': {
          'text': base64Encode(utf8.encode(text)),
          'status': 2,
        },
      }));

      // 每帧 audio 是独立的 base64 块（可能带自己的 padding），逐帧解码后拼接字节。
      final audio = BytesBuilder();
      await for (final msg in ws) {
        final Map<String, dynamic> frame;
        try {
          frame = jsonDecode(msg as String) as Map<String, dynamic>;
        } on FormatException catch (e) {
          throw TTSException('讯飞响应格式错误: $e', e);
        }
        final code = frame['code'];
        if (code != 0) {
          throw TTSException(
            '讯飞合成失败(code=$code): ${frame['message'] ?? '未知错误'}',
          );
        }
        final data = frame['data'] as Map<String, dynamic>?;
        final audioB64 = data?['audio'];
        if (audioB64 is String && audioB64.isNotEmpty) {
          try {
            audio.add(base64Decode(audioB64));
          } on FormatException catch (e) {
            throw TTSException('讯飞音频 base64 解码失败', e);
          }
        }
        if (data?['status'] == 2) break;
      }

      if (audio.isEmpty) {
        throw TTSException('讯飞响应缺少音频数据');
      }
      return audio.takeBytes();
    } finally {
      await ws.close();
    }
  }
}
