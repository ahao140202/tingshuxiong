import '../domain/domain.dart';
import 'deepseek/deepseek_provider.dart';
import 'llm_provider.dart';

/// LLM 提供商注册表：按 [LLMKind] 创建对应实现。
class LLMRegistry {
  const LLMRegistry();

  /// 创建指定类型的提供商。
  ///
  /// [credentials] 为凭据映射，键名见 [LLMKind.credentialFields]；
  /// 各实现只读取自己需要的字段，新增提供商无需改动本签名。
  LLMProvider providerFor(
    LLMKind kind, {
    required Map<String, String> credentials,
  }) {
    switch (kind) {
      case LLMKind.deepSeek:
        return DeepSeekProvider(apiKey: credentials['apiKey'] ?? '');
    }
  }
}
