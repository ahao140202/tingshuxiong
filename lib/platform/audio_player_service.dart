import 'package:audioplayers/audioplayers.dart';

/// 音频播放抽象：UI 层与 AppState 仅依赖本接口，便于测试注入假实现。
abstract class AudioPlayback {
  /// 播放状态流（playing / paused / stopped ...）。
  Stream<PlayerState> get stateStream;

  /// 播放位置流。
  Stream<Duration> get positionStream;

  /// 音频总时长流。
  Stream<Duration> get durationStream;

  /// 播放完成事件（音频自然播放到结尾时触发一次，用于自动连播）。
  Stream<void> get completeStream;

  /// 当前是否正在播放。
  bool get isPlaying;

  /// 播放本地音频文件（替换当前播放内容）。
  Future<void> playFile(String path);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> seek(Duration position);
}

/// 本地音频播放实现（Windows 基于 Media Foundation）。
class AudioPlayerService implements AudioPlayback {
  AudioPlayerService();

  final AudioPlayer _player = AudioPlayer();

  /// 播放状态流（playing / paused / stopped ...）。
  @override
  Stream<PlayerState> get stateStream => _player.onPlayerStateChanged;

  @override
  Stream<Duration> get positionStream => _player.onPositionChanged;

  @override
  Stream<Duration> get durationStream => _player.onDurationChanged;

  @override
  Stream<void> get completeStream => _player.onPlayerComplete;

  @override
  bool get isPlaying => _player.state == PlayerState.playing;

  @override
  Future<void> playFile(String path) {
    return _player.play(DeviceFileSource(path));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> dispose() => _player.dispose();
}
