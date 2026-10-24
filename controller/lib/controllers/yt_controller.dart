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
import '../services/clock_out_service.dart';
import 'app_controllers.dart';

class YtController extends GetxController {
  final enabled = false.obs, busy = false.obs;
  final message = '尚未更新'.obs, ranking = ''.obs;
  final issues = <YtIssue>[].obs;
  final hasData = false.obs;
  final backgroundStatus = '后台尚未启用'.obs;
  final events = <String>[].obs;
  final service = YouTrackService();
  final clockData = Rxn<ClockOutData>();
  final clockStatus = '下班：未配置'.obs;
  String clockLabel(YtConfig draft, DateTime now) =>
      clockData.value?.label(
        now,
        draft.number('work_hours'),
        draft.text('timezone'),
      ) ??
      clockStatus.value;

  Future<Map<String, dynamic>?> importClockConfig() async {
    final file = await openFile(
      initialDirectory: '/Users/cd022/HBWuChang/code/clockOut/clockOut',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'clockOut Swift 配置', extensions: ['swift']),
      ],
    );
    if (file == null) return null;
    return ClockOutService.importSwift(await file.readAsString());
  }

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
    events.assignAll(
      (box.get('yt.events', defaultValue: <String>[]) as List).cast<String>(),
    );
    channel.setMethodCallHandler((call) async {
      if ((call.method == 'wake' || call.method == 'tick') && enabled.value) {
        await updateStatus(trigger: call.method);
      }
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
    if (value) {
      await _start();
    } else if (Platform.isMacOS) {
      await _configureNative(false);
    }
  }

  Future<void> _configureNative(bool value) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final status = await channel
            .invokeMapMethod<String, dynamic>('setEnabled', value)
            .timeout(const Duration(seconds: 5));
        if (value && status?['sleepAssertion'] != true) {
          throw StateError('未能建立防睡眠断言');
        }
        backgroundStatus.value = value ? '原生定时器已启用 · 防睡眠断言已建立' : '后台已关闭';
        logEvent(value ? '后台原生定时器和防睡眠已启用' : '后台已关闭');
        return;
      } on MissingPluginException {
        if (attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _start() async {
    timer?.cancel();
    if (Platform.isMacOS) {
      try {
        await _configureNative(true);
      } catch (e) {
        backgroundStatus.value = '后台初始化失败：$e';
        logEvent('后台初始化失败 (${e.runtimeType})');
        return;
      }
    } else {
      timer = Timer.periodic(
        const Duration(minutes: 10),
        (_) => updateStatus(trigger: 'timer'),
      );
    }
    unawaited(updateStatus(trigger: 'startup'));
  }

  void logEvent(String value) {
    events.insert(
      0,
      '${DateTime.now().toIso8601String().substring(0, 19)} $value',
    );
    if (events.length > 60) events.removeRange(60, events.length);
    unawaited(box.put('yt.events', events.toList()));
  }

  String date(int? milliseconds) {
    if (milliseconds == null) return '无过期时间';
    return tz.TZDateTime.fromMillisecondsSinceEpoch(
      tz.getLocation(config.text('timezone')),
      milliseconds,
    ).toString().substring(0, 16);
  }

  Future<void> updateStatus({
    bool send = true,
    String trigger = 'manual',
  }) async {
    if (busy.value) {
      logEvent('$trigger 跳过：前次任务仍在进行');
      return;
    }
    logEvent('$trigger 开始查询');
    busy.value = true;
    final generation = _generation;
    final current = config;
    try {
      current.validate();
      final found = await service.issues(current);
      if (generation != _generation) return;
      logEvent('查询完成：${found.length} 条');
      clockData.value = null;
      if (current.text('clock_token').isEmpty ||
          current.text('clock_url').isEmpty) {
        clockStatus.value = '下班：未配置';
      } else {
        try {
          clockData.value = await ClockOutService().fetch(current);
          clockStatus.value = clockLabel(current, DateTime.now());
        } catch (_) {
          clockStatus.value = '下班：查询失败';
          logEvent('打卡查询失败（不影响 YT 更新）');
        }
      }
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
        logEvent('开始 CPU 文字绘制');
        final overlay = await overlayYt(
          Uint8List.fromList(base.cast<int>()),
          found,
          now,
          current.number('warning_hours'),
          local.toString().substring(0, 16),
          rotation: current.number('text_rotation'),
          position: current.text('text_position'),
          clockLabel: clockLabel(current, now),
          clockMetrics: clockData.value?.metrics ?? 'WK:-- ALL:-- S:--',
        );
        if (generation != _generation) return;
        logEvent('文字绘制完成，开始蓝牙发送');
        final ok = await Get.find<BleController>().sendImage(
          overlay,
          sourceName: 'YT 状态',
          retainBase: false,
          scanTimeoutSeconds: current.number('scan_timeout_seconds'),
        );
        logEvent(ok ? '设备刷新成功，已断开蓝牙' : '蓝牙发送或刷新失败');
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
      logEvent('更新失败 (${e.runtimeType})');
      message.value = '更新失败：$e';
    } finally {
      busy.value = false;
      logEvent('任务结束');
    }
  }

  @override
  void onClose() {
    timer?.cancel();
    channel.setMethodCallHandler(null);
    super.onClose();
  }
}
