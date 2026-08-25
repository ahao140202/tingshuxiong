import 'package:dio/dio.dart';

import '../../domain/domain.dart';
import '../llm_provider.dart';

/// DeepSeek 章节修订实现（OpenAI 兼容 `/chat/completions` 协议）。
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

  /// 章节修订系统提示词：最小改动 + 错别字矫正 + 朗读友好润色。
  static const String systemPrompt = '''
你是一位专业的有声小说口播稿件编辑。请对用户提供的章节原文做尽可能小的修订，输出适合语音合成朗读的中文口播稿：
1. 错别字矫正：纠正错别字、笔误与明显标点错误；
2. 文从字顺：仅对明显不通顺、拗口的句子做最小调整，使其通顺易读；
3. 润色表达：在不改变原意的前提下微调用词与语序，更符合听众听觉习惯与小说朗读稿的语感；
4. 尽可能小的改动：非必要不修改原文原字；不增删、不改写关键情节、人物、对白与叙事逻辑，未发现问题之处保持原文原样；
5. 保留对话引号，对话内容可适当口语化；
6. 只输出修订后的正文，不要输出标题、注释或任何解释。''';

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
