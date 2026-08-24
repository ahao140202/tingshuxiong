import 'package:dio/dio.dart';

import '../../domain/domain.dart';
import '../llm_provider.dart';

/// DeepSeek 口语化改写实现（OpenAI 兼容 `/chat/completions` 协议）。
///
/// API Key 由上层（facade / 设置页）注入，不在本类持久化。
class DeepSeekProvider implements LLMProvider {
  DeepSeekProvider({
    required this.apiKey,
    Dio? dio,
    this._baseUrl = defaultBaseUrl,
    String? model,
  })  : _dio = dio ?? _defaultDio(_baseUrl),
        model = model ?? LLMKind.deepSeek.defaultModel;

  /// 默认 HTTP 客户端（可在构造时注入自定义 Dio 以便测试）。
  static Dio _defaultDio(String baseUrl) {
    return Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
      ),
    );
  }

  /// 官方 API 地址。
  static const String defaultBaseUrl = 'https://api.deepseek.com';

  final String apiKey;
  final String _baseUrl;
  final Dio _dio;

  @override
  final String model;

  @override
  LLMKind get kind => LLMKind.deepSeek;

  /// 口语化改写系统提示词。
  static const String systemPrompt = '''
你是一位专业的有声小说口播改编编辑。请把用户提供的章节原文改写为适合语音合成朗读的中文口语化文本：
1. 忠于原意，不增删关键情节、人物与对白；
2. 使用短句与口语化表达，朗朗上口，符合中文朗读习惯；
3. 去除冗余书面修饰，避免生僻书面语；
4. 保留对话引号，对话内容可适当口语化；
5. 只输出改写后的正文，不要输出标题、注释或任何解释。''';

  @override
  Future<String> rewrite({
    required String title,
    required String rawText,
    int? maxTokens,
    double? temperature,
  }) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/chat/completions',
        data: {
          'model': model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': '章节标题：$title\n\n$rawText'},
          ],
          'max_tokens': maxTokens ?? 1500,
          'temperature': temperature ?? 0.7,
          'stream': false,
        },
        // 请求级显式携带鉴权头，保证注入自定义 Dio 时也生效。
        options: Options(
          headers: {'Authorization': 'Bearer $apiKey'},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw LLMException('DeepSeek 请求失败: ${e.message}', e);
    }

    final choices = response.data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LLMException('DeepSeek 响应缺少 choices 字段');
    }
    final content = (choices.first as Map<String, dynamic>)['message']?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw LLMException('DeepSeek 响应内容为空');
    }
    return content.trim();
  }
}
