import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../domain/domain.dart';
import '../../text/text.dart';
import '../tts_provider.dart';
import 'tencent_auth.dart';
import 'tencent_stream_tts_provider.dart';

/// 腾讯云基础语音合成实现（TextToVoice 接口，API 3.0 签名）。
///
/// 接口为 `https://tts.tencentcloudapi.com`（POST + JSON），认证采用
/// TC3-HMAC-SHA256 签名（见 [TencentSigner]），请求头携带
/// `X-TC-Action: TextToVoice`、`X-TC-Version: 2019-08-23`；
/// 响应为 `Response.Audio`（base64 编码的 mp3 音频）。
///
/// 基础接口只支持大模型（501xxx / 601xxx）与精品音色（101xxx 等）；
/// 超自然大模型音色（502xxx / 602xxx / 603xxx）仅实时语音合成接口
/// 提供，选择此类音色时自动切换到 [TencentStreamTTSProvider]
/// （WebSocket 实现，需额外配置 [appId]）。
///
/// 鉴权凭据（SecretId / SecretKey）由上层（facade / 设置页）注入。
/// 单次合成文本上限：中文 150 汉字（全角标点算 1 字）或英文 500 字母，
/// 即任意 450 字节内的 UTF-8 文本均不超限，超长文本由本类内部按
/// [TextChunker] 自动分块合成并拼接，调用方无需关心。
///
/// 腾讯云接口不支持音高参数：语速/音量由 [TTSConfig] 0-100 通用值映射为
/// 接口范围（语速 [-2,6]、音量 [-10,10]），音高字段被忽略。
class TencentTTSProvider implements TTSProvider {
  TencentTTSProvider({
    required this.secretId,
    required this.secretKey,
    this.appId = '',
    Dio? dio,
    Future<TtsWebSocket> Function(Uri)? wsConnect,
    this._baseUrl = defaultBaseUrl,
    DateTime Function()? now,
    this.streamTimeout = const Duration(minutes: 5),
  })  : _dio = dio ?? _defaultDio(_baseUrl),
        _now = now ?? DateTime.now,
        _stream = TencentStreamTTSProvider(
          secretId: secretId,
          secretKey: secretKey,
          appId: appId,
          wsConnect: wsConnect,
          now: now,
          timeout: streamTimeout,
        );

  /// 默认 HTTP 客户端（可在构造时注入自定义 Dio 以便测试）。
  static Dio _defaultDio(String baseUrl) {
    return Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
  }

  /// 官方 API 地址。
  static const String defaultBaseUrl = 'https://tts.tencentcloudapi.com';

  /// 单次合成文本上限（UTF-8 字节）。
  ///
  /// 接口限制中文 150 汉字（全角标点算 1 字，3 字节）或英文 500 字母，
  /// 450 字节内任意 UTF-8 文本两者均不超限；此处留少量余量。
  static const int maxTextBytes = 440;

  /// 接口常量（API 3.0 请求头）。
  static const String action = 'TextToVoice';
  static const String version = '2019-08-23';
  static const String region = 'ap-guangzhou';
  static const String service = 'tts';

  final String secretId;
  final String secretKey;

  /// 腾讯云账号 AppId：仅超自然大模型音色（实时合成）需要，
  /// 普通音色走基础接口无需配置。
  final String appId;

  /// 超自然音色实时合成的等待超时（透传给 [TencentStreamTTSProvider]）。
  final Duration streamTimeout;

  final String _baseUrl;
  final Dio _dio;
  final DateTime Function() _now;
  final TencentStreamTTSProvider _stream;

  @override
  TTSKind get kind => TTSKind.tencent;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    // 超自然大模型音色仅实时语音合成（WebSocket）接口支持，
    // 与基础接口音色表互不通用，选择时自动切换到流式实现。
    if (TencentStreamTTSProvider.isSupernaturalVoice(config.voice)) {
      return _stream.synthesize(text: text, config: config);
    }
    // 单次合成有 150 汉字/500 字母上限：超限时按句分块、逐块合成并拼接
    // MP3（MP3 帧自包含，顺序拼接即可正常播放）。
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
    final timestamp = _now().millisecondsSinceEpoch ~/ 1000;
    final host = Uri.parse(_baseUrl).host;
    final payload = jsonEncode({
      'Text': text,
      'SessionId': '${_now().microsecondsSinceEpoch}',
      'VoiceType': int.tryParse(config.voice) ?? 101001,
      // TTSConfig 0-100 → 腾讯云接口范围：语速 [-2,6]、音量 [-10,10]。
      'Speed': _mapSpeed(config.speed),
      'Volume': _mapVolume(config.volume),
      'SampleRate': 16000,
      'Codec': 'mp3',
    });
    final signer = TencentSigner(secretId: secretId, secretKey: secretKey);

    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/',
        data: payload,
        options: Options(
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Host': host,
            'X-TC-Action': action,
            'X-TC-Version': version,
            'X-TC-Timestamp': '$timestamp',
            'X-TC-Region': region,
            'Authorization': signer.authorization(
              timestamp: timestamp,
              payload: payload,
              host: host,
            ),
          },
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw TTSException('腾讯云请求失败: ${e.message}', e);
    }

    final resp = response.data?['Response'];
    final error = resp is Map ? resp['Error'] : null;
    if (error is Map) {
      throw TTSException(
        '腾讯云合成失败(${error['Code']}): ${error['Message'] ?? '未知错误'}',
      );
    }
    final audioB64 = resp is Map ? resp['Audio'] : null;
    if (audioB64 is! String || audioB64.isEmpty) {
      throw TTSException('腾讯云响应缺少音频数据');
    }
    try {
      return base64Decode(audioB64);
    } on FormatException catch (e) {
      throw TTSException('腾讯云音频 base64 解码失败', e);
    }
  }

  /// TTSConfig 语速 0-100 → 接口语速 [-2,6]（0 为 1.0 倍速默认）。
  ///
  /// 两段线性映射：0-50 → -2..0（0.6-1.0 倍），50-100 → 0..6（1.0-2.5 倍）。
  static double _mapSpeed(int value) {
    if (value <= 50) return value / 25 - 2;
    return (value - 50) / 50 * 6;
  }

  /// TTSConfig 音量 0-100 → 接口音量 [-10,10]（50 为 0 正常音量）。
  static double _mapVolume(int value) => (value - 50) / 5;
}
