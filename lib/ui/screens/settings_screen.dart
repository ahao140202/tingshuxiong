import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';
import '../../core/tts/xunfei/xunfei_voice_catalog.dart';
import '../../core/tts/xunfei/xunfei_voices.dart';
import '../../platform/platform.dart';
import '../state/app_state.dart';

/// 设置页：选择 LLM/TTS 提供商、填写对应凭据与引擎参数，保存后立即生效。
///
/// 凭据字段按 [LLMKind.credentialFields] / [TTSKind.credentialFields] 动态渲染，
/// 新增提供商无需改动本页结构。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late LLMKind _llmKind;
  late TTSKind _ttsKind;

  /// 凭据输入控制器，键为 `llm:<key>` / `tts:<key>`（不同提供商同名字段互不覆盖）。
  final Map<String, TextEditingController> _credentialControllers = {};

  late String _voice;

  /// 生成文件根目录（null 表示默认目录，保存后即时生效）。
  late String? _outputRoot;
  late final TextEditingController _outputRootController;

  /// 发音人下拉的 key：自定义发音人变更后换新 key 强制重建，刷新显示值。
  UniqueKey _voiceFieldKey = UniqueKey();

  /// 发音人目录异步加载结果（实时源优先，失败回退内置聚合目录）。
  late final Future<List<XunfeiVoice>> _voiceFuture =
      XunfeiVoiceCatalog().load();
  late final TextEditingController _windowMaxChars;
  late final TextEditingController _maxTokens;
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
      for (final field in kind.credentialFields) {
        _credentialControllers['llm:${field.key}'] =
            TextEditingController(text: s.llmCredentials[field.key] ?? '');
      }
    }
    for (final kind in TTSKind.values) {
      for (final field in kind.credentialFields) {
        _credentialControllers['tts:${field.key}'] =
            TextEditingController(text: s.ttsCredentials[field.key] ?? '');
      }
    }
    _voice = s.voice;
    _outputRoot = s.outputRoot;
    _outputRootController =
        TextEditingController(text: s.outputRoot ?? '');
    _windowMaxChars = TextEditingController(text: '${s.windowMaxChars}');
    _maxTokens = TextEditingController(text: '${s.maxTokens}');
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
    _outputRootController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final llmCredentials = <String, String>{
      for (final field in _llmKind.credentialFields)
        field.key:
            (_credentialControllers['llm:${field.key}']?.text ?? '').trim(),
    };
    final ttsCredentials = <String, String>{
      for (final field in _ttsKind.credentialFields)
        field.key:
            (_credentialControllers['tts:${field.key}']?.text ?? '').trim(),
    };
    final settings = AppSettings(
      llmKind: _llmKind,
      ttsKind: _ttsKind,
      llmCredentials: llmCredentials,
      ttsCredentials: ttsCredentials,
      voice: _voice.trim().isEmpty ? _ttsKind.defaultVoice : _voice.trim(),
      speed: _speed,
      volume: _volume,
      pitch: _pitch,
      windowSize: _windowSize,
      windowMaxChars: int.tryParse(_windowMaxChars.text.trim()) ?? 15000,
      maxTokens: int.tryParse(_maxTokens.text.trim()) ?? 1500,
      temperature: _temperature,
      maxRetries: _maxRetries,
      outputRoot: _outputRoot,
    );
    await widget.appState.applySettings(settings);
    if (mounted) Navigator.of(context).pop();
  }

  /// 弹窗输入自定义发音人 vcn（如已授权的特色发音人）。
  Future<void> _editCustomVoice() async {
    final controller = TextEditingController(text: _voice);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义发音人'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '发音人 ID (vcn)',
            hintText: '如 aisjiuxu，需已在讯飞控制台授权',
            border: OutlineInputBorder(),
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
        _voice = result;
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
              controller: _credentialControllers['llm:${field.key}'],
              obscureText: field.obscure,
              decoration: InputDecoration(
                labelText: '${_llmKind.label} ${field.label}',
                hintText: field.key == 'apiKey' ? 'sk-...' : null,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
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
              controller: _credentialControllers['tts:${field.key}'],
              obscureText: field.obscure,
              decoration: InputDecoration(
                labelText: '${_ttsKind.label} ${field.label}',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          _sectionTitle('TTS 参数'),
          _buildVoiceField(context),
          const SizedBox(height: 8),
          Text(
            '基础发音人免费可用；特色发音人需在讯飞控制台购买授权（未授权合成会报错），'
            '也可点编辑按钮直接输入已授权的 vcn。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          _slider('语速', _speed, (v) => setState(() => _speed = v)),
          _slider('音量', _volume, (v) => setState(() => _volume = v)),
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
              IconButton(
                tooltip: '选择目录',
                icon: const Icon(Icons.folder_open),
                onPressed: _pickOutputRoot,
              ),
              IconButton(
                tooltip: '恢复默认',
                icon: const Icon(Icons.restore),
                onPressed: () => setState(() {
                  _outputRoot = null;
                  _outputRootController.text = '';
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '改写稿与音频将按「根目录/书名/rewrite|audio|history」组织，'
            '重新生成时旧文件自动转入 history 目录。',
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
            'LLM 口语化改写 → 所选 TTS 合成 → 本地存储。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 发音人下拉：异步加载聚合目录（基础 + 特色分组），统一字体风格。
  ///
  /// 实时数据源不可用时回退内置目录；自定义 vcn 始终保留为末项。
  Widget _buildVoiceField(BuildContext context) {
    final theme = Theme.of(context);
    // 所有下拉项统一字体，保证基础/特色/自定义风格一致。
    final itemStyle = theme.textTheme.bodyMedium;
    return FutureBuilder<List<XunfeiVoice>>(
      future: _voiceFuture,
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
                onChanged: (v) => setState(() => _voice = v ?? _voice),
              ),
            ),
            IconButton(
              tooltip: '自定义发音人',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _editCustomVoice,
            ),
          ],
        );
      },
    );
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
