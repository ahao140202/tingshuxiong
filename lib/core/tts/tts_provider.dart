import 'dart:typed_data';

import '../domain/domain.dart';

/// TTS 调用异常（网络 / 协议 / 业务错误统一包装）。
class TTSException implements Exception {
  TTSException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'TTSException: $message';
}

/// TTS 提供商抽象接口。
///
/// 调度器与 UI 仅依赖本接口与 [TTSKind]；
/// 新增引擎在 `provider_kind.dart` 扩展枚举，并在 `tts_registry.dart` 注册实现。
abstract class TTSProvider {
  /// 提供商类型。
  TTSKind get kind;

  /// 将文本合成为音频（MP3），返回完整音频字节。
  ///
  /// [text] 为单段可合成文本（长度需遵守引擎限制，超长文本请先用 TextChunker 切分）；
  /// [config] 为合成参数（发音人 / 语速 / 音量 / 音高）。
  Future<Uint8List> synthesize({required String text, required TTSConfig config});
}
