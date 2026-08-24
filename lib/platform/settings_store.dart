import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/domain/domain.dart';

/// 用户可配置设置（提供商选择 + API 凭据 + 引擎参数），JSON 序列化，不可变。
///
/// 凭据以映射存储（键名见 [LLMKind.credentialFields] / [TTSKind.credentialFields]），
/// 新增提供商只需扩展枚举，无需改动本模型与 JSON 结构。
class AppSettings {
  const AppSettings({
    this.llmKind = LLMKind.deepSeek,
    this.ttsKind = TTSKind.xunfei,
    this.llmCredentials = const {},
    this.ttsCredentials = const {},
    this.voice = 'xiaoyan',
    this.speed = 50,
    this.volume = 50,
    this.pitch = 50,
    this.windowSize = 2,
    this.windowMaxChars = 15000,
    this.maxTokens = 1500,
    this.temperature = 0.7,
    this.maxRetries = 3,
    this.outputRoot,
  });

  /// 用户选择的 LLM 提供商。
  final LLMKind llmKind;

  /// 用户选择的 TTS 提供商。
  final TTSKind ttsKind;

  /// LLM 凭据映射（键名见 [LLMKind.credentialFields]）。
  final Map<String, String> llmCredentials;

  /// TTS 凭据映射（键名见 [TTSKind.credentialFields]）。
  final Map<String, String> ttsCredentials;

  final String voice;
  final int speed;
  final int volume;
  final int pitch;
  final int windowSize;
  final int windowMaxChars;
  final int maxTokens;
  final double temperature;
  final int maxRetries;

  /// 生成文件根目录（改写稿/音频/历史文件输出位置）；null 表示默认目录。
  final String? outputRoot;

  /// 是否已填齐所选提供商的全部必填凭据（可装配引擎）。
  bool get hasCredentials =>
      llmKind.credentialFields
          .every((f) => (llmCredentials[f.key] ?? '').isNotEmpty) &&
      ttsKind.credentialFields
          .every((f) => (ttsCredentials[f.key] ?? '').isNotEmpty);

  /// copyWith 哨兵值：区分「未传参」与「显式传 null」（outputRoot 可空）。
  static const Object _unset = Object();

  AppSettings copyWith({
    LLMKind? llmKind,
    TTSKind? ttsKind,
    Map<String, String>? llmCredentials,
    Map<String, String>? ttsCredentials,
    String? voice,
    int? speed,
    int? volume,
    int? pitch,
    int? windowSize,
    int? windowMaxChars,
    int? maxTokens,
    double? temperature,
    int? maxRetries,
    Object? outputRoot = _unset,
  }) {
    return AppSettings(
      llmKind: llmKind ?? this.llmKind,
      ttsKind: ttsKind ?? this.ttsKind,
      llmCredentials: llmCredentials ?? this.llmCredentials,
      ttsCredentials: ttsCredentials ?? this.ttsCredentials,
      voice: voice ?? this.voice,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      pitch: pitch ?? this.pitch,
      windowSize: windowSize ?? this.windowSize,
      windowMaxChars: windowMaxChars ?? this.windowMaxChars,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      maxRetries: maxRetries ?? this.maxRetries,
      outputRoot: identical(outputRoot, _unset)
          ? this.outputRoot
          : outputRoot as String?,
    );
  }

  /// 转换为引擎运行配置。
  EngineConfig toEngineConfig() {
    return EngineConfig(
      llmKind: llmKind,
      ttsKind: ttsKind,
      windowSize: windowSize,
      windowMaxChars: windowMaxChars,
      maxTokens: maxTokens,
      temperature: temperature,
      tts: TTSConfig(voice: voice, speed: speed, volume: volume, pitch: pitch),
    );
  }

  Map<String, dynamic> toJson() => {
        'llmKind': llmKind.name,
        'ttsKind': ttsKind.name,
        'llmCredentials': llmCredentials,
        'ttsCredentials': ttsCredentials,
        'voice': voice,
        'speed': speed,
        'volume': volume,
        'pitch': pitch,
        'windowSize': windowSize,
        'windowMaxChars': windowMaxChars,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'maxRetries': maxRetries,
        'outputRoot': outputRoot,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    // 兼容旧版扁平凭据字段（llmApiKey / ttsAppId / ttsApiKey / ttsApiSecret）。
    final legacyLlmKey = json['llmApiKey'] as String? ?? '';
    final legacyAppId = json['ttsAppId'] as String? ?? '';
    final legacyTtsKey = json['ttsApiKey'] as String? ?? '';
    final legacyTtsSecret = json['ttsApiSecret'] as String? ?? '';

    Map<String, String> readCredentials(String key) {
      final raw = json[key];
      return raw is Map
          ? Map<String, String>.from(raw)
          : const <String, String>{};
    }

    final llmCredentials = readCredentials('llmCredentials');
    final ttsCredentials = readCredentials('ttsCredentials');
    return AppSettings(
      llmKind:
          LLMKind.values.asNameMap()[json['llmKind']] ?? LLMKind.deepSeek,
      ttsKind: TTSKind.values.asNameMap()[json['ttsKind']] ?? TTSKind.xunfei,
      llmCredentials: llmCredentials.isEmpty && legacyLlmKey.isNotEmpty
          ? {'apiKey': legacyLlmKey}
          : llmCredentials,
      ttsCredentials: ttsCredentials.isEmpty && legacyAppId.isNotEmpty
          ? {
              'appId': legacyAppId,
              if (legacyTtsKey.isNotEmpty) 'apiKey': legacyTtsKey,
              if (legacyTtsSecret.isNotEmpty) 'apiSecret': legacyTtsSecret,
            }
          : ttsCredentials,
      voice: json['voice'] as String? ?? 'xiaoyan',
      speed: json['speed'] as int? ?? 50,
      volume: json['volume'] as int? ?? 50,
      pitch: json['pitch'] as int? ?? 50,
      windowSize: json['windowSize'] as int? ?? 2,
      windowMaxChars: json['windowMaxChars'] as int? ?? 15000,
      maxTokens: json['maxTokens'] as int? ?? 1500,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      maxRetries: json['maxRetries'] as int? ?? 3,
      outputRoot: json['outputRoot'] as String?,
    );
  }
}

/// 设置持久化：JSON 文件读写；文件缺失或损坏时回退默认设置。
class SettingsStore {
  SettingsStore({Future<File> Function()? fileProvider})
      : _fileProvider = fileProvider ?? _defaultFile;

  final Future<File> Function() _fileProvider;

  static Future<File> _defaultFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'settings.json'));
  }

  Future<AppSettings> load() async {
    final file = await _fileProvider();
    if (!await file.exists()) return const AppSettings();
    try {
      final json = jsonDecode(await file.readAsString());
      return AppSettings.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final file = await _fileProvider();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
