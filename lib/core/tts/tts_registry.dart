import '../domain/domain.dart';
import 'tts_provider.dart';
import 'xunfei/xunfei_provider.dart';

/// TTS 提供商注册表：按 [TTSKind] 创建对应实现。
class TTSRegistry {
  const TTSRegistry();

  /// 创建指定类型的提供商。
  ///
  /// [credentials] 为凭据映射，键名见 [TTSKind.credentialFields]；
  /// 各实现只读取自己需要的字段，新增引擎无需改动本签名。
  TTSProvider providerFor(
    TTSKind kind, {
    required Map<String, String> credentials,
  }) {
    switch (kind) {
      case TTSKind.xunfei:
        return XunfeiTTSProvider(
          appId: credentials['appId'] ?? '',
          apiKey: credentials['apiKey'] ?? '',
          apiSecret: credentials['apiSecret'] ?? '',
        );
    }
  }
}
