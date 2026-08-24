/// 章节生成状态机状态。
///
/// 流转规则由调度器（SmartScheduler）保证：
/// `notGenerated -> rewriting -> synthesizing -> generated`
/// 任意状态 -> `failed`（异常）/ `cancelled`（用户跳章取消）。
enum ChapterStatus {
  notGenerated('未生成'),
  rewriting('AI 改写中'),
  synthesizing('合成音频中'),
  generated('已生成'),
  failed('生成失败'),
  cancelled('已取消');

  const ChapterStatus(this.label);

  /// 展示用中文文案。
  final String label;

  /// 是否处于终态（不再自动流转）。
  bool get isDone => this == generated || this == failed || this == cancelled;

  /// 是否可继续生成（未生成/失败/已取消均可重新调度）。
  bool get isRunnable => this == notGenerated || this == failed || this == cancelled;
}