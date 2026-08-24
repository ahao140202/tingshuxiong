/// 讯飞 WebAPI 鉴权工具（HMAC-SHA256 签名）。
///
/// 参考：https://www.xfyun.cn/doc/tts/online_tts/API.html
/// 纯函数、无状态、可单测（golden 向量验证）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 生成 RFC1123 GMT 格式的 HTTP 日期头，如 `Mon, 24 Aug 2026 08:00:00 GMT`。
String formatHttpDate(DateTime utc) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final d = utc.toUtc();
  final dd = d.day.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  final ss = d.second.toString().padLeft(2, '0');
  return '${weekdays[d.weekday - 1]}, $dd ${months[d.month - 1]} ${d.year} $hh:$mm:$ss GMT';
}

/// 生成 Authorization 头。
///
/// [host] 为 API 主机名（如 `tts-api.xfyun.cn`），[date] 为 RFC1123 GMT 日期，
/// [requestLine] 形如 `GET /v2/tts HTTP/1.1`。
String buildAuthorization({
  required String apiKey,
  required String apiSecret,
  required String host,
  required String date,
  required String requestLine,
}) {
  final signatureOrigin = 'host: $host\ndate: $date\n$requestLine';
  final hmac = Hmac(sha256, utf8.encode(apiSecret));
  final digest = hmac.convert(utf8.encode(signatureOrigin));
  final signature = base64Encode(digest.bytes);
  return 'api_key="$apiKey", algorithm="hmac-sha256", '
      'headers="host date request-line", signature="$signature"';
}
