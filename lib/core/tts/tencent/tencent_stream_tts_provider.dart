import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/domain.dart';
import '../../text/text.dart';
import '../tts_provider.dart';

/// WebSocket 最小抽象：隔离 dart:io 依赖，便于测试注入替身。
abstract class TtsWebSocket {
  /// 接收消息流（文本为 JSON 响应，二进制为音频帧）。
  Stream<dynamic> get stream;

  /// 连接关闭后完成。
  Future<void> get done;

  /// 主动关闭连接（协议要求收到尾包后由客户端关闭）。
  Future<void> close([int? code, String? reason]);
}

/// dart:io [WebSocket] 适配器。
class _IoWebSocket implements TtsWebSocket {
  _IoWebSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<dynamic> get stream => _ws;

  @override
  Future<void> get done => _ws.done;

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}

/// 腾讯云实时语音合成实现（TextToStreamAudioWS 接口，WebSocket）。
///
/// 基础语音合成（TextToVoice，见 [TencentTTSProvider]）只支持大模型与
/// 精品音色；超自然大模型音色（502xxx / 602xxx / 603xxx，如智小虎、
/// 爱小悠）仅在本接口提供，且只能使用实时接口的音色表。调用方按
/// [isSupernaturalVoice] 分流到本实现。
///
/// 鉴权与 TextToVoice 的 TC3 签名不同：全部参数拼入请求 URL，签名原文为
/// `GETtts.cloud.tencent.com/stream_ws?<参数按字典序拼接，值为原文>`，
/// 签名 = base64(HMAC-SHA1(签名原文, SecretKey))，最终 URL 中参数值做
/// Java `URLEncoder` 风格编码（空格转 `+`），签名再编码一次后以
/// `&Signature=` 追加。
///
/// 连接建立后服务端直接返回流式结果，无需客户端发消息：文本消息为
/// JSON 响应（`code == 0` 成功，`final == 1` 表示全部合成结束，客户端
/// 需主动关闭连接），二进制消息为音频帧，按序拼接即为完整音频。
class TencentStreamTTSProvider implements TTSProvider {
  TencentStreamTTSProvider({
    required this.secretId,
    required this.secretKey,
    this.appId = '',
    Future<TtsWebSocket> Function(Uri)? wsConnect,
    this._baseUrl = defaultWsUrl,
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 5),
  })  : _wsConnect = wsConnect ??
            ((uri) async => _IoWebSocket(await WebSocket.connect(uri.toString()))),
        _now = now ?? DateTime.now;

  /// 官方 WebSocket 地址。
  static const String defaultWsUrl = 'wss://tts.cloud.tencent.com/stream_ws';

  /// 签名原文前缀（请求方法 GET + 域名 + 路径，注意大小写）。
  static const String signPrefix = 'GETtts.cloud.tencent.com/stream_ws';

  /// 接口名（URL 参数 Action）。
  static const String action = 'TextToStreamAudioWS';

  /// 单次合成文本上限（UTF-8 字节）。
  ///
  /// 接口限制中文 600 汉字（全角标点算 1 字）或英文 1800 字母，
  /// 1800 字节内任意 UTF-8 文本两者均不超限。
  static const int maxTextBytes = 1800;

  /// 等待合成结束的总超时（含连接与流式接收；超自然音色合成一段
  /// 600 字音频约 2-3 分钟，默认留足余量）。
  final Duration timeout;

  final String secretId;
  final String secretKey;

  /// 腾讯云账号 AppId（实时合成签名必填，控制台「账号信息」可查）。
  final String appId;

  final String _baseUrl;
  final Future<TtsWebSocket> Function(Uri) _wsConnect;
  final DateTime Function() _now;

  @override
  TTSKind get kind => TTSKind.tencent;

  /// 是否为超自然大模型音色（仅实时语音合成接口支持）。
  ///
  /// 官方音色 ID 段：502xxx（智小虎/智小柔等聊天类）、602xxx（爱小悠等）、
  /// 603xxx（懂事少年等特色类）。
  static bool isSupernaturalVoice(String voiceId) =>
      voiceId.startsWith('502') ||
      voiceId.startsWith('602') ||
      voiceId.startsWith('603');

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    if (appId.isEmpty) {
      throw TTSException('使用超自然音色需在设置中填写腾讯云 AppId（控制台账号信息）');
    }
    // 单次合成有 600 汉字/1800 字母上限：超限时按句分块、逐块合成并
    // 拼接 MP3（MP3 帧自包含，顺序拼接即可正常播放）。
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

  /// 单次合成（文本已满足长度限制）：签名 → 连接 → 流式接收音频。
  Future<Uint8List> _synthesizeOnce({
    required String text,
    required TTSConfig config,
  }) async {
    final timestamp = _now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'Action': action,
      'AppId': appId,
      'Codec': 'mp3',
      'EnableSubtitle': 'false',
      'Expired': '${timestamp + 86400}',
      'SampleRate': '16000',
      'SecretId': secretId,
      'SessionId': '${_now().microsecondsSinceEpoch}',
      'Speed': _formatNum(_mapSpeed(config.speed)),
      'Text': text,
      'Timestamp': '$timestamp',
      'VoiceType': int.tryParse(config.voice)?.toString() ?? '101001',
      'Volume': _formatNum(_mapVolume(config.volume)),
    };
    // 参数按字典序拼接（签名与 URL 共用；签名用原文、URL 值做编码）。
    final sortedKeys = params.keys.toList()..sort();
    String join({required bool encodeValue}) => sortedKeys
        .map((k) => '$k=${encodeValue ? _urlEncode(params[k]!) : params[k]}')
        .join('&');

    final signRaw = '$signPrefix?${join(encodeValue: false)}';
    final digest = Hmac(sha1, utf8.encode(secretKey))
        .convert(utf8.encode(signRaw))
        .bytes;
    final sign = base64Encode(digest);
    final url =
        Uri.parse('$_baseUrl?${join(encodeValue: true)}&Signature=${_urlEncode(sign)}');

    final TtsWebSocket ws;
    try {
      ws = await _wsConnect(url);
    } on WebSocketException catch (e) {
      throw TTSException('腾讯云实时合成连接失败: ${e.message}', e);
    } on SocketException catch (e) {
      throw TTSException('腾讯云实时合成连接失败: ${e.message}', e);
    }

    // 流式接收：文本消息解析 JSON 状态，二进制消息为音频帧。
    final audio = BytesBuilder();
    TTSException? failure;
    final sub = ws.stream.listen(
      (message) {
        if (message is String) {
          Map<String, dynamic>? decoded;
          try {
            final value = jsonDecode(message);
            if (value is Map<String, dynamic>) decoded = value;
          } on FormatException {
            // 非 JSON 文本消息忽略。
          }
          final code = decoded?['code'];
          if (code is int && code != 0) {
            failure = TTSException(
              '腾讯云合成失败($code): ${decoded!['message'] ?? '未知错误'}',
            );
            ws.close(1000);
          } else if (decoded?['final'] == 1) {
            // 尾包：全部合成结束，按协议主动关闭连接。
            ws.close(1000);
          }
        } else if (message is List<int>) {
          audio.add(message);
        }
      },
      onError: (Object e) {
        // 流错误后连接已不可用：置失败并结束等待，避免挂到超时。
        failure ??= TTSException('腾讯云实时合成连接中断: $e', e);
        ws.close(1000);
      },
    );

    try {
      await ws.done.timeout(timeout, onTimeout: () {
        failure ??= TTSException('腾讯云实时合成超时（${timeout.inSeconds} 秒无结果）');
        ws.close(1000);
      });
    } on TimeoutException {
      // timeout 回调已置 failure，此处无需处理。
    } catch (e) {
      // 连接中途异常断开（done 以 error 完成）。
      failure ??= TTSException('腾讯云实时合成连接中断: $e', e);
    } finally {
      sub.cancel();
    }

    if (failure != null) throw failure!;
    return audio.takeBytes();
  }

  /// TTSConfig 语速 0-100 → 接口语速 [-2,6]（与基础合成接口一致）。
  ///
  /// 两段线性映射：0-50 → -2..0（0.6-1.0 倍），50-100 → 0..6（1.0-2.5 倍）。
  static double _mapSpeed(int value) {
    if (value <= 50) return value / 25 - 2;
    return (value - 50) / 50 * 6;
  }

  /// TTSConfig 音量 0-100 → 接口音量 [0,10]（实时合成仅可放大，
  /// 0 为正常音量，50 分位以下保持 0 不变）。
  static double _mapVolume(int value) => value <= 50 ? 0 : (value - 50) / 5;

  /// 对齐 Java SDK 的数值格式：整数值输出为整数（1.0 → "1"）。
  static String _formatNum(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : value.toString();

  /// Java `URLEncoder.encode` 兼容编码（腾讯云签名 URL 要求）：
  /// 字母数字与 `-_.*` 不编码，空格转 `+`，其余按 UTF-8 字节 %XX 大写。
  static String _urlEncode(String input) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(input)) {
      if ((byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          (byte >= 0x30 && byte <= 0x39) ||
          byte == 0x2D ||
          byte == 0x5F ||
          byte == 0x2E ||
          byte == 0x2A) {
        buffer.writeCharCode(byte);
      } else if (byte == 0x20) {
        buffer.write('+');
      } else {
        buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return buffer.toString();
  }
}
