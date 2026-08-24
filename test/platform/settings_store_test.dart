import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/platform/platform.dart';

void main() {
  late Directory tempDir;
  late File settingsFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_store_test');
    settingsFile = File('${tempDir.path}${Platform.pathSeparator}settings.json');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('AppSettings', () {
    test('默认值', () {
      const settings = AppSettings();
      expect(settings.hasCredentials, isFalse);
      expect(settings.llmKind, LLMKind.deepSeek);
      expect(settings.ttsKind, TTSKind.xunfei);
      expect(settings.llmCredentials, isEmpty);
      expect(settings.ttsCredentials, isEmpty);
      expect(settings.voice, 'xiaoyan');
      expect(settings.windowSize, 2);
      expect(settings.windowMaxChars, 15000);
      expect(settings.maxTokens, 1500);
      expect(settings.temperature, 0.7);
      expect(settings.maxRetries, 3);
      expect(settings.outputRoot, isNull);
      expect(settings.toEngineConfig().llmKind, LLMKind.deepSeek);
      expect(settings.toEngineConfig().ttsKind, TTSKind.xunfei);
      expect(settings.toEngineConfig().tts.voice, 'xiaoyan');
    });

    test('hasCredentials 按所选提供商字段校验，全齐才为 true', () {
      const partial = AppSettings(llmCredentials: {'apiKey': 'sk-1'});
      expect(partial.hasCredentials, isFalse);
      const full = AppSettings(
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {'appId': 'a', 'apiKey': 'k', 'apiSecret': 's'},
      );
      expect(full.hasCredentials, isTrue);
      // 缺少所选提供商任一必填字段即为 false
      const missingSecret = AppSettings(
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {'appId': 'a', 'apiKey': 'k'},
      );
      expect(missingSecret.hasCredentials, isFalse);
    });

    test('copyWith 保留未修改字段', () {
      const base = AppSettings(
        llmCredentials: {'apiKey': 'sk-1'},
        speed: 70,
      );
      final updated = base.copyWith(speed: 80);
      expect(updated.llmCredentials, {'apiKey': 'sk-1'});
      expect(updated.speed, 80);
      expect(updated.volume, 50);
      expect(updated.llmKind, LLMKind.deepSeek);
      // outputRoot 未修改时保留，显式传 null 清除。
      final withRoot = base.copyWith(outputRoot: '/out');
      expect(withRoot.outputRoot, '/out');
      expect(withRoot.copyWith(outputRoot: null).outputRoot, isNull);
    });

    test('toEngineConfig 映射参数', () {
      const settings = AppSettings(
        llmKind: LLMKind.deepSeek,
        ttsKind: TTSKind.xunfei,
        windowSize: 4,
        windowMaxChars: 9000,
        maxTokens: 1000,
        temperature: 0.5,
        voice: 'aisjiu',
        speed: 65,
        volume: 40,
        pitch: 55,
      );
      final config = settings.toEngineConfig();
      expect(config.llmKind, LLMKind.deepSeek);
      expect(config.ttsKind, TTSKind.xunfei);
      expect(config.windowSize, 4);
      expect(config.windowMaxChars, 9000);
      expect(config.maxTokens, 1000);
      expect(config.temperature, 0.5);
      expect(config.tts.voice, 'aisjiu');
      expect(config.tts.speed, 65);
      expect(config.tts.volume, 40);
      expect(config.tts.pitch, 55);
    });

    test('JSON round-trip', () {
      const settings = AppSettings(
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {'appId': 'app', 'apiKey': 'key', 'apiSecret': 'secret'},
        voice: 'aisjiu',
        speed: 60,
        windowSize: 3,
        temperature: 0.4,
        outputRoot: 'D:/books/generated',
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.toJson(), settings.toJson());
      expect(restored.outputRoot, 'D:/books/generated');
    });

    test('旧版扁平凭据字段 JSON 迁移到凭据映射', () {
      final old = AppSettings.fromJson({
        'llmApiKey': 'sk-old',
        'ttsAppId': 'app-old',
        'ttsApiKey': 'key-old',
        'ttsApiSecret': 'secret-old',
        'speed': 60,
      });
      expect(old.llmCredentials, {'apiKey': 'sk-old'});
      expect(old.ttsCredentials,
          {'appId': 'app-old', 'apiKey': 'key-old', 'apiSecret': 'secret-old'});
      expect(old.speed, 60);
      // 新结构优先于旧字段
      final migrated = AppSettings.fromJson({
        'llmCredentials': {'apiKey': 'sk-new'},
        'llmApiKey': 'sk-old',
        'ttsCredentials': {'appId': 'a-new'},
        'ttsAppId': 'a-old',
      });
      expect(migrated.llmCredentials, {'apiKey': 'sk-new'});
      expect(migrated.ttsCredentials, {'appId': 'a-new'});
    });
  });

  group('SettingsStore', () {
    SettingsStore makeStore() => SettingsStore(fileProvider: () async => settingsFile);

    test('文件不存在时返回默认设置', () async {
      final settings = await makeStore().load();
      expect(settings.llmCredentials, isEmpty);
      expect(settings.speed, 50);
    });

    test('save 后 load 还原', () async {
      final store = makeStore();
      const settings = AppSettings(
        llmCredentials: {'apiKey': 'sk-1'},
        ttsCredentials: {'appId': 'app', 'apiKey': 'k', 'apiSecret': 's'},
        speed: 80,
      );
      await store.save(settings);

      final restored = await makeStore().load();
      expect(restored.llmCredentials, {'apiKey': 'sk-1'});
      expect(restored.ttsCredentials,
          {'appId': 'app', 'apiKey': 'k', 'apiSecret': 's'});
      expect(restored.speed, 80);
      expect(restored.toJson(), settings.toJson());
    });

    test('损坏 JSON 回退默认且不抛异常', () async {
      await settingsFile.writeAsString('{not valid json');
      final settings = await makeStore().load();
      expect(settings, const AppSettings());
    });

    test('未知字段不影响加载', () async {
      await settingsFile.writeAsString(
        jsonEncode({'llmCredentials': {'apiKey': 'sk-x'}, 'unknownField': 123}),
      );
      final settings = await makeStore().load();
      expect(settings.llmCredentials, {'apiKey': 'sk-x'});
      expect(settings.speed, 50);
    });
  });
}
