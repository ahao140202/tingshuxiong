# 听书熊

AI 有声小说生成器：导入 txt 小说 → DeepSeek 修订润色 → 讯飞/腾讯云 TTS 合成 → 本地播放/导出。

## 功能

- 导入 txt 小说（自动识别 UTF-8 / GBK 编码，自动切分章节）
- LLM 修订润色（DeepSeek，可按章节预加载窗口生成）
- 在线语音合成（讯飞 / 腾讯云二选一，超长文本自动分块，支持发音人/语速/音量调节）
  - 讯飞：发音人按基础/特色分组，支持音高调节
  - 腾讯云：48 个音色按音色标准分组（超自然大模型 / 大模型 / 精品音色）
- 本地播放与音频导出
- Windows / Android / iOS 三端

## 运行

```bash
flutter pub get
flutter run -d windows
```

首次使用请在「设置」页填写 DeepSeek API Key，并在讯飞 / 腾讯云中任选一个 TTS 服务填写对应凭据（讯飞：APPID / API Key / API Secret；腾讯云：SecretId / SecretKey）。切换服务时各服务凭据与音色选择会分别保存，互不丢失。

## 端到端验证

```bash
# 真实调用 DeepSeek + 讯飞，对《玄鉴仙族》第 N 章执行完整生成流程
dart run tool/e2e_generate.dart 1
```
