# 听书熊

AI 有声小说生成器：导入 txt 小说 → DeepSeek 口语化改写 → 讯飞 TTS 合成 → 本地播放/导出。

## 功能

- 导入 txt 小说（自动识别 UTF-8 / GBK 编码，自动切分章节）
- LLM 口语化改写（DeepSeek，可按章节预加载窗口生成）
- 讯飞在线语音合成（超长文本自动分块，支持发音人/语速/音量/音高调节）
- 本地播放与音频导出
- Windows / Android / iOS 三端

## 运行

```bash
flutter pub get
flutter run -d windows
```

首次使用请在「设置」页填写 DeepSeek API Key 与讯飞 APPID / API Key / API Secret。

## 端到端验证

```bash
# 真实调用 DeepSeek + 讯飞，对《玄鉴仙族》第 N 章执行完整生成流程
dart run tool/e2e_generate.dart 1
```
