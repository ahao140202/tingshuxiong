import 'provider_kind.dart';

/// 引擎运行配置（用户可配置项，不可变）。
///
/// 由用户设置页写入并注入引擎；新增模型/参数在此扩展，
/// 调度器与各 Provider 仅依赖本配置，实现「由用户控制」的扩展方式。
class EngineConfig {
  const EngineConfig({
    this.llmKind = LLMKind.deepSeek,
    this.ttsKind = TTSKind.xunfei,
    this.windowSize = 2,
    this.windowMaxChars = 15000,
    this.maxTokens = 1500,
    this.temperature = 0.7,
    this.tts = const TTSConfig(),
  });

  /// 用户选择的 LLM 提供商。
  final LLMKind llmKind;

  /// 用户选择的 TTS 提供商。
  final TTSKind ttsKind;

  /// 预加载窗口：当前章 + 后续 N 章（默认 2）。
  final int windowSize;

  /// 预加载窗口累计字数上限（默认 15000 字）。
  final int windowMaxChars;

  /// LLM 单次输出 tokens 上限（默认 1500）。
  final int maxTokens;

  /// LLM 采样温度（默认 0.7）。
  final double temperature;

  /// TTS 合成参数。
  final TTSConfig tts;
}

/// TTS 合成通用参数（各引擎共有的可配置项）。
class TTSConfig {
  const TTSConfig({
    this.voice = 'xiaoyan',
    this.speed = 50,
    this.volume = 50,
    this.pitch = 50,
  });

  /// 发音人（vcn，需与所选 TTS 引擎的发音人表匹配）。
  final String voice;

  /// 语速 0-100，默认 50。
  final int speed;

  /// 音量 0-100，默认 50。
  final int volume;

  /// 音高 0-100，默认 50。
  final int pitch;

  TTSConfig copyWith({
    String? voice,
    int? speed,
    int? volume,
    int? pitch,
  }) {
    return TTSConfig(
      voice: voice ?? this.voice,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      pitch: pitch ?? this.pitch,
    );
  }
}