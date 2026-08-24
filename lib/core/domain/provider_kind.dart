/// 凭据字段描述：设置页按此渲染输入框，注册表按此从凭据映射取值。
///
/// [key] 为凭据映射中的键名（如 `apiKey` / `appId`）；
/// [label] 为设置页显示名（如 `API Key`）；[obscure] 控制是否密码框。
class CredentialField {
  const CredentialField(this.key, this.label, {this.obscure = false});

  final String key;
  final String label;
  final bool obscure;
}

/// LLM 提供商类型。
///
/// 新增模型时在此扩展枚举（凭据字段一并声明），并在
/// `llm/llm_registry.dart` 注册对应实现，调用方（UI/调度器）
/// 仅依赖 [LLMKind] 与 `LLMProvider` 接口，无需改动。
enum LLMKind {
  deepSeek(
    'DeepSeek',
    'deepseek-v4-flash',
    [CredentialField('apiKey', 'API Key', obscure: true)],
  );

  const LLMKind(this.label, this.defaultModel, this.credentialFields);

  /// 展示名。
  final String label;

  /// 默认模型名（deepseek-chat 已于 2026-07-24 弃用，使用 v4-flash）。
  final String defaultModel;

  /// 该提供商所需的凭据字段（设置页据此渲染，注册表据此取值）。
  final List<CredentialField> credentialFields;
}

/// TTS 提供商类型。
enum TTSKind {
  xunfei(
    '讯飞',
    'xiaoyan',
    [
      CredentialField('appId', 'APPID'),
      CredentialField('apiKey', 'API Key', obscure: true),
      CredentialField('apiSecret', 'API Secret', obscure: true),
    ],
  );

  const TTSKind(this.label, this.defaultVoice, this.credentialFields);

  /// 展示名。
  final String label;

  /// 默认发音人（vcn）。
  final String defaultVoice;

  /// 该提供商所需的凭据字段（设置页据此渲染，注册表据此取值）。
  final List<CredentialField> credentialFields;
}
