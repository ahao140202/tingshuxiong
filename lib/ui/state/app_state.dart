import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/domain/domain.dart';
import '../../core/facade/facade.dart';
import '../../platform/platform.dart';

/// 应用全局状态：持有引擎、设置、数据库、当前书与播放状态。
///
/// 引擎的 bookStream 会持续把章节状态变化同步到 UI，同时：
/// - 整书（书 + 章节状态）落 SQLite，启动时恢复上次打开的书；
/// - 章节生成成功时写入快照表（便于后续回溯）；
/// - 播放进度按 5 秒节流写入数据库。
class AppState extends ChangeNotifier {
  AppState({
    required this._engine,
    required this._settingsStore,
    required this._audioStore,
    required this._filePicker,
    required this._player,
    AudioExporter? audioExporter,
    this._database,
  }) : _audioExporter = audioExporter ?? AudioExporter() {
    _player.stateStream.listen((state) {
      final playing = state == PlayerState.playing;
      if (playing != _playing) {
        _playing = playing;
        notifyListeners();
      }
    });
    // 自动连播：一章自然播放完成后按章节顺序继续下一章
    // （无音频时阻塞生成再播，最后一章播完停止）。
    _player.completeStream.listen((_) => _onChapterComplete());
    // 播放进度节流落库：每 5 秒保存一次当前章节进度（不触发 UI）。
    _player.positionStream.listen((position) {
      _lastPosition = position;
      final now = DateTime.now();
      if (now.difference(_lastProgressSave) >= const Duration(seconds: 5)) {
        _lastProgressSave = now;
        _saveProgress();
      }
    });
  }

  final TingEngine _engine;
  final SettingsStore _settingsStore;
  final AudioStore _audioStore;
  final TxtPicker _filePicker;
  final AudioPlayback _player;
  final AudioExporter _audioExporter;
  final BookDatabase? _database;

  AppSettings _settings = const AppSettings();
  Book? _book;
  bool _initialized = false;
  int _playingIndex = -1;
  bool _playing = false;

  /// 章节状态跟踪（`bookId:index` → 状态），用于检测「新生成成功」插入快照。
  final Map<String, ChapterStatus> _seenStatus = {};

  Duration _lastPosition = Duration.zero;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  AppSettings get settings => _settings;

  Book? get book => _book;

  bool get initialized => _initialized;

  /// 正在播放的章节（无播放时为 -1）。
  int get playingIndex => _playingIndex;

  bool get isPlaying => _playing;

  bool get isGenerating => _engine.isRunning;

  /// 是否可启动生成（凭据齐全且有书）。
  bool get canGenerate => _settings.hasCredentials && _book != null;

  Stream<PlayerState> get playerStateStream => _player.stateStream;

  /// 播放位置流（UI 用，已节流）：audioplayers 约 200ms 发射一次，
  /// 节流到约 500ms，降低 UI 重建频率与 Windows 无障碍语义树更新压力。
  /// 用普通回调节流而非 async* 转换器：broadcast 源在转换器暂停时
  /// 不缓冲事件，回调模式可保证首个事件必达、后续按节流窗口放行。
  late final Stream<Duration> _positionUi = () {
    final controller = StreamController<Duration>.broadcast();
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    _player.positionStream.listen((position) {
      final now = DateTime.now();
      if (now.difference(lastEmit) >= const Duration(milliseconds: 500)) {
        lastEmit = now;
        controller.add(position);
      }
    });
    return controller.stream;
  }();

  Stream<Duration> get playerPositionStream => _positionUi;

  Stream<Duration> get playerDurationStream => _player.durationStream;

  /// 加载持久化设置、打开数据库并恢复上次的书；启动时调用一次。
  Future<void> init() async {
    _settings = await _settingsStore.load();
    _audioStore.setRoot(_settings.outputRoot);
    _configureEngine();
    // 打开数据库并恢复上次打开的书（章节状态与文件路径均在库中）。
    final database = _database;
    if (database != null) {
      try {
        await database.init();
        final restored = await database.loadLatestBook();
        if (restored != null) {
          _book = restored;
          _trackStatuses(restored);
        }
      } catch (_) {
        // 数据库不可用时降级为内存运行，不影响主流程。
      }
    }
    _initialized = true;
    notifyListeners();
    _engine.bookStream.listen(_onBookChanged);
  }

  /// 选择并导入 txt 小说。
  Future<void> importBook() async {
    final file = await _filePicker.pick();
    if (file == null) return;
    final book = _engine.importBook(
      id: file.name,
      title: file.name,
      fullText: file.content,
    );
    _book = book;
    _playingIndex = -1;
    _trackStatuses(book);
    notifyListeners();
    unawaited(_persistBook(book));
  }

  /// 保存并应用设置（重新装配引擎、切换输出根目录）。
  Future<void> applySettings(AppSettings newSettings) async {
    _settings = newSettings;
    _audioStore.setRoot(newSettings.outputRoot);
    _configureEngine();
    notifyListeners();
    await _settingsStore.save(newSettings);
  }

  void _configureEngine() {
    _engine.configure(
      llmKind: _settings.llmKind,
      llmCredentials: _settings.llmCredentials,
      ttsKind: _settings.ttsKind,
      ttsCredentials: _settings.ttsCredentials,
      config: _settings.toEngineConfig(),
      saveAudio: _audioStore.saveAudio,
      saveRewrite: _audioStore.saveRewrite,
      maxRetries: _settings.maxRetries,
    );
  }

  /// 从当前进度启动生成。
  Future<void> generate() async {
    final book = _book;
    if (book == null || !_settings.hasCredentials) return;
    if (!_engine.isConfigured) _configureEngine();
    await _engine.start(book);
    _syncBook();
  }

  /// 停止生成（进行中章节标记为 cancelled）。
  Future<void> stopGenerating() async {
    await _engine.stop();
    _syncBook();
  }

  /// 跳转到指定章节并从该章重新生成（用于失败章节重试 / 手动跳章）。
  Future<void> regenerateChapter(int index) async {
    await _engine.jumpTo(index);
    _syncBook();
  }

  /// 继续生成：从第一个未完成章节（未生成/失败/已取消）开始，
  /// 已生成章节自动跳过、不覆盖已有内容；全部已完成时返回 false。
  Future<bool> continueGenerate() async {
    final book = _book;
    if (book == null || !_settings.hasCredentials) return false;
    var startIndex = 0;
    while (startIndex < book.chapterCount &&
        !book.chapterAt(startIndex).status.isRunnable) {
      startIndex++;
    }
    if (startIndex >= book.chapterCount) return false; // 全部完成
    if (!_engine.isConfigured) _configureEngine();
    await _engine.start(book, fromIndex: startIndex);
    _syncBook();
    return true;
  }

  /// 从 [index] 章开始按当前配置重新生成：
  /// 先将该章及之后章节的旧生成文件（音频/改写稿）转移到历史目录并更新
  /// 快照路径，再重置章节状态，最后从该章重新调度生成。
  ///
  /// 文件转移失败会抛出异常（调用方负责提示），不继续生成避免覆盖丢失。
  Future<void> regenerateFrom(int index) async {
    final book = _book;
    if (book == null) return;
    index = index.clamp(0, book.chapterCount - 1);

    var updated = book;
    for (var i = index; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      final moved = await _audioStore.moveToHistory(
        book.id,
        i,
        audioPath: chapter.audioPath,
        rewritePath: chapter.rewritePath,
      );
      await _database?.updateSnapshotPaths(
        book.id,
        i,
        audioPath: moved.audioPath,
        rewritePath: moved.rewritePath,
      );
      updated = updated.replaceChapter(
        i,
        chapter.copyWith(
          status: ChapterStatus.notGenerated,
          rewrittenText: null,
          rewritePath: null,
          audioPath: null,
          errorMessage: null,
        ),
      );
    }
    _book = updated;
    _trackStatuses(updated);
    notifyListeners();

    // 按最新配置从该章开始重新生成。
    if (!_engine.isConfigured) _configureEngine();
    await _engine.start(updated, fromIndex: index);
    _syncBook();
  }

  /// 引擎状态流回调：更新内存书、整书落库、检测生成成功插入快照。
  void _onBookChanged(Book book) {
    _book = book;
    notifyListeners();
    final database = _database;
    if (database == null) return;
    unawaited(_persistBook(book));
    for (var i = 0; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      final key = '${book.id}:$i';
      final was = _seenStatus[key];
      if (chapter.status == ChapterStatus.generated &&
          was != ChapterStatus.generated) {
        unawaited(database.insertSnapshot(
          bookId: book.id,
          chapterIndex: i,
          status: chapter.status.name,
          audioPath: chapter.audioPath,
          rewritePath: chapter.rewritePath,
          ttsConfigJson: _ttsConfigJson(),
        ));
      }
      _seenStatus[key] = chapter.status;
    }
  }

  /// 整书落库（书 + 章节状态），失败静默忽略（不阻塞 UI）。
  Future<void> _persistBook(Book book) async {
    try {
      await _database?.saveBook(book);
    } catch (_) {
      // 落库失败不中断主流程。
    }
  }

  /// 当前 TTS 配置的 JSON 摘要（快照回溯用）。
  String _ttsConfigJson() => jsonEncode({
        'voice': _settings.voice,
        'speed': _settings.speed,
        'volume': _settings.volume,
        'pitch': _settings.pitch,
      });

  /// 把当前播放进度写入数据库（不触发 UI）。
  void _saveProgress() {
    final book = _book;
    final database = _database;
    if (book == null || database == null || _playingIndex < 0) return;
    unawaited(
      database
          .updateProgress(book.id, _playingIndex, _lastPosition)
          .catchError((_) {}),
    );
  }

  void _trackStatuses(Book book) {
    for (var i = 0; i < book.chapterCount; i++) {
      _seenStatus['${book.id}:$i'] = book.chapterAt(i).status;
    }
  }

  /// 调度控制返回后同步引擎最新状态（广播流事件可能仍在派发中）。
  void _syncBook() {
    final latest = _engine.book;
    if (latest != null) {
      _book = latest;
      notifyListeners();
    }
  }

  /// 导出全部已生成章节音频（桌面端选目录，移动端导出到文档目录）。
  Future<AudioExportResult> exportAudio() async {
    final book = _book;
    if (book == null) {
      throw StateError('尚未导入书籍');
    }
    return _audioExporter.exportBook(book);
  }

  /// 播放指定章节音频。
  Future<void> playChapter(int index) async {
    final book = _book;
    if (book == null) return;
    final chapter = book.chapterAt(index);
    if (!chapter.hasAudio) return;
    _saveProgress();
    _playingIndex = index;
    notifyListeners();
    await _player.playFile(chapter.audioPath!);
  }

  /// 点击播放章节：本地无音频时先同步生成该章，生成成功后立即播放，
  /// 随后按预加载窗口逻辑后台生成后续章节（保证连续播放）。
  ///
  /// 生成失败时返回 false（调用方负责提示）。
  Future<bool> playOrGenerate(int index) async {
    final book = _book;
    if (book == null) return false;
    if (index < 0 || index >= book.chapterCount) return false;
    _saveProgress();
    _playingIndex = index;
    notifyListeners();

    var chapter = book.chapterAt(index);
    if (!chapter.hasAudio) {
      if (!_settings.hasCredentials) return false;
      if (!_engine.isConfigured) _configureEngine();
      // 传入当前书：首次播放时调度器尚未装载书籍，必须带上才能处理。
      await _engine.generateChapter(index, book: book);
      _syncBook();
      chapter = _book!.chapterAt(index);
      if (!chapter.hasAudio) return false; // 生成失败
    }
    await _player.playFile(chapter.audioPath!);

    // 预加载窗口：从下一章起按窗口配置后台生成（仅窗口内章节，
    // 不整本生成，窗口大小真正生效），不阻塞播放。
    final bookNow = _book!;
    if (index + 1 < bookNow.chapterCount) {
      unawaited(
        _engine
            .preloadWindow(bookNow, fromIndex: index + 1)
            .then((_) => _syncBook()),
      );
    }
    return true;
  }

  /// 播放 / 暂停切换；暂停时补存一次进度。
  Future<void> togglePlay() async {
    if (_playing) {
      await _player.pause();
      _saveProgress();
    } else if (_playingIndex >= 0 && _book != null) {
      await _player.resume();
    }
  }

  Future<void> seek(Duration position) => _player.seek(position);

  /// 自动连播：当前章播放完成后按章节顺序继续下一章。
  /// 下一章无音频时阻塞等待生成完成再播（复用 [playOrGenerate]，
  /// 同时按预加载窗口后台生成后续章节）；最后一章播完即停。
  Future<void> _onChapterComplete() async {
    final book = _book;
    if (book == null || _playingIndex < 0) return;
    _saveProgress();
    final next = _playingIndex + 1;
    if (next >= book.chapterCount) return; // 最后一章播完，停止连播
    await playOrGenerate(next);
  }
}
