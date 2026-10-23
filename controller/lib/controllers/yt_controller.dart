import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../services/youtrack_service.dart';
import 'app_controllers.dart';

class YtController extends GetxController {
  final enabled = false.obs, busy = false.obs;
  final message = '尚未更新'.obs, ranking = ''.obs;
  final issues = <YtIssue>[].obs;
  final hasData = false.obs;
  final service = YouTrackService();
  static const channel = MethodChannel('epd/background');
  Box<dynamic> get box => Hive.box<dynamic>('settings');
  YtConfig get config => YtConfig(
    Map<String, dynamic>.from(
      box.get('yt.config', defaultValue: <String, dynamic>{}) as Map,
    ),
  );
  Timer? timer;
  int _generation = 0;
  @override
  void onInit() {
    super.onInit();
    tzdata.initializeTimeZones();
    enabled.value = box.get('yt.enabled', defaultValue: false) as bool;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'wake' && enabled.value) await updateStatus();
    });
    if (enabled.value) {
      _start();
    }
  }

  Future<Map<String, dynamic>?> importConfig() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON 配置', extensions: ['json']),
      ],
    );
    if (file == null) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) throw const FormatException('配置必须为 JSON 对象');
    return Map<String, dynamic>.fromEntries(
      Map<String, dynamic>.from(
        json,
      ).entries.where((e) => YtConfig.defaults.containsKey(e.key)),
    );
  }

  Future<void> save(Map<String, dynamic> values) async {
    final next = YtConfig(values);
    next.validate();
    tz.getLocation(next.text('timezone'));
    _generation++;
    await box.put('yt.config', next.values);
    await box.put(
      'yt.scan_timeout_seconds',
      next.number('scan_timeout_seconds'),
    );
    message.value = '配置已保存';
  }

  Future<void> setEnabled(bool value) async {
    if (value) {
      config.validate();
      tz.getLocation(config.text('timezone'));
    }
    _generation++;
    enabled.value = value;
    await box.put('yt.enabled', value);
    timer?.cancel();
    if (Platform.isMacOS) await channel.invokeMethod('setEnabled', value);
    if (value) _start();
  }

  void _start() {
    if (Platform.isMacOS) unawaited(channel.invokeMethod('setEnabled', true));
    timer?.cancel();
    timer = Timer.periodic(const Duration(minutes: 10), (_) => updateStatus());
    unawaited(updateStatus());
  }

  String date(int? milliseconds) {
    if (milliseconds == null) return '无过期时间';
    return tz.TZDateTime.fromMillisecondsSinceEpoch(
      tz.getLocation(config.text('timezone')),
      milliseconds,
    ).toString().substring(0, 16);
  }

  Future<void> updateStatus({bool send = true}) async {
    if (busy.value) return;
    busy.value = true;
    final generation = _generation;
    final current = config;
    try {
      current.validate();
      final found = await service.issues(current);
      if (generation != _generation) return;
      hasData.value = true;
      issues.assignAll(found);
      final base = box.get('lastBaseImage');
      if (!send) {
        message.value = '剩余 ${found.length} 条 · 已更新预览数据，未发送';
      } else if (base is! List) {
        message.value = '剩余 ${found.length} 条；请先正常发送一张底图';
      } else {
        final now = DateTime.now();
        final local = tz.TZDateTime.from(
          now,
          tz.getLocation(current.text('timezone')),
        );
        final overlay = await overlayYt(
          Uint8List.fromList(base.cast<int>()),
          found,
          now,
          current.number('warning_hours'),
          local.toString().substring(0, 16),
          rotation: current.number('text_rotation'),
          position: current.text('text_position'),
        );
        if (generation != _generation) return;
        final ok = await Get.find<BleController>().sendImage(
          overlay,
          sourceName: 'YT 状态',
          retainBase: false,
          scanTimeoutSeconds: current.number('scan_timeout_seconds'),
        );
        message.value = ok
            ? '剩余 ${found.length} 条 · ${local.toString().substring(0, 19)} 已刷新'
            : Get.find<BleController>().message.value;
      }
      try {
        ranking.value = await service.ranking(current);
      } catch (_) {
        ranking.value = '月榜加载失败（不影响剩余数量）';
      }
    } catch (e) {
      message.value = '更新失败：$e';
    } finally {
      busy.value = false;
    }
  }

  @override
  void onClose() {
    timer?.cancel();
    channel.setMethodCallHandler(null);
    super.onClose();
  }
}
