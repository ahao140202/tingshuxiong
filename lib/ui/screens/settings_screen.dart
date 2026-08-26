import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';
import '../../core/tts/tencent/tencent_voice_catalog.dart';
import '../../core/tts/tencent/tencent_voices.dart';
import '../../core/tts/xunfei/xunfei_voice_catalog.dart';
import '../../core/tts/xunfei/xunfei_voices.dart';
import '../../platform/platform.dart';
import '../state/app_state.dart';

/// 设置页：选择 LLM/TTS 提供商、填写对应凭据与引擎参数，保存后立即生效。
///
/// 凭据字段按 [LLMKind.credentialFields] / [TTSKind.credentialFields] 动态渲染，
/// 新增提供商无需改动本页结构；凭据与音色均按提供商维度保存，切换提供商
/// 不会丢失各自已填内容与已选音色。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late LLMKind _llmKind;
  late TTSKind _ttsKind;

  /// 凭据输入控制器，键为 `llm:<kind>:<key>` / `tts:<kind>:<key>`
  /// （含提供商维度，不同提供商同名字段互不覆盖）。
  final Map<String, TextEditingController> _credentialControllers = {};

  /// 正在「按住展示」的敏感字段控制器键集合（松开/取消时移除）。
  final Set<String> _revealedKeys = {};

  /// 各 TTS 提供商选中的音色（key = 提供商枚举名），切换提供商互不丢失。
  late final Map<String, String> _voiceByKind;

  /// 当前 TTS 提供商选中的音色。
  String get _voice => _voiceByKind[_ttsKind.name] ?? _ttsKind.defaultVoice;

  /// 生成文件根目录（null 表示默认目录，保存后即时生效）。
  late String? _outputRoot;
  late final TextEditingController _outputRootController;

  /// 发音人下拉的 key：自定义发音人变更后换新 key 强制重建，刷新显示值。
  UniqueKey _voiceFieldKey = UniqueKey();

  /// 讯飞发音人目录异步加载结果（实时源优先，失败回退内置聚合目录）。
  late final Future<List<XunfeiVoice>> _xunfeiVoiceFuture =
      XunfeiVoiceCatalog().load();

  /// 腾讯云音色目录异步加载结果（实时源优先，失败回退内置聚合目录）。
  late final Future<List<TencentVoice>> _tencentVoiceFuture =
      TencentVoiceCatalog().load();
  late final TextEditingController _windowMaxChars;
  late final TextEditingController _maxTokens;
  late final TextEditingController _mergeFileSizeMb;
  late int _speed;
  late int _volume;
  late int _pitch;
  late int _windowSize;
  late double _temperature;
  late int _maxRetries;

  @override
  void initState() {
    super.initState();
    final s = widget.appState.settings;
    _llmKind = s.llmKind;
    _ttsKind = s.ttsKind;
    // 预创建全部提供商的凭据控制器（切换提供商不丢失已输入内容）。
    for (final kind in LLMKind.values) {
      final creds = s.llmCredentialsFor(kind);
      for (final field in kind.credentialFields) {
        _credentialControllers['llm:${kind.name}:${field.key}'] =
            TextEditingController(text: creds[field.key] ?? '');
      }
    }
    for (final kind in TTSKind.values) {
      final creds = s.ttsCredentialsFor(kind);
      for (final field in kind.credentialFields) {
        _credentialControllers['tts:${kind.name}:${field.key}'] =
            TextEditingController(text: creds[field.key] ?? '');
      }
    }
    _voiceByKind = {
      for (final kind in TTSKind.values) kind.name: s.voiceFor(kind),
    };
    _outputRoot = s.outputRoot;
    _outputRootController =
        TextEditingController(text: s.outputRoot ?? '');
    _windowMaxChars = TextEditingController(text: '${s.windowMaxChars}');
    _maxTokens = TextEditingController(text: '${s.maxTokens}');
    _mergeFileSizeMb = TextEditingController(text: '${s.mergeFileSizeMb}');
    _speed = s.speed;
    _volume = s.volume;
    _pitch = s.pitch;
    _windowSize = s.windowSize;
    _temperature = s.temperature;
    _maxRetries = s.maxRetries;
  }

  @override
  void dispose() {
    for (final controller in _credentialControllers.values) {
      controller.dispose();
    }
    _windowMaxChars.dispose();
    _maxTokens.dispose();
    _mergeFileSizeMb.dispose();
    _outputRootController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // 收集全部提供商的凭据（各提供商独立保存，切换不丢失）。
    final llmCredentialsByKind = <String, Map<String, String>>{
      for (final kind in LLMKind.values)
        kind.name: {
          for (final field in kind.credentialFields)
            field.key:
                (_credentialControllers['llm:${kind.name}:${field.key}']
                        ?.text ??
                    '')
                    .trim(),
        },
    };
    final ttsCredentialsByKind = <String, Map<String, String>>{
      for (final kind in TTSKind.values)
        kind.name: {
          for (final field in kind.credentialFields)
            field.key:
                (_credentialControllers['tts:${kind.name}:${field.key}']
                        ?.text ??
                    '')
                    .trim(),
        },
    };
    final voiceByKind = <String, String>{
      for (final kind in TTSKind.values)
        kind.name: _voiceByKind[kind.name] ?? kind.defaultVoice,
    };
    final settings = AppSettings(
      llmKind: _llmKind,
      ttsKind: _ttsKind,
      llmCredentialsByKind: llmCredentialsByKind,
      ttsCredentialsByKind: ttsCredentialsByKind,
      voiceByKind: voiceByKind,
      speed: _speed,
      volume: _volume,
      pitch: _pitch,
      windowSize: _windowSize,
      windowMaxChars: int.tryParse(_windowMaxChars.text.trim()) ?? 15000,
      maxTokens: int.tryParse(_maxTokens.text.trim()) ?? 1500,
      mergeFileSizeMb: int.tryParse(_mergeFileSizeMb.text.trim()) ?? 100,
      temperature: _temperature,
      maxRetries: _maxRetries,
      outputRoot: _outputRoot,
    );
    await widget.appState.applySettings(settings);
    if (mounted) Navigator.of(context).pop();
  }

  /// 敏感字段的「按住展示」按钮：按下显示明文，松开/取消立即恢复掩码。
  ///
  /// 用 [Listener] 监听原始指针事件而非按钮点击：展示状态与按住时长绑定，
  /// 鼠标在按钮上按下即显示，抬起（含移出后松开）即隐藏。
  Widget _revealButton(String controllerKey) {
    return Listener(
      onPointerDown: (_) => setState(() => _revealedKeys.add(controllerKey)),
      onPointerUp: (_) => setState(() => _revealedKeys.remove(controllerKey)),
      onPointerCancel: (_) =>
          setState(() => _revealedKeys.remove(controllerKey)),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Icon(Icons.visibility_outlined, size: 20),
      ),
    );
  }

  /// 弹窗输入自定义发音人/音色 ID（如已授权的特色发音人或新开通的音色）。
  Future<void> _editCustomVoice() async {
    final controller = TextEditingController(text: _voice);
    final isTencent = _ttsKind == TTSKind.tencent;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isTencent ? '自定义音色' : '自定义发音人'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: isTencent ? '音色 ID (VoiceType)' : '发音人 ID (vcn)',
            hintText: isTencent
                ? '如 101001，需已在腾讯云开通对应音色'
                : '如 aisjiuxu，需已在讯飞控制台授权',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        _voiceByKind[_ttsKind.name] = result;
        _voiceFieldKey = UniqueKey();
      });
    }
  }

  /// 选择生成文件根目录（桌面端弹系统目录选择框；移动端不支持时提示）。
  Future<void> _pickOutputRoot() async {
    String? path;
    try {
      path = await getDirectoryPath();
    } on UnimplementedError {
      path = null;
    }
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未选择目录（移动端暂不支持目录选择）')),
        );
      }
      return;
    }
    // 判空后提升为非空，供 setState 闭包内使用。
    final selected = path;
    setState(() {
      _outputRoot = selected;
      _outputRootController.text = selected;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('API 凭据'),
          DropdownButtonFormField<LLMKind>(
            initialValue: _llmKind,
            decoration: const InputDecoration(
              labelText: 'LLM 提供商',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final kind in LLMKind.values)
                DropdownMenuItem(value: kind, child: Text(kind.label)),
            ],
            onChanged: (v) => setState(() => _llmKind = v ?? LLMKind.deepSeek),
          ),
          const SizedBox(height: 12),
          for (final field in _llmKind.credentialFields) ...[
            TextField(
              // 控制器 key 必须带提供商维度（与 initState 预创建一致），
              // 否则输入内容不写入控制器、保存时读到旧值导致配置不生效。
              controller:
                  _credentialControllers['llm:${_llmKind.name}:${field.key}'],
              obscureText: field.obscure &&
                  !_revealedKeys.contains('llm:${_llmKind.name}:${field.key}'),
              decoration: InputDecoration(
                labelText: '${_llmKind.label} ${field.label}',
                hintText: field.key == 'apiKey' ? 'sk-...' : null,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                // 敏感字段提供「按住展示」：按下显示明文，松开恢复掩码。
                suffixIcon: field.obscure
                    ? _revealButton('llm:${_llmKind.name}:${field.key}')
                    : null,
              ),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<TTSKind>(
            initialValue: _ttsKind,
            decoration: const InputDecoration(
              labelText: 'TTS 提供商',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final kind in TTSKind.values)
                DropdownMenuItem(value: kind, child: Text(kind.label)),
            ],
            onChanged: (v) => setState(() => _ttsKind = v ?? TTSKind.xunfei),
          ),
          const SizedBox(height: 12),
          for (final field in _ttsKind.credentialFields) ...[
            TextField(
              // 与 LLM 字段一致：控制器 key 带提供商维度（保存不生效的同类问题）。
              controller:
                  _credentialControllers['tts:${_ttsKind.name}:${field.key}'],
              obscureText: field.obscure &&
                  !_revealedKeys.contains('tts:${_ttsKind.name}:${field.key}'),
              decoration: InputDecoration(
                labelText: '${_ttsKind.label} ${field.label}',
                // 与 LLM 的 sk-... 提示对称，引导填入正确格式的凭据。
                hintText: field.key == 'secretId' ? 'AKID...' : null,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: field.obscure
                    ? _revealButton('tts:${_ttsKind.name}:${field.key}')
                    : null,
              ),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          _sectionTitle('TTS 参数'),
          _buildVoiceField(context),
          const SizedBox(height: 8),
          if (_ttsKind == TTSKind.xunfei)
            Text(
              '基础发音人免费可用；特色发音人需在讯飞控制台购买授权（未授权合成会报错），'
              '也可点编辑按钮直接输入已授权的 vcn。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            )
          else
            Text(
              '音色按官方「音色标准」分组：超自然大模型 / 大模型 / 精品音色，'
              '费用与开通方式见腾讯云购买指南，也可点编辑按钮直接输入音色 ID。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          _slider('语速', _speed, (v) => setState(() => _speed = v)),
          _slider('音量', _volume, (v) => setState(() => _volume = v)),
          // 腾讯云 TextToVoice 接口不支持音高参数，仅讯飞提供音高调节。
          if (_ttsKind == TTSKind.xunfei)
            _slider('音高', _pitch, (v) => setState(() => _pitch = v)),
          const SizedBox(height: 24),
          _sectionTitle('生成参数'),
          // 生成文件根目录：改写稿/音频/历史文件统一输出位置。
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _outputRootController,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: '生成文件根目录',
                    hintText: '默认：应用数据目录/generated',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              // ExcludeSemantics 规避 Flutter tooltip 语义嫁接框架 bug
              //（#187198）：悬浮/点击触发 AXTree 更新失败日志；提示与点击不受影响。
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '选择目录',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickOutputRoot,
                ),
              ),
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '恢复默认',
                  icon: const Icon(Icons.restore),
                  onPressed: () => setState(() {
                    _outputRoot = null;
                    _outputRootController.text = '';
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '改写稿与音频将按「根目录/书名/rewrite|audio」组织；'
            '逐章导出与聚合导出均输出到所选目录。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _mergeFileSizeMb,
            decoration: const InputDecoration(
              labelText: '聚合文件大小上限（MB）',
              hintText: '默认 100',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          Text(
            '「聚合并导出」按此上限将章节音频顺序合并为数量更少的大文件。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 12),
          _slider('预加载窗口（后续章数）', _windowSize, (v) => setState(() => _windowSize = v), max: 5),
          TextField(
            controller: _windowMaxChars,
            decoration: const InputDecoration(
              labelText: '窗口累计字数上限',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _maxTokens,
            decoration: const InputDecoration(
              labelText: 'LLM 单次输出 tokens 上限',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _slider(
            '采样温度',
            (_temperature * 10).round(),
            (v) => setState(() => _temperature = v / 10),
            max: 10,
            display: _temperature.toStringAsFixed(1),
          ),
          _slider('失败重试次数', _maxRetries, (v) => setState(() => _maxRetries = v), max: 5),
          const SizedBox(height: 24),
          _sectionTitle('说明'),
          Text(
            '凭据仅保存在本机应用数据目录。生成流程：'
            'LLM 修订润色 → 所选 TTS 合成 → 本地存储。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 音色/发音人下拉：按当前 TTS 提供商加载对应目录。
  ///
  /// 讯飞按「基础/特色」分组；腾讯云按官方「音色标准」（超自然大模型 /
  /// 大模型 / 精品音色）分组，均标明分组与个数。实时数据源不可用时回退
  /// 内置目录；自定义音色 ID 始终保留为末项。
  Widget _buildVoiceField(BuildContext context) {
    final theme = Theme.of(context);
    // 所有下拉项统一字体，保证分组/条目/自定义风格一致。
    final itemStyle = theme.textTheme.bodyMedium;
    if (_ttsKind == TTSKind.tencent) {
      return FutureBuilder<List<TencentVoice>>(
        future: _tencentVoiceFuture,
        builder: (context, snapshot) {
          final voices = snapshot.data ?? tencentBuiltinVoices;
          return Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: _voiceFieldKey,
                  initialValue: _voice,
                  decoration: const InputDecoration(
                    labelText: '音色（VoiceType）',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final standard in TencentVoiceStandard.values)
                      ..._tencentVoiceGroupItems(standard, voices, itemStyle),
                    // 当前值为目录外的自定义音色时保留显示，避免保存时被重置。
                    if (!voices.any((v) => v.id == _voice))
                      DropdownMenuItem(
                        value: _voice,
                        child: Text('自定义（$_voice）', style: itemStyle),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    if (v != null) _voiceByKind[_ttsKind.name] = v;
                  }),
                ),
              ),
              // ExcludeSemantics 同上：规避 tooltip 语义嫁接框架 bug。
              ExcludeSemantics(
                child: IconButton(
                  tooltip: '自定义音色',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _editCustomVoice,
                ),
              ),
            ],
          );
        },
      );
    }
    return FutureBuilder<List<XunfeiVoice>>(
      future: _xunfeiVoiceFuture,
      builder: (context, snapshot) {
        final voices = snapshot.data ?? xunfeiBuiltinVoices;
        final basic = [
          for (final v in voices)
            if (v.kind == XunfeiVoiceKind.basic) v,
        ];
        final featured = [
          for (final v in voices)
            if (v.kind == XunfeiVoiceKind.featured) v,
        ];
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: _voiceFieldKey,
                initialValue: _voice,
                decoration: const InputDecoration(
                  labelText: '发音人',
                  border: OutlineInputBorder(),
                ),
                items: [
                  ..._voiceGroupItems(XunfeiVoiceKind.basic, basic, itemStyle),
                  ..._voiceGroupItems(
                      XunfeiVoiceKind.featured, featured, itemStyle),
                  // 当前值为自定义发音人时保留显示，避免保存时被重置。
                  if (!voices.any((v) => v.code == _voice))
                    DropdownMenuItem(
                      value: _voice,
                      child: Text('自定义（$_voice）', style: itemStyle),
                    ),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _voiceByKind[_ttsKind.name] = v;
                }),
              ),
            ),
            // ExcludeSemantics 同上：规避 tooltip 语义嫁接框架 bug。
            ExcludeSemantics(
              child: IconButton(
                tooltip: '自定义发音人',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _editCustomVoice,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 构造一组腾讯云音色下拉项：分组标题（不可选，含数量）+ 音色条目。
  List<DropdownMenuItem<String>> _tencentVoiceGroupItems(
    TencentVoiceStandard standard,
    List<TencentVoice> voices,
    TextStyle? itemStyle,
  ) {
    final theme = Theme.of(context);
    final group = [
      for (final v in voices)
        if (v.standard == standard) v,
    ];
    return [
      DropdownMenuItem<String>(
        enabled: false,
        value: '__group__${standard.name}',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '${standard.groupLabel}（${group.length}）',
            style: itemStyle?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ),
      for (final v in group)
        DropdownMenuItem<String>(
          value: v.id,
          child: Text('${v.name} · ${v.scene}', style: itemStyle),
        ),
    ];
  }

  /// 构造一组发音人下拉项：分组标题（不可选）+ 发音人条目，字体统一。
  List<DropdownMenuItem<String>> _voiceGroupItems(
    XunfeiVoiceKind kind,
    List<XunfeiVoice> voices,
    TextStyle? itemStyle,
  ) {
    final theme = Theme.of(context);
    return [
      DropdownMenuItem<String>(
        enabled: false,
        value: '__group__${kind.name}',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            kind.groupLabel,
            style: itemStyle?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ),
      for (final v in voices)
        DropdownMenuItem<String>(
          value: v.code,
          child: Text('${v.name} · ${v.description}', style: itemStyle),
        ),
    ];
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  Widget _slider(
    String label,
    int value,
    ValueChanged<int> onChanged, {
    int max = 100,
    String? display,
  }) {
    return Row(
      children: [
        SizedBox(width: 140, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.toDouble().clamp(0, max.toDouble()),
            max: max.toDouble(),
            divisions: max,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(width: 40, child: Text(display ?? '$value')),
      ],
    );
  }
}
