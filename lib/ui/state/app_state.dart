import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/domain/domain.dart';
import '../../core/facade/facade.dart';
import '../../platform/platform.dart';

/// 应用全局状态：持有引擎、设置、数据库、当前书与播放状态。
///
/// 引擎的 bookStream 会持续把章节状态变化同步到 UI，同时：
/// - 整书（书 + 章节状态）落 SQLite，启动时恢复上次打开的书；
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

  /// 书架上的全部书籍（按导入时间倒序，与数据库一致）。
  List<Book> _books = [];
  bool _initialized = false;
  int _playingIndex = -1;
  bool _playing = false;

  Duration _lastPosition = Duration.zero;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  AppSettings get settings => _settings;

  Book? get book => _book;

  /// 书架书籍列表（只读视图）：最新导入的排最前。
  List<Book> get books => List.unmodifiable(_books);

  bool get initialized => _initialized;

  /// 正在播放的章节（无播放时为 -1）。
  int get playingIndex => _playingIndex;

  bool get isPlaying => _playing;

  bool get isGenerating => _engine.isRunning;

  /// 是否可启动生成（凭据齐全且有书）。
  bool get canGenerate => _settings.hasCredentials && _book != null;

  Stream<PlayerState> get playerStateStream => _player.stateStream;

  /// UI 播放位置流控制器：与节流逻辑分离，便于 seek 后强制推送位置。
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  /// 播放位置流（UI 用，已节流）：audioplayers 约 200ms 发射一次，
  /// 节流到约 500ms，降低 UI 重建频率与 Windows 无障碍语义树更新压力。
  /// 用普通回调节流而非 async* 转换器：broadcast 源在转换器暂停时
  /// 不缓冲事件，回调模式可保证首个事件必达、后续按节流窗口放行。
  late final Stream<Duration> _positionUi = () {
    _player.positionStream.listen((position) {
      final now = DateTime.now();
      if (now.difference(_lastPositionEmit) >=
          const Duration(milliseconds: 500)) {
        _lastPositionEmit = now;
        _positionController.add(position);
      }
    });
    return _positionController.stream;
  }();

  /// 节流窗口起点：上次放行（或强制推送）位置事件的时刻。
  DateTime _lastPositionEmit = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<Duration> get playerPositionStream => _positionUi;

  Stream<Duration> get playerDurationStream => _player.durationStream;

  /// 把位置立即推送到 UI 流并重置节流窗口（绕过节流）。
  ///
  /// 用途：seek 后播放器上报的位置事件可能落在节流窗口内被吞掉
  /// （暂停时甚至不发射），若不强制推送会导致正文高亮与进度条滞后。
  void _emitPosition(Duration position) {
    _lastPositionEmit = DateTime.now();
    _positionController.add(position);
  }

  /// 加载持久化设置、打开数据库并恢复上次的书；启动时调用一次。
  Future<void> init() async {
    _settings = await _settingsStore.load();
    _audioStore.setRoot(_settings.outputRoot);
    _configureEngine();
    // 打开数据库并恢复书架全部书籍与上次打开的书（章节状态与文件路径均在库中）。
    final database = _database;
    if (database != null) {
      try {
        await database.init();
        _books = await database.loadBooks();
        final restored = await database.loadLatestBook();
        if (restored != null) {
          _book = restored;
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
    // 书架列表立即更新（新书置顶、同 id 覆盖去重），随后按数据库
    // 导入时间序校正（同名覆盖时保持首次导入位置，跨会话顺序一致）。
    _books = [book, ..._books.where((b) => b.id != book.id)];
    notifyListeners();
    unawaited(_persistBook(book));
    unawaited(_refreshBooks());
  }

  /// 书架点击书籍：切换当前书（章节状态从数据库加载的实例），不重新导入。
  void openBook(Book book) {
    if (_book?.id == book.id) return;
    _book = book;
    _playingIndex = -1;
    notifyListeners();
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

  /// 章节级重新生成：仅生成本章节（单章生成，不进入窗口循环、
  /// 不涉及其他章节改动），用于失败章节重试。
  Future<void> regenerateChapter(int index) async {
    await _engine.generateChapter(index);
    _syncBook();
  }

  /// 离线缓存入口：从最后一个已生成章节的下一章起整本生成（不受
  /// 预加载窗口限制，窗口循环推进直到全部完成）。
  ///
  /// - 已有生成记录：从最后一个已生成章节之后继续（跳过已生成、
  ///   不覆盖；其之前的失败/取消章节保持原状，可由章节卡片单独重试）；
  /// - 无生成记录：从第 1 章开始整本生成；
  /// - 全部章节均已生成：返回 false（调用方提示无需继续）。
  Future<bool> generateOrContinue() async {
    final book = _book;
    if (book == null || !_settings.hasCredentials) return false;
    var lastGenerated = -1;
    for (var i = 0; i < book.chapterCount; i++) {
      if (book.chapterAt(i).status == ChapterStatus.generated) {
        lastGenerated = i;
      }
    }
    final startIndex = lastGenerated + 1; // 无记录时从 0 开始整本生成
    if (startIndex >= book.chapterCount) return false; // 全部完成
    if (!_engine.isConfigured) _configureEngine();
    await _engine.start(book, fromIndex: startIndex);
    _syncBook();
    return true;
  }

  /// 全部清空：删除本小说所有章节的已生成文件（音频/改写稿），重置全部
  /// 章节状态为未生成（不触发生成），供「离线缓存」从头再来。
  ///
  /// 文件删除失败会抛出异常（调用方负责提示），不继续删除避免残留
  /// 旧文件与状态不一致。
  Future<void> clearAll() async {
    final book = _book;
    if (book == null) return;

    var updated = book;
    for (var i = 0; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      await _audioStore.deleteChapterFiles(
        audioPath: chapter.audioPath,
        rewritePath: chapter.rewritePath,
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
    notifyListeners();
    await _persistBook(updated);
  }

  /// 删除小说：先停止可能进行中的生成（避免引擎回调把已删的书重新
  /// 写回），清理该书全部已生成文件（章节记录的旧路径覆盖切换过
  /// 根目录的历史文件 + 当前根目录的书目录），再移除数据库记录与
  /// 书架项；删除的是当前书时同时复位。
  ///
  /// 文件删除失败抛异常（调用方负责提示），不继续删除避免残留；
  /// 数据库删除失败静默（与落库失败策略一致，下次启动会恢复记录）。
  Future<void> deleteBook(String id) async {
    final candidates = _books.where((b) => b.id == id).toList();
    if (candidates.isEmpty) return;
    final book = candidates.first;
    if (_engine.isConfigured) {
      try {
        await _engine.stop();
      } catch (_) {
        // 停止失败不阻塞删除（生成回调随后会被状态清理覆盖）。
      }
    }
    for (var i = 0; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      await _audioStore.deleteChapterFiles(
        audioPath: chapter.audioPath,
        rewritePath: chapter.rewritePath,
      );
    }
    await _audioStore.deleteBookFiles(book.id);
    final database = _database;
    if (database != null) {
      try {
        await database.deleteBook(id);
      } catch (_) {
        // 数据库不可用时仍从内存移除，避免卡住书架操作。
      }
    }
    _books = _books.where((b) => b.id != id).toList();
    if (_book?.id == id) {
      _book = null;
      _playingIndex = -1;
    }
    notifyListeners();
  }

  /// 引擎状态流回调：更新内存书并整书落库。
  void _onBookChanged(Book book) {
    _book = book;
    notifyListeners();
    final database = _database;
    if (database == null) return;
    unawaited(_persistBook(book));
  }

  /// 整书落库（书 + 章节状态），失败静默忽略（不阻塞 UI）。
  Future<void> _persistBook(Book book) async {
    try {
      await _database?.saveBook(book);
    } catch (_) {
      // 落库失败不中断主流程。
    }
  }

  /// 从数据库重载书架列表（导入后校正导入时间排序），失败时保留内存列表。
  Future<void> _refreshBooks() async {
    final database = _database;
    if (database == null) return;
    try {
      _books = await database.loadBooks();
      notifyListeners();
    } catch (_) {
      // 数据库不可用时保留内存列表。
    }
  }

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

  /// 聚合并导出：把全部已生成章节音频按顺序打包为不超过
  /// [mergeFileSizeMb]（设置项，默认 100MB）的大文件，导出到所选目录。
  Future<AudioMergeResult> mergeExportAudio() async {
    final book = _book;
    if (book == null) {
      throw StateError('尚未导入书籍');
    }
    return _audioExporter.mergeBook(book, maxSizeMb: _settings.mergeFileSizeMb);
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

  /// 跳转播放位置：先把目标位置同步到 UI 流，再通知播放器 seek。
  ///
  /// 顺序上先推送 UI 再 await 播放器：拖动进度条时 UI 即时反馈，
  /// 且播放器 seek 失败（底层引擎异常）不向上抛，避免拖动导致崩溃；
  /// 播放中播放器后续位置事件会自然纠正偏差。
  Future<void> seek(Duration position) async {
    _lastPosition = position;
    _emitPosition(position);
    try {
      await _player.seek(position);
    } catch (_) {
      // 播放器 seek 失败不影响应用运行（仅本次跳转未生效）。
    }
  }

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
