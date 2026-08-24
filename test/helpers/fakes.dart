import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/llm/llm.dart';
import 'package:tingshuxiong/core/tts/tts.dart';
import 'package:tingshuxiong/platform/platform.dart';

/// 可配置失败次数与门控的假 LLM。
///
/// - [failures]：前 N 次调用抛 [LLMException]；
/// - [failOnCalls]：指定调用序号失败（与 [failures] 叠加），
///   用于精确制造「某章失败、其余成功」的场景（如继续生成测试）；
/// - [gate]：非空时每次调用等待 gate 完成（模拟进行中的改写请求）。
class FakeLLM implements LLMProvider {
  FakeLLM({this.failures = 0, this.gate, this.failOnCalls = const {}});

  final int failures;
  final Completer<String>? gate;
  final Set<int> failOnCalls;

  int calls = 0;
  final List<String> titles = [];

  /// 首次调用开始时完成（用于测试等待任务真正启动）。
  final Completer<void> firstCallStarted = Completer<void>();

  @override
  LLMKind get kind => LLMKind.deepSeek;

  @override
  String get model => 'fake-llm';

  @override
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  }) async {
    calls++;
    titles.add(title);
    if (!firstCallStarted.isCompleted) firstCallStarted.complete();
    final g = gate;
    if (g != null) return g.future;
    if (calls <= failures || failOnCalls.contains(calls)) {
      throw LLMException('模拟改写失败');
    }
    return '改写：$title';
  }
}

/// 假 TTS：前 [failures] 次调用抛 [TTSException]。
class FakeTTS implements TTSProvider {
  FakeTTS({this.failures = 0});

  final int failures;
  int calls = 0;
  final List<String> texts = [];

  @override
  TTSKind get kind => TTSKind.xunfei;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required TTSConfig config,
  }) async {
    calls++;
    texts.add(text);
    if (calls <= failures) throw TTSException('模拟合成失败');
    return Uint8List.fromList(utf8.encode('audio:$text'));
  }
}

/// 总是返回 [FakeLLM] 实例的注册表；[provider] 非空时固定返回该实例。
class FakeLLMRegistry extends LLMRegistry {
  const FakeLLMRegistry([this.provider]);

  final FakeLLM? provider;

  @override
  LLMProvider providerFor(
    LLMKind kind, {
    required Map<String, String> credentials,
  }) {
    return provider ?? FakeLLM();
  }
}

/// 总是返回 [FakeTTS] 实例的注册表。
class FakeTTSRegistry extends TTSRegistry {
  const FakeTTSRegistry();

  @override
  TTSProvider providerFor(
    TTSKind kind, {
    required Map<String, String> credentials,
  }) {
    return FakeTTS();
  }
}

/// 文件选择桩：固定返回 [file]。
class FakeTxtPicker implements TxtPicker {
  FakeTxtPicker(this.file);

  final TxtFile? file;

  @override
  Future<TxtFile?> pick() async => file;
}

/// 音频播放桩：记录调用并发射状态事件（模拟真实播放器行为）。
class FakeAudio implements AudioPlayback {
  final StreamController<PlayerState> _state =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast();
  final StreamController<void> _complete =
      StreamController<void>.broadcast();

  String? playedPath;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  int seekCalls = 0;

  bool _playing = false;

  @override
  Stream<PlayerState> get stateStream => _state.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<void> get completeStream => _complete.stream;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> playFile(String path) async {
    playedPath = path;
    _playing = true;
    _state.add(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
    _state.add(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    _playing = true;
    _state.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    _state.add(PlayerState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
  }

  /// 模拟播放位置更新（测试用）。
  void emitPosition(Duration position) => _position.add(position);

  /// 模拟播放完成（自动连播测试用）。
  void emitComplete() => _complete.add(null);
}
