import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'ble_protocol.dart';

class YtConfig {
  YtConfig(Map<String, dynamic> input) : values = {...defaults, ...input};
  final Map<String, dynamic> values;
  static const defaults = <String, dynamic>{
    'base_url': 'https://yt.utui.cc',
    'token': '',
    'query': '',
    'report_id': '174-145',
    'ranking_limit': 10,
    'expiration_field': 'Expiration time',
    'timezone': 'Asia/Shanghai',
    'scan_timeout_seconds': 30,
    'warning_hours': 24,
    'text_rotation': 0,
    'text_position': 'bottom_center',
  };
  String text(String key) => values[key].toString().trim();
  int number(String key) => int.parse(text(key));
  static const positions = <String, String>{
    'top_left': '左上',
    'top_center': '上中',
    'top_right': '右上',
    'center_left': '左中',
    'center': '居中',
    'center_right': '右中',
    'bottom_left': '左下',
    'bottom_center': '下中',
    'bottom_right': '右下',
  };
  void validate() {
    if (![0, 90, 180, 270].contains(number('text_rotation')) ||
        !positions.containsKey(text('text_position'))) {
      throw const FormatException('请选择四个方向和九个位置之一');
    }
    final uri = Uri.tryParse(text('base_url'));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('base_url 必须为 HTTPS 服务地址');
    }
    for (final key in [
      'token',
      'query',
      'report_id',
      'expiration_field',
      'timezone',
    ]) {
      if (text(key).isEmpty) throw FormatException('$key 不能为空');
    }
    if (number('ranking_limit') < 1 ||
        number('ranking_limit') > 50 ||
        number('scan_timeout_seconds') < 1 ||
        number('scan_timeout_seconds') > 300 ||
        number('warning_hours') < 1 ||
        number('warning_hours') > 8760) {
      throw const FormatException('排行 1–50，扫描超时 1–300 秒，预警 1–8760 小时');
    }
  }
}

class YtIssue {
  YtIssue(this.id, this.summary, this.expiration);
  final String id, summary;
  final int? expiration;
  factory YtIssue.parse(Map<String, dynamic> json, String field) {
    int? expiration;
    for (final item in (json['customFields'] as List? ?? [])) {
      if (item['name'].toString().toLowerCase() == field.toLowerCase()) {
        expiration = num.tryParse('${item['value']}')?.toInt();
        break;
      }
    }
    return YtIssue(
      '${json['idReadable'] ?? json['id']}',
      '${json['summary'] ?? ''}',
      expiration,
    );
  }
  int colorIndex(DateTime now, int hours) {
    if (expiration == null) return 0;
    final remaining = expiration! - now.millisecondsSinceEpoch;
    return remaining <= const Duration(hours: 2).inMilliseconds
        ? 3
        : remaining <= Duration(hours: hours).inMilliseconds
        ? 2
        : 0;
  }
}

class YouTrackService {
  Future<dynamic> get(
    YtConfig config,
    String path,
    Map<String, String> query,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = Uri.parse(
        '${config.text('base_url').replaceAll(RegExp(r'/+$'), '')}$path',
      ).replace(queryParameters: query);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('Authorization', 'Bearer ${config.text('token')}');
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('YouTrack HTTP ${response.statusCode}');
      }
      return jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 20)),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<YtIssue>> issues(YtConfig config) async {
    final issues = <YtIssue>[];
    while (true) {
      final page = await get(config, '/api/issues', {
        'query': config.text('query'),
        'fields': 'id,idReadable,summary,customFields(name,value)',
        '\$skip': '${issues.length}',
        '\$top': '100',
      });
      if (page is! List) throw const FormatException('Issue 数据格式错误');
      issues.addAll(
        page.map(
          (e) => YtIssue.parse(
            Map<String, dynamic>.from(e),
            config.text('expiration_field'),
          ),
        ),
      );
      if (page.length < 100) break;
    }
    issues.sort(
      (a, b) => (a.expiration ?? 8640000000000000).compareTo(
        b.expiration ?? 8640000000000000,
      ),
    );
    return issues;
  }

  Future<String> ranking(YtConfig config) async {
    final user = await get(config, '/api/users/me', {
      'fields': 'id,login,fullName',
    });
    final report = await get(
      config,
      '/api/reports/${Uri.encodeComponent(config.text('report_id'))}',
      {
        '\$top': '-1',
        'fields':
            'id,name,data(total(value,presentation),columns(name,size(value,presentation)))',
      },
    );
    final rows = report['data']?['columns'] as List? ?? [];
    final identities = [
      user['login'],
      user['fullName'],
    ].whereType<String>().map((e) => e.toLowerCase()).toSet();
    final rank = rows.indexWhere(
      (e) => identities.contains('${e['name']}'.toLowerCase()),
    );
    return [
      if (rank >= 0) '我的月榜 #${rank + 1}',
      ...rows
          .take(config.number('ranking_limit'))
          .toList()
          .asMap()
          .entries
          .map(
            (e) =>
                '${e.key + 1}. ${e.value['name']} · ${e.value['size']?['value'] ?? 0}',
          ),
    ].join('\n');
  }
}

/// Earliest deadlines first, matching the issue list; missing dates sort last.
List<({String text, int colorIndex})> ytDeadlineRows(
  List<YtIssue> issues,
  DateTime now,
  int warningHours,
) {
  final sorted = List<YtIssue>.of(issues)
    ..sort((a, b) {
      final order = (a.expiration ?? 8640000000000000).compareTo(
        b.expiration ?? 8640000000000000,
      );
      return order != 0 ? order : a.id.compareTo(b.id);
    });
  return sorted.take(3).map((issue) {
    final expiration = issue.expiration;
    final delta = expiration == null
        ? null
        : expiration - now.millisecondsSinceEpoch;
    // Round future partial minutes up: a task with 20 seconds left is not overdue.
    final minutes = delta == null
        ? null
        : delta > 0
        ? (delta + Duration.millisecondsPerMinute - 1) ~/
              Duration.millisecondsPerMinute
        : delta.abs() ~/ Duration.millisecondsPerMinute;
    final time = minutes == null
        ? '无到期时间'
        : '${delta! <= 0 ? "-" : ""}${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m';
    return (
      text: '$time  ${issue.id}',
      colorIndex: issue.colorIndex(now, warningHours),
    );
  }).toList();
}

Future<Uint8List> overlayYt(
  Uint8List base,
  List<YtIssue> issues,
  DateTime now,
  int hours,
  String timestamp, {
  int rotation = 0,
  String position = 'bottom_center',
}) async {
  if (base.length != BleProtocol.imageBytes) {
    throw const FormatException('底图数据长度错误');
  }
  final out = Uint8List.fromList(base);
  if (![0, 90, 180, 270].contains(rotation) ||
      !YtConfig.positions.containsKey(position)) {
    throw const FormatException('文字方向或位置无效');
  }
  final overdue = issues
      .where(
        (e) =>
            e.expiration != null && e.expiration! <= now.millisecondsSinceEpoch,
      )
      .length;
  final red = issues.where((e) => e.colorIndex(now, hours) == 3).length;
  final yellow = issues.where((e) => e.colorIndex(now, hours) == 2).length;
  final color = red > 0
      ? const ui.Color(0xFFC80000)
      : yellow > 0
      ? const ui.Color(0xFFF5CD00)
      : const ui.Color(0xFF000000);
  final deadlines = ytDeadlineRows(issues, now, hours);
  ui.Color deadlineColor(int index) => switch (index) {
    3 => const ui.Color(0xFFC80000),
    2 => const ui.Color(0xFFF5CD00),
    _ => const ui.Color(0xFF000000),
  };
  final rows = <Map<String, Object>>[];
  void text(String value, double size, double y, ui.Color color) {
    rows.add({'text': value, 'size': size, 'y': y, 'color': color.toARGB32()});
  }

  text('YT 剩余：${issues.length}', 40, 4, color);
  text(
    '已过期：$overdue    即将到期：${issues.where((e) => e.expiration != null && e.expiration! > now.millisecondsSinceEpoch && e.colorIndex(now, hours) != 0).length}',
    18,
    55,
    const ui.Color(0xFF000000),
  );
  for (var i = 0; i < deadlines.length; i++) {
    final row = deadlines[i];
    text(row.text, 40, 82 + i * 52.0, deadlineColor(row.colorIndex));
  }
  text('更新：$timestamp', 16, 244, const ui.Color(0xFF000000));

  late img.Image panel;
  Uint8List? nativePng;
  if (Platform.isMacOS) {
    try {
      nativePng = await const MethodChannel('epd/background')
          .invokeMethod<Uint8List>('renderText', rows)
          .timeout(const Duration(seconds: 20));
      if (nativePng == null) throw StateError('CPU 文字绘制返回空数据');
    } on MissingPluginException {
      // Flutter widget tests and non-native hosts use the portable renderer.
    }
  }
  if (nativePng != null) {
    final decoded = img.decodePng(nativePng);
    if (decoded == null) throw StateError('CPU 文字图像解码失败');
    panel = decoded;
  } else {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (final row in rows) {
      final value = row['text'] as String;
      final size = row['size'] as double;
      final y = row['y'] as double;
      final color = ui.Color(row['color'] as int);
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: 'PingFang SC',
            fontFamilyFallback: const ['Heiti SC', 'Arial'],
            fontSize: size,
            color: color,
            height: 1,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        locale: const ui.Locale('zh', 'CN'),
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 456);
      painter.paint(canvas, ui.Offset(12, y));
      painter.dispose();
    }

    final picture = recorder.endRecording();
    final raster = await picture
        .toImage(480, 264)
        .timeout(const Duration(seconds: 20));
    try {
      final rgba = await raster.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (rgba == null) throw StateError('文字图像生成失败');
      panel = img.Image.fromBytes(
        width: 480,
        height: 264,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
      );
    } finally {
      raster.dispose();
      picture.dispose();
    }
  }
  if (rotation != 0) panel = img.copyRotate(panel, angle: rotation);
  final column = position.endsWith('left')
      ? 0
      : position.endsWith('right')
      ? 2
      : 1;
  final row = position.startsWith('top')
      ? 0
      : position.startsWith('bottom')
      ? 2
      : 1;
  final left = (BleProtocol.imageWidth - panel.width) * column ~/ 2;
  final top = (BleProtocol.imageHeight - panel.height) * row ~/ 2;
  for (var y = 0; y < panel.height; y++) {
    for (var x = 0; x < panel.width; x++) {
      final p = panel.getPixel(x, y);
      if (p.a == 0) continue;
      final offset = (top + y) * BleProtocol.rowBytes + (left + x) ~/ 4;
      final shift = 6 - 2 * ((left + x) % 4);
      const palette = [
        [0, 0, 0],
        [255, 255, 255],
        [245, 205, 0],
        [200, 0, 0],
      ];
      final background = palette[(out[offset] >> shift) & 3];
      final alpha = p.a / 255;
      final r = p.r * alpha + background[0] * (1 - alpha);
      final g = p.g * alpha + background[1] * (1 - alpha);
      final b = p.b * alpha + background[2] * (1 - alpha);
      // Quantize antialiased text with the same four physical display colors.
      var index = 0;
      var distance = double.infinity;
      for (var i = 0; i < palette.length; i++) {
        final c = palette[i];
        final d =
            (r - c[0]) * (r - c[0]) +
            (g - c[1]) * (g - c[1]) +
            (b - c[2]) * (b - c[2]);
        if (d < distance) {
          distance = d.toDouble();
          index = i;
        }
      }

      out[offset] = (out[offset] & ~(3 << shift)) | (index << shift);
    }
  }
  return out;
}

/// Decode the exact bytes sent to the device, so preview and send share pixels.
Uint8List packedYtPreview(Uint8List packed) {
  if (packed.length != BleProtocol.imageBytes) {
    throw const FormatException('图像长度错误');
  }
  const palette = [
    [0, 0, 0],
    [255, 255, 255],
    [245, 205, 0],
    [200, 0, 0],
  ];
  final image = img.Image(
    width: BleProtocol.imageWidth,
    height: BleProtocol.imageHeight,
  );
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final c =
          palette[(packed[y * BleProtocol.rowBytes + x ~/ 4] >>
                  (6 - 2 * (x % 4))) &
              3];
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}
