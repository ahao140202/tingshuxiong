/// 讯飞在线语音合成发音人（vcn）目录。
///
/// 讯飞开放平台未提供发音人列表的公开 REST 接口（文档明确发音人
/// 只能通过控制台「添加试用/购买」后查看），因此应用维护一份聚合目录：
/// - [XunfeiVoiceKind.basic]：控制台免费赠送、直接可用的基础发音人；
/// - [XunfeiVoiceKind.featured]：官方文档确认存在的特色发音人（需在
///   控制台购买授权，2 万/年，未授权时合成返回 11200）。
///
/// 目录通过 [XunfeiVoiceCatalog] 加载：可注入实时数据源（JSON），
/// 失败时回退到 [xunfeiBuiltinVoices] 内置聚合列表。
class XunfeiVoice {
  const XunfeiVoice(
    this.code,
    this.name,
    this.description, {
    this.kind = XunfeiVoiceKind.basic,
  });

  /// 接口参数 vcn。
  final String code;

  /// 中文名。
  final String name;

  /// 音色说明（性别 · 语种/方言）。
  final String description;

  /// 类别（基础/特色），用于下拉分组展示。
  final XunfeiVoiceKind kind;

  factory XunfeiVoice.fromJson(Map<String, dynamic> json) {
    return XunfeiVoice(
      '${json['code']}',
      '${json['name']}',
      '${json['description']}',
      kind: json['kind'] == 'featured'
          ? XunfeiVoiceKind.featured
          : XunfeiVoiceKind.basic,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'description': description,
        'kind': kind.name,
      };
}

/// 发音人类别。
enum XunfeiVoiceKind {
  /// 基础发音人：免费赠送、直接可用。
  basic('基础发音人 · 免费'),

  /// 特色发音人：需控制台购买授权。
  featured('特色发音人 · 需授权');

  const XunfeiVoiceKind(this.groupLabel);

  /// 下拉分组标题。
  final String groupLabel;
}

/// 内置聚合目录：官方文档/服务说明确认存在的发音人。
///
/// 基础 5 个（小燕、许久、小萍、小婧、许小宝）+ 特色 5 个
/// （小宇、小峰、小琪、凯瑟琳、玛丽，经典音库，均需授权）。
const List<XunfeiVoice> xunfeiBuiltinVoices = [
  XunfeiVoice('xiaoyan', '小燕', '女声 · 普通话'),
  XunfeiVoice('aisjiuxu', '许久', '男声 · 普通话'),
  XunfeiVoice('aisxping', '小萍', '女声 · 普通话'),
  XunfeiVoice('aisjinger', '小婧', '女声 · 粤语'),
  XunfeiVoice('aisbabyxu', '许小宝', '童声 · 普通话'),
  XunfeiVoice('xiaoyu', '小宇', '男声 · 普通话', kind: XunfeiVoiceKind.featured),
  XunfeiVoice('xiaofeng', '小峰', '男声 · 普通话', kind: XunfeiVoiceKind.featured),
  XunfeiVoice('xiaoqi', '小琪', '女声 · 普通话', kind: XunfeiVoiceKind.featured),
  XunfeiVoice('catherine', '凯瑟琳', '女声 · 英语', kind: XunfeiVoiceKind.featured),
  XunfeiVoice('mary', '玛丽', '女声 · 英语', kind: XunfeiVoiceKind.featured),
];
