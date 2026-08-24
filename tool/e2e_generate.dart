// CLI 工具脚本：使用 print 输出进度（非生产代码）。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:path/path.dart' as p;
import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/facade/ting_engine.dart';
import 'package:tingshuxiong/core/llm/deepseek/deepseek_provider.dart';
import 'package:tingshuxiong/core/tts/xunfei/xunfei_provider.dart';

/// 端到端生成测试：真实调用 DeepSeek + 讯飞，对《玄鉴仙族》第一章
/// 执行「口语化改写 → TTS 合成 → 落盘」全流程，验证整条链路可用。
///
/// 用法：`dart run tool/e2e_generate.dart [章节号]`
/// 凭据从应用设置文件读取（settings.json），退出码非 0 表示失败。
Future<void> main(List<String> args) async {
  final chapterNo = args.isEmpty ? 1 : int.parse(args.first);
  final settingsFile = File(
    r'C:\Users\user\AppData\Roaming\com.example\tingshuxiong\settings.json',
  );
  final s = jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
  final llmCreds = (s['llmCredentials'] as Map?)?.cast<String, String>() ?? {};
  final ttsCreds = (s['ttsCredentials'] as Map?)?.cast<String, String>() ?? {};

  // 1. 读取小说并切分章节（txt 为 GBK 编码，按应用同款策略解码）
  final txt = File(
    r'd:\tingshuxiong\test\玄鉴仙族-作者：季越人.txt',
  );
  final fullText = _decodeText(await txt.readAsBytes());
  final book = TingEngine().importBook(
    id: 'e2e-玄鉴仙族',
    title: '玄鉴仙族',
    fullText: fullText,
  );
  if (book.chapterCount == 0) {
    _fail('未切分出任何章节');
  }
  if (chapterNo > book.chapterCount) {
    _fail('章节号 $chapterNo 超出范围（共 ${book.chapterCount} 章）');
  }
  final chapter = book.chapterAt(chapterNo - 1);
  print('[1/4] 章节「${chapter.title}」原文 ${chapter.rawText.length} 字 '
      '(${utf8.encode(chapter.rawText).length} 字节)');

  // 2. DeepSeek 口语化改写
  final llm = DeepSeekProvider(
    apiKey: llmCreds['apiKey'] ?? '',
  );
  final t0 = DateTime.now();
  print('[2/4] DeepSeek 改写中（model=${llm.model}）…');
  final rewritten = await llm.rewrite(
    title: chapter.title,
    rawText: chapter.rawText,
    maxTokens: 1500,
    temperature: 0.7,
  );
  print('[2/4] 改写完成：${rewritten.length} 字 '
      '(${utf8.encode(rewritten).length} 字节)，耗时 '
      '${DateTime.now().difference(t0).inSeconds}s');

  // 3. 讯飞 TTS 合成（provider 内部自动分块，验证超长文本修复）
  final tts = XunfeiTTSProvider(
    appId: ttsCreds['appId'] ?? '',
    apiKey: ttsCreds['apiKey'] ?? '',
    apiSecret: ttsCreds['apiSecret'] ?? '',
  );
  final t1 = DateTime.now();
  print('[3/4] 讯飞 TTS 合成中（voice=${s['voice'] ?? 'xiaoyan'}）…');
  final audio = await tts.synthesize(
    text: rewritten,
    config: TTSConfig(voice: s['voice'] as String? ?? 'xiaoyan'),
  );
  print('[3/4] 合成完成：${audio.length} 字节，耗时 '
      '${DateTime.now().difference(t1).inSeconds}s');

  // 4. 落盘
  final outDir = Directory(p.join('build', 'e2e'));
  await outDir.create(recursive: true);
  final outFile = File(
    p.join(outDir.path, '${chapterNo.toString().padLeft(3, '0')}-${chapter.title}.mp3'),
  );
  await outFile.writeAsBytes(audio);
  print('[4/4] 已保存 $outFile（${audio.length} 字节）');

  // 5. 校验：MP3 魔数（ID3 或帧头）与最小尺寸
  final ok = _looksLikeMp3(audio);
  print(ok
      ? '✅ 端到端生成成功：改写 ${rewritten.length} 字 → 音频 ${audio.length} 字节'
      : '⚠️ 音频文件字节数异常（可能为空或非 MP3），请人工检查');
  if (!ok) _fail('音频校验失败');
}

bool _looksLikeMp3(Uint8List bytes) {
  if (bytes.length < 4) return false;
  // ID3v2 头（'ID3'）或 MPEG 帧同步（0xFFE0 掩码）。
  if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
  return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
}

/// 与应用的 TxtFilePicker 同款策略：优先 UTF-8，失败回退 GBK。
String _decodeText(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbk.decode(bytes);
  }
}

Never _fail(String message) {
  stderr.writeln('❌ $message');
  exit(1);
}
