///
/// 腾讯云语音合成音色目录。
///
/// 腾讯云未提供音色列表的公开 REST 接口（音色需在控制台开通后使用），
/// 因此应用维护一份聚合目录：数据抓取自腾讯云官网「音色列表」页面
/// （文档 ID 1073/92668），共 48 个音色，按官方「音色类型」列
/// （即音色标准）分组：
/// - [TencentVoiceStandard.superNatural]：超自然大模型音色；
/// - [TencentVoiceStandard.largeModel]：大模型音色；
/// - [TencentVoiceStandard.premium]：精品音色。
///
/// 注意：三个官方接口（实时 / 基础 / 长文本语音合成）的音色表并不
/// 通用。超自然大模型音色（502xxx / 602xxx / 603xxx）只存在于实时
/// 语音合成音色表（走 WebSocket 的 [TencentStreamTTSProvider]）；
/// 基础语音合成（TextToVoice）只有大模型与精品音色。选择超自然音色
/// 时应用自动切换到实时接口，普通音色走基础接口。
///
/// 目录通过 [TencentVoiceCatalog] 加载：可注入实时数据源（JSON），
/// 失败时回退到 [tencentBuiltinVoices] 内置聚合列表。
class TencentVoice {
  const TencentVoice(
    this.id,
    this.name,
    this.scene,
    this.standard, {
    this.languages = '中英文',
    this.sampleRates = '8k/16k/24k',
    this.emotion = '中性',
  });

  /// 接口参数 VoiceType（音色 ID）。
  final String id;

  /// 音色名称。
  final String name;

  /// 推荐场景（如「情感女声」「阅读男声」）。
  final String scene;

  /// 音色标准（官方「音色类型」列），用于下拉分组展示。
  final TencentVoiceStandard standard;

  /// 支持语言。
  final String languages;

  /// 支持采样率。
  final String sampleRates;

  /// 支持情感（多情感音色列出全部，其余为中性）。
  final String emotion;

  factory TencentVoice.fromJson(Map<String, dynamic> json) {
    return TencentVoice(
      '${json['id']}',
      '${json['name']}',
      '${json['scene']}',
      TencentVoiceStandard.values.asNameMap()[json['standard']] ??
          TencentVoiceStandard.premium,
      languages: '${json['languages'] ?? '中英文'}',
      sampleRates: '${json['sampleRates'] ?? '8k/16k/24k'}',
      emotion: '${json['emotion'] ?? '中性'}',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'scene': scene,
        'standard': standard.name,
        'languages': languages,
        'sampleRates': sampleRates,
        'emotion': emotion,
      };
}

/// 音色标准（腾讯云官网「音色类型」），对应不同计费与音质档位。
enum TencentVoiceStandard {
  /// 超自然大模型音色：大模型生成、最自然的拟人音色。
  superNatural('超自然大模型音色'),

  /// 大模型音色：大模型生成、自然度次之。
  largeModel('大模型音色'),

  /// 精品音色：传统精品音库、稳定成熟。
  premium('精品音色');

  const TencentVoiceStandard(this.groupLabel);

  /// 下拉分组标题。
  final String groupLabel;
}

/// 内置聚合目录：数据来自腾讯云官网音色列表页（实时语音合成表，48 个）。
const List<TencentVoice> tencentBuiltinVoices = [
  // —— 超自然大模型音色（17 个）——
  TencentVoice('502007', '智小虎', '聊天童声', TencentVoiceStandard.superNatural),
  TencentVoice('502006', '智小悟', '聊天男声', TencentVoiceStandard.superNatural),
  TencentVoice('502005', '智小解', '解说男声', TencentVoiceStandard.superNatural),
  TencentVoice('502004', '智小满', '营销女声', TencentVoiceStandard.superNatural),
  TencentVoice('502003', '智小敏', '聊天女声', TencentVoiceStandard.superNatural),
  TencentVoice('502001', '智小柔', '聊天女声', TencentVoiceStandard.superNatural),
  TencentVoice('602004', '暖心阿灿', '聊天男声', TencentVoiceStandard.superNatural),
  TencentVoice('602005', '专业梓欣', '聊天女声', TencentVoiceStandard.superNatural),
  TencentVoice('603000', '懂事少年', '特色男声', TencentVoiceStandard.superNatural),
  TencentVoice('603001', '潇湘妹妹', '特色女声', TencentVoiceStandard.superNatural),
  TencentVoice('603002', '软萌心心', '特色男童声', TencentVoiceStandard.superNatural),
  TencentVoice('603003', '随和老李', '聊天男声', TencentVoiceStandard.superNatural),
  TencentVoice('603004', '温柔小柠', '聊天女声', TencentVoiceStandard.superNatural),
  TencentVoice('603005', '知心大林', '聊天男声', TencentVoiceStandard.superNatural),
  TencentVoice('603006', '沉稳青叔', '聊天男声', TencentVoiceStandard.superNatural),
  TencentVoice('603007', '邻家女孩', '聊天女声', TencentVoiceStandard.superNatural),
  TencentVoice('602003', '爱小悠', '聊天女声', TencentVoiceStandard.superNatural),
  // —— 大模型音色（17 个）——
  TencentVoice('501000', '智斌', '阅读男声', TencentVoiceStandard.largeModel),
  TencentVoice('501001', '智兰', '资讯女声', TencentVoiceStandard.largeModel),
  TencentVoice('501002', '智菊', '阅读女声', TencentVoiceStandard.largeModel),
  TencentVoice('501003', '智宇', '阅读男声', TencentVoiceStandard.largeModel),
  TencentVoice('501004', '月华', '聊天女声', TencentVoiceStandard.largeModel),
  TencentVoice('501005', '飞镜', '聊天男声', TencentVoiceStandard.largeModel),
  TencentVoice('501006', '千嶂', '聊天男声', TencentVoiceStandard.largeModel),
  TencentVoice('501007', '浅草', '聊天男声', TencentVoiceStandard.largeModel),
  TencentVoice('501008', 'WeJames', '外语男声', TencentVoiceStandard.largeModel,
      languages: '英文'),
  TencentVoice('501009', 'WeWinny', '外语女声', TencentVoiceStandard.largeModel,
      languages: '英文'),
  TencentVoice('601008', '爱小豪', '聊天男声', TencentVoiceStandard.largeModel,
      languages: '中文',
      emotion: '中性、悲伤、高兴、生气、恐惧、撒娇、震惊、厌恶、平静'),
  TencentVoice('601009', '爱小芊', '聊天女声', TencentVoiceStandard.largeModel,
      languages: '中文',
      emotion: '中性、悲伤、高兴、生气、恐惧、撒娇、震惊、厌恶、平静'),
  TencentVoice('601010', '爱小娇', '聊天女声', TencentVoiceStandard.largeModel,
      languages: '中文',
      emotion: '中性、悲伤、高兴、生气、恐惧、撒娇、震惊、厌恶、平静'),
  TencentVoice('601011', '爱小川', '聊天男声', TencentVoiceStandard.largeModel,
      languages: '中文'),
  TencentVoice('601012', '爱小璟', '特色女声', TencentVoiceStandard.largeModel,
      languages: '中文'),
  TencentVoice('601013', '爱小伊', '阅读女声', TencentVoiceStandard.largeModel,
      languages: '中文'),
  TencentVoice('601014', '爱小简', '聊天男声', TencentVoiceStandard.largeModel,
      languages: '中文'),
  // —— 精品音色（14 个）——
  TencentVoice('101050', 'WeJack', '英文男声', TencentVoiceStandard.premium,
      languages: '英文', sampleRates: '8k/16k'),
  TencentVoice('101055', '智付', '通用女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101013', '智辉', '新闻男声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101019', '智彤', '粤语女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101030', '智柯', '通用男声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101054', '智友', '通用男声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101027', '智梅', '通用女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101026', '智希', '通用女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101004', '智云', '通用男声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101015', '智萌', '男童声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101011', '智燕', '新闻女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101001', '智瑜', '情感女声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101021', '智瑞', '新闻男声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
  TencentVoice('101016', '智甜', '女童声', TencentVoiceStandard.premium,
      sampleRates: '8k/16k'),
];
