import '../domain/domain.dart';

/// LLM 调用异常（网络 / 协议 / 业务错误统一包装）。
class LLMException implements Exception {
  LLMException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'LLMException: $message';
}

/// LLM 提供商抽象接口。
///
/// 调度器与 UI 仅依赖本接口与 [LLMKind]；
/// 新增模型在 `provider_kind.dart` 扩展枚举，并在 `llm_registry.dart` 注册实现。
abstract class LLMProvider {
  /// 提供商类型。
  LLMKind get kind;

  /// 当前使用的模型名。
  String get model;

  /// 将章节原文改写为适合语音朗读的口语化文本。
  ///
  /// [title] 章节标题，[rawText] 章节原文；
  /// [maxTokens] 与 [temperature] 缺省时使用引擎默认值（1500 / 0.7）。
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  });
}
