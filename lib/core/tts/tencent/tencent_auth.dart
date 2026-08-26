import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 腾讯云 API 3.0（TC3-HMAC-SHA256）请求签名。
///
/// 仅覆盖本应用 TTS 场景（POST + JSON 请求体），签名行为与腾讯云官方 SDK
/// （tencentcloud-sdk-python common/abstract_client.py）一致：
/// - CanonicalRequest 的签名头固定为 `content-type` 与 `host` 两个；
/// - 无查询串（POST），请求路径固定 `/`；
/// - service 为 `tts`，credential scope 为 `{date}/tts/tc3_request`。
///
/// 使用 [crypto] 包的 Hmac/Sha256 实现，可独立单测。
class TencentSigner {
  TencentSigner({
    required this.secretId,
    required this.secretKey,
    this.service = 'tts',
  });

  final String secretId;
  final String secretKey;

  /// 云服务名（TTS 为 `tts`）。
  final String service;

  /// 生成 `Authorization` 请求头。
  ///
  /// [timestamp] 为 Unix 秒（注入便于测试固定值）；[payload] 为请求体
  /// JSON 字符串；[host] 为请求 Host（如 `tts.tencentcloudapi.com`），
  /// 需与请求实际 Host 一致。
  String authorization({
    required int timestamp,
    required String payload,
    required String host,
  }) {
    final date = _formatDate(timestamp);
    final canonicalHeaders =
        'content-type:application/json; charset=utf-8\nhost:$host\n';
    const signedHeaders = 'content-type;host';
    final canonicalRequest = 'POST\n/\n\n$canonicalHeaders\n'
        '$signedHeaders\n${_sha256Hex(utf8.encode(payload))}';
    final stringToSign = 'TC3-HMAC-SHA256\n$timestamp\n'
        '$date/$service/tc3_request\n${_sha256Hex(utf8.encode(canonicalRequest))}';

    final kDate = Hmac(sha256, utf8.encode('TC3$secretKey'))
        .convert(utf8.encode(date))
        .bytes;
    final kService =
        Hmac(sha256, kDate).convert(utf8.encode(service)).bytes;
    final kSigning =
        Hmac(sha256, kService).convert(utf8.encode('tc3_request')).bytes;
    final signature =
        Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();

    return 'TC3-HMAC-SHA256 Credential=$secretId/$date/$service/tc3_request, '
        'SignedHeaders=$signedHeaders, Signature=$signature';
  }

  /// Unix 秒 → `YYYY-MM-DD`（UTC）。
  static String _formatDate(int timestamp) {
    final utc = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000,
        isUtc: true);
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
}
