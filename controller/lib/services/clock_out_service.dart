import 'dart:convert';
import 'dart:io';
import 'package:timezone/timezone.dart' as tz;
import 'youtrack_service.dart';

class ClockOutData {
  ClockOutData(
    this.clockIn,
    this.restDay,
    this.fetchedAt, {
    this.totalStruggleOt = '--',
    this.striver = '--',
    this.lateAndEarlyRemaining = '--',
  });
  final String totalStruggleOt, striver, lateAndEarlyRemaining;
  String get metrics =>
      '末:$totalStruggleOt 总:$striver 迟:$lateAndEarlyRemaining';
  factory ClockOutData.fromJson(Map data, DateTime fetchedAt) => ClockOutData(
    data['clockInTime'] as String?,
    data['isRestDay'] == true,
    fetchedAt,
    totalStruggleOt: data['totalStruggleOt']?.toString() ?? '--',
    striver: data['striver']?.toString() ?? '--',
    lateAndEarlyRemaining: data['lateAndEarlyRemaining']?.toString() ?? '--',
  );
  final String? clockIn;
  final bool restDay;
  final DateTime fetchedAt;

  String label(DateTime now, int hours, String timezone) {
    final location = tz.getLocation(timezone);
    final local = tz.TZDateTime.from(now, location);
    final fetched = tz.TZDateTime.from(fetchedAt, location);
    if (local.year != fetched.year ||
        local.month != fetched.month ||
        local.day != fetched.day) {
      return '下班：等待更新';
    }
    final match = RegExp(
      r'^(\d{1,2}):(\d{2}):(\d{2})$',
    ).firstMatch(clockIn ?? '');
    if (match == null) return '下班：尚未打卡';
    final h = int.parse(match[1]!),
        m = int.parse(match[2]!),
        s = int.parse(match[3]!);
    if (h > 23 || m > 59 || s > 59) return '下班：打卡时间异常';
    final target = tz.TZDateTime(
      location,
      local.year,
      local.month,
      local.day,
      h,
      m,
      s,
    ).add(Duration(hours: hours));
    final milliseconds =
        target.millisecondsSinceEpoch - now.millisecondsSinceEpoch;
    if (milliseconds <= 0) return '可以下班了';
    final minutes = (milliseconds + 59999) ~/ 60000;
    return '还有${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m下班';
  }
}

class ClockOutService {
  Future<ClockOutData> fetch(YtConfig config) async {
    final uri = Uri.tryParse(config.text('clock_url'));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        config.text('clock_token').isEmpty) {
      throw const FormatException('未配置打卡接口');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json, text/plain, */*');
      request.headers.set('x-access-token', config.text('clock_token'));
      request.headers.set('Referer', 'https://rc.workingmanual.com/');
      request.headers.set('Origin', 'https://rc.workingmanual.com');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('打卡 HTTP ${response.statusCode}');
      }
      final result = jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 20)),
      );
      if (result is! Map ||
          '${result['code']}' != '8200' ||
          result['data'] is! Map) {
        throw const FormatException('打卡接口返回异常');
      }
      final data = result['data'] as Map;
      return ClockOutData.fromJson(data, DateTime.now());
    } finally {
      client.close(force: true);
    }
  }

  /// Extract only the endpoint and header from the existing clockOut Swift file.
  static Map<String, dynamic> importSwift(String source) {
    final url = RegExp(
      r'URL\(string:\s*"([^"]*getUserClock[^\"]*)"',
    ).firstMatch(source)?.group(1);
    final token = RegExp(
      r'request\.setValue\("([^"\r\n]+)",\s*forHTTPHeaderField:\s*"x-access-token"\)',
    ).firstMatch(source)?.group(1);
    if (url == null || token == null) {
      throw const FormatException('未找到 clockOut 接口或 Token');
    }
    return {'clock_url': url, 'clock_token': token};
  }
}
