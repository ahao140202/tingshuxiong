import 'dart:async';
import 'dart:typed_data';

import '../domain/domain.dart';
import '../llm/llm.dart';
import '../tts/tts.dart';

/// 智能调度器：按预加载窗口逐章执行「LLM 口语化改写 → TTS 合成 → 落盘」。
///
/// 状态机流转见 [ChapterStatus]（`notGenerated -> rewriting -> synthesizing -> generated`）；
/// 单章失败自动重试 [maxRetries] 次后标记 `failed`；
/// 跳章（[jumpTo]）或停止（[stop]）通过世代号（epoch）机制中止进行中的章节，
/// 被取消的章节标记为 `cancelled`，已生成内容保留。
///
/// 音频落盘通过 [saveAudio] 回调注入，调度器本身不接触文件系统，便于单测。
/// 改写稿中间文件通过可选的 [saveRewrite] 回调落盘（返回文件路径），
/// 写盘失败不影响主流程（仅不记录路径）。
class SmartScheduler {
  SmartScheduler({
    required this.config,
    required this._llm,
    required this._tts,
    required this._saveAudio,
    this._saveRewrite,
    this.maxRetries = 3,
  });

  /// 引擎配置（窗口大小 / 字数上限 / LLM 参数 / TTS 参数）。
  final EngineConfig config;

  /// 单章失败后的最大重试次数（默认 3）。
  final int maxRetries;

  final LLMProvider _llm;
  final TTSProvider _tts;
  final Future<String> Function(String bookId, int chapterIndex, Uint8List audio)
      _saveAudio;

  /// 改写稿落盘回调（可空）：返回落盘路径；返回 null 或抛错时仅跳过记录。
  final Future<String?> Function(String bookId, int chapterIndex, String text)?
      _saveRewrite;

  /// 状态流采用同步派发（sync: true）：调用方 await start/stop 返回时，
  /// 所有状态事件已同步送达订阅者；否则异步派发会使事件滞留在待发队列，
  /// 被订阅取消（configure 重建转接）时丢失，UI 会错过中间态甚至终态。
  final StreamController<Book> _controller =
      StreamController<Book>.broadcast(sync: true);
  Book? _book;
  bool _running = false;
  final Map<int, int> _retries = {};
  int _epoch = 0;

  /// 是否正在生成。
  bool get isRunning => _running;

  /// 当前 Book（未启动时为 null）。
  Book? get book => _book;

  /// Book 状态流：章节状态 / 进度每次变化时发出最新实例。
  Stream<Book> get bookStream => _controller.stream;

  /// 计算预加载窗口：从 [startIndex] 起包含当前章及后续章节，
  /// 后续章节最多 [windowSize] 章，且窗口内累计字数不超过 [windowMaxChars]。
  ///
  /// [includeStart] 为 false 时窗口为纯后续章节（最多 [windowSize] 章，
  /// 不含起始章），用于播放时的预加载场景。
  static List<int> computeWindow({
    required int startIndex,
    required int chapterCount,
    required int windowSize,
    required int windowMaxChars,
    required int Function(int index) charCountOf,
    bool includeStart = true,
  }) {
    final indices = <int>[];
    var totalChars = 0;
    for (var i = startIndex; i < chapterCount; i++) {
      final chars = charCountOf(i);
      final fitsCount = indices.isEmpty ||
          (includeStart
              ? indices.length <= windowSize
              : indices.length < windowSize);
      final fitsChars = indices.isEmpty || totalChars + chars <= windowMaxChars;
      if (!fitsCount || !fitsChars) break;
      indices.add(i);
      totalChars += chars;
    }
    return indices;
  }

  /// 从 [book] 的 lastChapterIndex 开始生成；[fromIndex] 指定起始章节（跳章）。
  ///
  /// [fromIndex] 必须落在 `[0, chapterCount)` 内，否则抛 [ArgumentError]。
  Future<void> start(Book book, {int? fromIndex}) async {
    if (fromIndex != null &&
        (fromIndex < 0 || fromIndex >= book.chapterCount)) {
      throw ArgumentError.value(
        fromIndex,
        'fromIndex',
        '超出章节范围 [0, ${book.chapterCount})',
      );
    }
    if (_running) return;
    _running = true;
    _epoch++;
    _book = fromIndex != null
        ? book.withPosition(fromIndex, Duration.zero)
        : book;
    _retries.clear();
    _emit();

    // 记录本次任务的世代号：跳章/停止时世代号递增，
    // 本任务所有后续检查（含 finally 的 _running 复位）以世代号为准，
    // 避免与并发的新任务互相误杀。
    final myEpoch = _epoch;
    try {
      var index = _book!.lastChapterIndex;
      while (myEpoch == _epoch && index < _book!.chapterCount) {
        final window = computeWindow(
          startIndex: index,
          chapterCount: _book!.chapterCount,
          windowSize: config.windowSize,
          windowMaxChars: config.windowMaxChars,
          charCountOf: (i) => _book!.chapterAt(i).rawText.length,
        );
        for (final chapterIndex in window) {
          if (myEpoch != _epoch) break;
          await _processChapter(chapterIndex, myEpoch);
        }
        // 窗口处理完毕（含失败章节）后推进，避免死循环。
        index = window.last + 1;
      }
    } finally {
      if (myEpoch == _epoch) _running = false;
    }
  }

  /// 跳转到指定章节：取消当前任务并从该章重新调度。
  Future<void> jumpTo(int chapterIndex) async {
    if (_book == null) return;
    _epoch++;
    _running = false;
    _cancelInFlight();
    await start(_book!, fromIndex: chapterIndex);
  }

  /// 单章生成：取消当前任务，仅处理 [chapterIndex] 一章后返回
  /// （不进入窗口循环），用于「点击播放无音频时先生成再播」。
  ///
  /// [book] 非空时先装载该书（首次播放、尚未启动过窗口任务时
  /// scheduler 内部还没有 Book，必须传入）；与窗口任务共用世代号
  /// 机制：期间发起窗口生成/跳章会取消本任务。
  Future<void> generateChapter(int chapterIndex, {Book? book}) async {
    if (book != null) _book = book;
    if (_book == null) return;
    _epoch++;
    _running = false;
    _cancelInFlight();
    if (chapterIndex < 0 || chapterIndex >= _book!.chapterCount) {
      throw ArgumentError.value(chapterIndex, 'chapterIndex', '超出章节范围');
    }
    final myEpoch = _epoch;
    _running = true;
    try {
      await _processChapter(chapterIndex, myEpoch);
    } finally {
      if (myEpoch == _epoch) _running = false;
    }
  }

  /// 预加载窗口：仅处理 [fromIndex] 起的一个窗口（后续最多
  /// [config.windowSize] 章），处理完即停、不继续整本生成；
  /// 用于播放时按窗口配置预生成后续章节，窗口大小真正生效。
  Future<void> preloadWindow(Book book, {required int fromIndex}) async {
    if (_running) return;
    _running = true;
    _epoch++;
    _book = book.withPosition(fromIndex, Duration.zero);
    _retries.clear();
    _emit();

    final myEpoch = _epoch;
    try {
      final window = computeWindow(
        startIndex: fromIndex,
        chapterCount: _book!.chapterCount,
        windowSize: config.windowSize,
        windowMaxChars: config.windowMaxChars,
        charCountOf: (i) => _book!.chapterAt(i).rawText.length,
        includeStart: false,
      );
      for (final chapterIndex in window) {
        if (myEpoch != _epoch) break;
        await _processChapter(chapterIndex, myEpoch);
      }
    } finally {
      if (myEpoch == _epoch) _running = false;
    }
  }

  /// 停止生成：取消进行中的章节，已生成内容保留。
  Future<void> stop() async {
    _epoch++;
    _running = false;
    _cancelInFlight();
  }

  /// 将进行中的章节（rewriting / synthesizing）标记为 cancelled。
  void _cancelInFlight() {
    final book = _book;
    if (book == null) return;
    var updated = book;
    for (var i = 0; i < book.chapterCount; i++) {
      final chapter = book.chapterAt(i);
      if (chapter.status == ChapterStatus.rewriting ||
          chapter.status == ChapterStatus.synthesizing) {
        updated = updated.replaceChapter(
          i,
          chapter.copyWith(status: ChapterStatus.cancelled),
        );
      }
    }
    _book = updated;
    _emit();
  }

  /// 处理单章：改写 → 合成 → 落盘；异常按 [maxRetries] 重试。
  Future<void> _processChapter(int chapterIndex, int epoch) async {
    var chapter = _book!.chapterAt(chapterIndex);
    if (!chapter.status.isRunnable) return;

    try {
      _replaceChapter(
        chapterIndex,
        chapter.copyWith(status: ChapterStatus.rewriting),
      );
      final rewritten = await _llm.rewrite(
        title: chapter.title,
        rawText: chapter.rawText,
        maxTokens: config.maxTokens,
        temperature: config.temperature,
      );
      if (epoch != _epoch) return;

      // 改写稿作为中间文件落盘（失败不中断主流程，仅不记录路径）。
      String? rewritePath;
      final saveRewrite = _saveRewrite;
      if (saveRewrite != null) {
        try {
          rewritePath = await saveRewrite(_book!.id, chapterIndex, rewritten);
        } catch (_) {
          rewritePath = null;
        }
      }

      chapter = _book!.chapterAt(chapterIndex);
      _replaceChapter(
        chapterIndex,
        chapter.copyWith(
          rewrittenText: rewritten,
          rewritePath: rewritePath,
          status: ChapterStatus.synthesizing,
          errorMessage: null,
        ),
      );
      final audio = await _tts.synthesize(
        text: rewritten,
        config: config.tts,
      );
      if (epoch != _epoch) return;

      final path = await _saveAudio(_book!.id, chapterIndex, audio);
      if (epoch != _epoch) return;

      chapter = _book!.chapterAt(chapterIndex);
      _replaceChapter(
        chapterIndex,
        chapter.copyWith(audioPath: path, status: ChapterStatus.generated),
      );
    } on Exception catch (e) {
      // 世代号已变化：任务被跳章/停止取消，状态由 _cancelInFlight 负责。
      if (epoch != _epoch) return;
      final retries = (_retries[chapterIndex] ?? 0) + 1;
      _retries[chapterIndex] = retries;
      if (retries <= maxRetries) {
        // 当前处于 rewriting/synthesizing 中间态，先复位为可运行状态再重试。
        // 保留失败原因，若重试成功会被清空。
        final current = _book!.chapterAt(chapterIndex);
        _replaceChapter(
          chapterIndex,
          current.copyWith(
            status: ChapterStatus.notGenerated,
            errorMessage: '$e',
          ),
        );
        await _processChapter(chapterIndex, epoch);
      } else {
        final current = _book!.chapterAt(chapterIndex);
        _replaceChapter(
          chapterIndex,
          current.copyWith(status: ChapterStatus.failed, errorMessage: '$e'),
        );
      }
    }
  }

  void _replaceChapter(int index, Chapter chapter) {
    _book = _book!.replaceChapter(index, chapter);
    _emit();
  }

  void _emit() {
    _controller.add(_book!);
  }
}
