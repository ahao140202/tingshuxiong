import 'dart:async';
import 'dart:typed_data';

import '../domain/domain.dart';
import '../llm/llm.dart';
import '../scheduler/scheduler.dart';
import '../text/text.dart';
import '../tts/tts.dart';

/// 引擎门面：应用与核心层的统一入口。
///
/// 职责：
/// 1. 导入 txt 全文并切分为章节 [Book]；
/// 2. 持有 API 凭据，按 [EngineConfig] 装配 Provider 与 [SmartScheduler]；
/// 3. 对外暴露 Book 状态流与调度控制（start / stop / jumpTo）。
///
/// 音频落盘通过 [configure] 的 [saveAudio] 回调由调用方（platform 层）注入，
/// 门面本身不接触文件系统。
class TingEngine {
  TingEngine({
    this._llmRegistry = const LLMRegistry(),
    this._ttsRegistry = const TTSRegistry(),
    ChapterSplitter? splitter,
  }) : _splitter = splitter ?? ChapterSplitter();

  final LLMRegistry _llmRegistry;
  final TTSRegistry _ttsRegistry;
  final ChapterSplitter _splitter;

  SmartScheduler? _scheduler;
  StreamSubscription<Book>? _schedulerSub;

  /// 稳定对外提供的 Book 状态流：
  /// 每次 [configure] 重建调度器后自动转接，订阅方无需重新订阅。
  ///
  /// 同步派发（sync: true）：保证 await start() 返回时全部状态事件已送达，
  /// 且重建转接（cancel 旧订阅）时不会丢弃调度器滞留的待发事件。
  final StreamController<Book> _bookController =
      StreamController<Book>.broadcast(sync: true);

  /// 是否已配置（调用 [configure] 后为 true）。
  bool get isConfigured => _scheduler != null;

  /// 导入 txt 全文，切分为章节 [Book]。
  ///
  /// [id] 建议使用文件名，保证同一本书重复导入时路径稳定。
  Book importBook({
    required String id,
    required String title,
    required String fullText,
  }) {
    final chapters = _splitter.split(fullText);
    return Book(id: id, title: title, chapters: chapters);
  }

  /// 配置凭据并装配引擎；可重复调用以更换配置。
  ///
  /// [llmCredentials] / [ttsCredentials] 为凭据映射，键名见
  /// [LLMKind.credentialFields] / [TTSKind.credentialFields]；
  /// 新增提供商无需改动本签名，仅扩展枚举与注册表。
  /// [saveAudio] 负责将合成音频写入磁盘并返回文件路径，
  /// 由 platform 层实现（如写入应用数据目录）。
  /// [saveRewrite]（可空）负责将改写稿中间文件写入磁盘并返回路径，
  /// 失败时调度器仅跳过记录、不中断主流程。
  void configure({
    required LLMKind llmKind,
    required Map<String, String> llmCredentials,
    required TTSKind ttsKind,
    required Map<String, String> ttsCredentials,
    EngineConfig config = const EngineConfig(),
    required Future<String> Function(
      String bookId,
      int chapterIndex,
      Uint8List audio,
    )
    saveAudio,
    Future<String?> Function(
      String bookId,
      int chapterIndex,
      String text,
    )?
    saveRewrite,
    int maxRetries = 3,
  }) {
    final llm = _llmRegistry.providerFor(llmKind, credentials: llmCredentials);
    final tts = _ttsRegistry.providerFor(
      ttsKind,
      credentials: ttsCredentials,
    );
    // 停止旧调度器的进行中任务（同步完成并发出取消事件），
    // 再取消旧订阅并重建：避免重建后旧任务继续调用 LLM/TTS/落盘。
    _scheduler?.stop();
    _schedulerSub?.cancel();
    _scheduler = SmartScheduler(
      config: config,
      llm: llm,
      tts: tts,
      saveAudio: saveAudio,
      saveRewrite: saveRewrite,
      maxRetries: maxRetries,
    );
    _schedulerSub = _scheduler!.bookStream.listen(_bookController.add);
  }

  /// 启动生成：从 [book] 的上次进度开始；[fromIndex] 指定起始章节。
  Future<void> start(Book book, {int? fromIndex}) {
    return _requireScheduler().start(book, fromIndex: fromIndex);
  }

  /// 停止生成（进行中章节标记为 cancelled，已生成内容保留）。
  Future<void> stop() => _requireScheduler().stop();

  /// 跳转章节：取消当前任务并从该章重新调度。
  Future<void> jumpTo(int chapterIndex) {
    return _requireScheduler().jumpTo(chapterIndex);
  }

  /// 单章生成：取消当前任务，仅生成 [chapterIndex] 一章后返回
  /// （不进入窗口循环），用于点击播放无音频时「先生成再播」。
  ///
  /// [book] 用于首次播放（调度器尚未装载书籍）时传入当前书，
  /// 否则调度器内部无 Book 可直接跳过处理。
  Future<void> generateChapter(int chapterIndex, {Book? book}) {
    return _requireScheduler().generateChapter(chapterIndex, book: book);
  }

  /// 预加载窗口：仅生成 [fromIndex] 起的一个窗口（后续最多窗口配置章数），
  /// 处理完即停、不整本生成；用于播放时按窗口配置预生成后续章节。
  Future<void> preloadWindow(Book book, {required int fromIndex}) {
    return _requireScheduler().preloadWindow(book, fromIndex: fromIndex);
  }

  /// Book 状态流（章节状态 / 进度每次变化时发出最新实例）。
  Stream<Book> get bookStream => _bookController.stream;

  /// 当前 Book（未启动时为 null）。
  Book? get book => _requireScheduler().book;

  /// 是否正在生成。
  bool get isRunning => _requireScheduler().isRunning;

  SmartScheduler _requireScheduler() {
    final scheduler = _scheduler;
    if (scheduler == null) {
      throw StateError('引擎尚未配置，请先调用 configure()');
    }
    return scheduler;
  }
}
