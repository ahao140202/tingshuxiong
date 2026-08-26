import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/domain/domain.dart';

/// 用户可配置设置（提供商选择 + API 凭据 + 引擎参数），JSON 序列化，不可变。
///
/// 凭据与音色按提供商维度保存（键为提供商枚举名，如 `deepSeek` / `tencent`），
/// 切换提供商时各自记住已填凭据与所选音色，互不覆盖；键名见
/// [LLMKind.credentialFields] / [TTSKind.credentialFields]。
/// 新增提供商只需扩展枚举，无需改动本模型与 JSON 结构。
class AppSettings {
  const AppSettings({
    this.llmKind = LLMKind.deepSeek,
    this.ttsKind = TTSKind.xunfei,
    this.llmCredentialsByKind = const {},
    this.ttsCredentialsByKind = const {},
    this.voiceByKind = const {},
    this.speed = 50,
    this.volume = 50,
    this.pitch = 50,
    this.windowSize = 2,
    this.windowMaxChars = 15000,
    this.maxTokens = 1500,
    this.temperature = 0.7,
    this.maxRetries = 3,
    this.mergeFileSizeMb = 100,
    this.outputRoot,
  });

  /// 用户选择的 LLM 提供商。
  final LLMKind llmKind;

  /// 用户选择的 TTS 提供商。
  final TTSKind ttsKind;

  /// LLM 凭据（key = 提供商枚举名，value = 该提供商的凭据映射）。
  final Map<String, Map<String, String>> llmCredentialsByKind;

  /// TTS 凭据（key = 提供商枚举名，value = 该提供商的凭据映射）。
  final Map<String, Map<String, String>> ttsCredentialsByKind;

  /// 各 TTS 提供商选中的音色（key = 提供商枚举名，value = 音色 ID）。
  final Map<String, String> voiceByKind;

  final int speed;
  final int volume;
  final int pitch;
  final int windowSize;
  final int windowMaxChars;
  final int maxTokens;
  final double temperature;
  final int maxRetries;

  /// 聚合导出单文件大小上限（MB）：按此限制把章节音频打包为
  /// 数量更少的聚合大文件，默认 100。
  final int mergeFileSizeMb;

  /// 生成文件根目录（改写稿/音频输出位置）；null 表示默认目录。
  final String? outputRoot;

  /// 指定 LLM 提供商的凭据映射（未配置时为空表）。
  Map<String, String> llmCredentialsFor(LLMKind kind) =>
      llmCredentialsByKind[kind.name] ?? const {};

  /// 指定 TTS 提供商的凭据映射（未配置时为空表）。
  Map<String, String> ttsCredentialsFor(TTSKind kind) =>
      ttsCredentialsByKind[kind.name] ?? const {};

  /// 当前所选 LLM 提供商的凭据。
  Map<String, String> get llmCredentials => llmCredentialsFor(llmKind);

  /// 当前所选 TTS 提供商的凭据。
  Map<String, String> get ttsCredentials => ttsCredentialsFor(ttsKind);

  /// 指定 TTS 提供商选中的音色（未配置时用该提供商默认音色）。
  String voiceFor(TTSKind kind) => voiceByKind[kind.name] ?? kind.defaultVoice;

  /// 当前所选 TTS 提供商的音色。
  String get voice => voiceFor(ttsKind);

  /// 是否已填齐所选提供商的全部必填凭据（可装配引擎）；
  /// 可选填字段（[CredentialField.optional]）不参与校验。
  bool get hasCredentials =>
      llmKind.credentialFields.every((f) =>
          f.optional ||
          (llmCredentialsFor(llmKind)[f.key] ?? '').isNotEmpty) &&
      ttsKind.credentialFields.every((f) =>
          f.optional ||
          (ttsCredentialsFor(ttsKind)[f.key] ?? '').isNotEmpty);

  /// copyWith 哨兵值：区分「未传参」与「显式传 null」（outputRoot 可空）。
  static const Object _unset = Object();

  AppSettings copyWith({
    LLMKind? llmKind,
    TTSKind? ttsKind,
    Map<String, Map<String, String>>? llmCredentialsByKind,
    Map<String, Map<String, String>>? ttsCredentialsByKind,
    Map<String, String>? voiceByKind,
    int? speed,
    int? volume,
    int? pitch,
    int? windowSize,
    int? windowMaxChars,
    int? maxTokens,
    double? temperature,
    int? maxRetries,
    int? mergeFileSizeMb,
    Object? outputRoot = _unset,
  }) {
    return AppSettings(
      llmKind: llmKind ?? this.llmKind,
      ttsKind: ttsKind ?? this.ttsKind,
      llmCredentialsByKind: llmCredentialsByKind ?? this.llmCredentialsByKind,
      ttsCredentialsByKind: ttsCredentialsByKind ?? this.ttsCredentialsByKind,
      voiceByKind: voiceByKind ?? this.voiceByKind,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      pitch: pitch ?? this.pitch,
      windowSize: windowSize ?? this.windowSize,
      windowMaxChars: windowMaxChars ?? this.windowMaxChars,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      maxRetries: maxRetries ?? this.maxRetries,
      mergeFileSizeMb: mergeFileSizeMb ?? this.mergeFileSizeMb,
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
      tts: TTSConfig(
        voice: voiceFor(ttsKind),
        speed: speed,
        volume: volume,
        pitch: pitch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'llmKind': llmKind.name,
        'ttsKind': ttsKind.name,
        'llmCredentialsByKind': llmCredentialsByKind,
        'ttsCredentialsByKind': ttsCredentialsByKind,
        'voiceByKind': voiceByKind,
        'speed': speed,
        'volume': volume,
        'pitch': pitch,
        'windowSize': windowSize,
        'windowMaxChars': windowMaxChars,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'maxRetries': maxRetries,
        'mergeFileSizeMb': mergeFileSizeMb,
        'outputRoot': outputRoot,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final llmKind =
        LLMKind.values.asNameMap()[json['llmKind']] ?? LLMKind.deepSeek;
    final ttsKind =
        TTSKind.values.asNameMap()[json['ttsKind']] ?? TTSKind.xunfei;

    // —— 凭据迁移：新格式按提供商分组的 map 优先；旧格式（单 map / 扁平
    // 字段）迁移到当前所选提供商名下，保证升级后原凭据不丢失。 ——
    Map<String, Map<String, String>> readCredentialsByKind(
      String newKey,
      String legacyKey,
      Map<String, String> legacyFlatFields, {
      required String kindName,
    }) {
      final byKind = <String, Map<String, String>>{};
      final raw = json[newKey];
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.value is Map) {
            byKind['${entry.key}'] =
                Map<String, String>.from(entry.value as Map);
          }
        }
      }
      if (byKind.isEmpty) {
        final legacy = <String, String>{};
        final rawLegacy = json[legacyKey];
        if (rawLegacy is Map) {
          for (final entry in rawLegacy.entries) {
            if (entry.value is String) {
              legacy['${entry.key}'] = entry.value as String;
            }
          }
        }
        if (legacy.isEmpty) {
          for (final entry in legacyFlatFields.entries) {
            final value = json[entry.key] as String? ?? '';
            if (value.isNotEmpty) legacy[entry.value] = value;
          }
        }
        if (legacy.isNotEmpty) byKind[kindName] = legacy;
      }
      return byKind;
    }

    final llmCredentialsByKind = readCredentialsByKind(
      'llmCredentialsByKind',
      'llmCredentials',
      {'llmApiKey': 'apiKey'},
      kindName: llmKind.name,
    );
    final ttsCredentialsByKind = readCredentialsByKind(
      'ttsCredentialsByKind',
      'ttsCredentials',
      {
        'ttsAppId': 'appId',
        'ttsApiKey': 'apiKey',
        'ttsApiSecret': 'apiSecret',
      },
      kindName: ttsKind.name,
    );

    // —— 音色迁移：新格式按提供商分组的 map 优先；旧格式 voice 迁移到
    // 当前所选 TTS 提供商名下。 ——
    final voiceByKind = <String, String>{};
    final rawVoiceByKind = json['voiceByKind'];
    if (rawVoiceByKind is Map) {
      for (final entry in rawVoiceByKind.entries) {
        if (entry.value is String) {
          voiceByKind['${entry.key}'] = entry.value as String;
        }
      }
    }
    if (voiceByKind.isEmpty) {
      final legacyVoice = json['voice'] as String?;
      if (legacyVoice != null && legacyVoice.isNotEmpty) {
        voiceByKind[ttsKind.name] = legacyVoice;
      }
    }

    return AppSettings(
      llmKind: llmKind,
      ttsKind: ttsKind,
      llmCredentialsByKind: llmCredentialsByKind,
      ttsCredentialsByKind: ttsCredentialsByKind,
      voiceByKind: voiceByKind,
      speed: json['speed'] as int? ?? 50,
      volume: json['volume'] as int? ?? 50,
      pitch: json['pitch'] as int? ?? 50,
      windowSize: json['windowSize'] as int? ?? 2,
      windowMaxChars: json['windowMaxChars'] as int? ?? 15000,
      maxTokens: json['maxTokens'] as int? ?? 1500,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      maxRetries: json['maxRetries'] as int? ?? 3,
      mergeFileSizeMb: json['mergeFileSizeMb'] as int? ?? 100,
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
