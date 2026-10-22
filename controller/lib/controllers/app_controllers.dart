import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../services/ble_protocol.dart';
import '../services/image_pipeline.dart';

class SettingsController extends GetxController {
  late final Box<dynamic> _box;

  @override
  void onInit() {
    super.onInit();
    _box = Hive.box<dynamic>('settings');
  }

  String get lastDeviceName =>
      (_box.get('lastDeviceName') as String?) ?? '';

  String get lastDeviceId => (_box.get('lastDeviceId') as String?) ?? '';

  void saveLastDevice(BluetoothDevice device) {
    _box.put('lastDeviceId', device.remoteId.str);
    _box.put('lastDeviceName', device.platformName);
    update();
  }
}

class HistoryController extends GetxController {
  late final Box<dynamic> _box;
  final records = <Map<String, dynamic>>[].obs;

  @override
  void onInit() {
    super.onInit();
    _box = Hive.box<dynamic>('history');
    reload();
  }

  void reload() {
    final list = <Map<String, dynamic>>[];
    for (final value in _box.values) {
      if (value is Map) {
        list.add(Map<String, dynamic>.from(value));
      }
    }
    list.sort((a, b) =>
        ((b['timestamp'] as num?) ?? 0).compareTo((a['timestamp'] as num?) ?? 0));
    records.assignAll(list);
  }

  Future<void> add({
    required String fileName,
    required int bytes,
    required int durationMs,
    required String deviceName,
    String? sourcePath,
  }) async {
    await _box.add({
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'fileName': fileName,
      'bytes': bytes,
      'durationMs': durationMs,
      'deviceName': deviceName,
      'sourcePath': sourcePath,
    });
    reload();
  }

  /// Whether the originally selected file of [record] is still readable.
  bool hasSource(Map<String, dynamic> record) {
    final path = record['sourcePath'];
    return path is String && path.isNotEmpty && File(path).existsSync();
  }

  Future<Uint8List?> readSource(Map<String, dynamic> record) async {
    final path = record['sourcePath'];
    if (path is! String || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> clear() async {
    await _box.clear();
    records.clear();
  }
}

class ImageController extends GetxController {
  static const _keyDither = 'editor.dither';
  static const _keyCropAngle = 'editor.cropAngle';
  static const _keyBlankColor = 'editor.blankColor';

  final originalBytes = Rxn<Uint8List>();
  final sourcePath = Rxn<String>();
  final previewPng = Rxn<Uint8List>();
  final packed = Rxn<Uint8List>();
  final fileName = '未选择图片'.obs;
  final rotation = 0.obs;
  final cropAngle = 0.obs;
  final cropRect = const Rect.fromLTRB(0, 0, 1, 1).obs;
  final blankColor = const Color(0xFFFFFFFF).obs;
  final displayBytes = Rxn<Uint8List>();
  final displaySize = Rxn<Size>();
  final dither = false.obs;
  final processing = false.obs;
  final error = ''.obs;
  final viewResetToken = 0.obs;
  final renderToken = 0.obs;

  Timer? _debounce;
  int _renderToken = 0;
  int _displayToken = 0;

  static const cropAngles = <int>[0, 90, 180, 270];

  bool get hasImage => originalBytes.value != null;
  bool get hasResult => packed.value != null;

  Box<dynamic>? get _settingsBox =>
      Hive.isBoxOpen('settings') ? Hive.box<dynamic>('settings') : null;

  @override
  void onInit() {
    super.onInit();
    final box = _settingsBox;
    if (box == null) return;

    final savedDither = box.get(_keyDither);
    if (savedDither is bool) dither.value = savedDither;

    final savedAngle = box.get(_keyCropAngle);
    if (savedAngle is int && cropAngles.contains(savedAngle)) {
      cropAngle.value = savedAngle;
    }

    final savedColor = box.get(_keyBlankColor);
    if (savedColor is int) blankColor.value = Color(savedColor);
  }

  /// Aspect ratio of the fixed crop frame for the current [cropAngle].
  double get cropAspectRatio =>
      cropAngle.value % 180 == 0
          ? BleProtocol.imageWidth / BleProtocol.imageHeight
          : BleProtocol.imageHeight / BleProtocol.imageWidth;

  Size? get rotatedImageSize => displaySize.value;

  Future<void> pickImage() async {
    try {
      const typeGroup = XTypeGroup(
        label: '图片',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;

      final bytes = await file.readAsBytes();
      await loadSource(bytes, file.name, path: file.path);
    } catch (e) {
      error.value = '读取图片失败：$e';
    }
  }

  Future<void> loadTestPattern() async {
    try {
      await loadSource(createTestPatternPng(), '四色测试图');
    } catch (e) {
      error.value = '读取测试图失败：$e';
    }
  }

  Future<void> loadSource(Uint8List bytes, String name, {String? path}) async {
    originalBytes.value = bytes;
    sourcePath.value = path;
    fileName.value = name;
    rotation.value = 0;
    cropRect.value = const Rect.fromLTRB(0, 0, 1, 1);
    previewPng.value = null;
    packed.value = null;
    error.value = '';
    await _loadDisplay();
    // The editor rebuilds its view and pushes the real crop rect afterwards.
    viewResetToken.value++;
  }

  Future<void> _loadDisplay() async {
    final source = originalBytes.value;
    if (source == null) return;
    final token = ++_displayToken;
    final rotationValue = rotation.value;
    try {
      final display = await buildDisplayImage(
        sourceBytes: source,
        rotation: rotationValue,
      );
      if (token != _displayToken) return;
      displayBytes.value = display.png;
      displaySize.value = Size(
        display.width.toDouble(),
        display.height.toDouble(),
      );
    } catch (e) {
      if (token == _displayToken) error.value = '读取图片失败：$e';
    }
  }

  void rotateBy(int degrees) {
    if (!hasImage) return;
    rotation.value = (rotation.value + degrees) % 360;
    if (rotation.value < 0) rotation.value += 360;
    // The editor keeps its current zoom/pan, as agreed.
    _loadDisplay();
  }

  void setCropAngle(int angle) {
    if (!hasImage) return;
    final normalized = ((angle % 360) + 360) % 360;
    if (normalized == cropAngle.value) return;
    cropAngle.value = normalized;
    _settingsBox?.put(_keyCropAngle, normalized);
    // The editor resets the view for the new frame ratio and pushes the rect.
    viewResetToken.value++;
  }

  /// Called by the editor whenever the visible crop region changes.
  ///
  /// [commit] triggers a (debounced) re-render; during an active drag the editor
  /// only updates the rect so the preview is not recomputed mid-gesture.
  void setCropRect(Rect value, {bool commit = false}) {
    final current = cropRect.value;
    final changed = (current.left - value.left).abs() > 1e-6 ||
        (current.top - value.top).abs() > 1e-6 ||
        (current.right - value.right).abs() > 1e-6 ||
        (current.bottom - value.bottom).abs() > 1e-6;
    if (changed) cropRect.value = value;
    if (commit) {
      _debounce?.cancel();
      render();
    }
  }

  void resetCrop() {
    if (!hasImage) return;
    viewResetToken.value++;
  }

  void setBlankColor(Color value) {
    if (blankColor.value == value) return;
    blankColor.value = value;
    _settingsBox?.put(_keyBlankColor, value.toARGB32());
    _scheduleRender();
  }

  void setDither(bool value) {
    if (dither.value == value) return;
    dither.value = value;
    _settingsBox?.put(_keyDither, value);
    render();
  }

  void _scheduleRender() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), render);
  }

  Future<void> render() async {
    final source = originalBytes.value;
    if (source == null) return;

    final token = ++_renderToken;
    final rect = cropRect.value;
    processing.value = true;
    error.value = '';

    try {
      final result = await renderImage(
        sourceBytes: source,
        rotation: rotation.value,
        cropLeft: rect.left,
        cropTop: rect.top,
        cropRight: rect.right,
        cropBottom: rect.bottom,
        cropAngle: cropAngle.value,
        blankColor: blankColor.value.toARGB32() & 0xFFFFFF,
        dither: dither.value,
      );
      if (token != _renderToken) return;
      previewPng.value = result.previewPng;
      packed.value = result.packed;
      renderToken.value++;
    } catch (e) {
      if (token == _renderToken) {
        error.value = '生成预览失败：$e';
        previewPng.value = null;
        packed.value = null;
      }
    } finally {
      if (token == _renderToken) processing.value = false;
    }
  }

  String get info {
    final p = packed.value;
    if (p == null) return '768×552 · 2bpp · 105984 字节';
    return '${BleProtocol.imageWidth}×${BleProtocol.imageHeight} · '
        '2bpp · 抖动${dither.value ? '开' : '关'} · ${p.length} 字节 · CRC32 '
        '${BleProtocol.crc32(p).toRadixString(16).toUpperCase().padLeft(8, '0')}';
  }

  @override
  void onClose() {
    _debounce?.cancel();
    super.onClose();
  }
}

class BleController extends GetxController {
  final adapterState = BluetoothAdapterState.unknown.obs;
  final scanning = false.obs;
  final connectable = false.obs;
  final connecting = false.obs;
  final connected = false.obs;
  final sending = false.obs;
  final scanResults = <ScanResult>[].obs;
  final device = Rxn<BluetoothDevice>();
  final controlChar = Rxn<BluetoothCharacteristic>();
  final statusChar = Rxn<BluetoothCharacteristic>();
  final infoChar = Rxn<BluetoothCharacteristic>();
  final status = EpdStatus.idle.obs;
  final progress = 0.0.obs;
  final message = ''.obs;
  final deviceInfo = ''.obs;
  final mtu = 0.obs;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<dynamic>? _connectionSub;
  Completer<EpdStatus>? _commitCompleter;

  @override
  void onInit() {
    super.onInit();
    _subscriptions.add(
      FlutterBluePlus.adapterState.listen((state) {
        adapterState.value = state;
      }),
    );
    _subscriptions.add(
      FlutterBluePlus.isScanning.listen((value) {
        scanning.value = value;
      }),
    );
    _subscriptions.add(
      FlutterBluePlus.onScanResults.listen(_onScanResults),
    );
  }

  void _onScanResults(List<ScanResult> results) {
    final filtered = <ScanResult>[];
    for (final r in results) {
      final name = _advertisedName(r);
      final uuidMatch = r.advertisementData.serviceUuids.any(
        (g) => g.str.toLowerCase() == BleProtocol.serviceUuid,
      );
      if (uuidMatch ||
          name.toUpperCase().contains('HUAWEI') ||
          name.toUpperCase().contains('EPD')) {
        filtered.add(r);
      }
    }
    filtered.sort((a, b) => b.rssi.compareTo(a.rssi));
    scanResults.assignAll(filtered);
  }

  String _advertisedName(ScanResult r) {
    if (r.device.platformName.isNotEmpty) return r.device.platformName;
    return r.advertisementData.advName;
  }

  String scanName(ScanResult r) {
    final name = _advertisedName(r);
    return name.isEmpty ? r.device.remoteId.str : name;
  }

  Future<void> scan() async {
    if (adapterState.value != BluetoothAdapterState.on) {
      message.value = '请先打开系统蓝牙';
      return;
    }
    scanResults.clear();
    message.value = '正在扫描 ${BleProtocol.deviceName}…';
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      message.value = '扫描失败：$e';
    }
  }

  Future<void> connectTo(ScanResult result) async {
    if (connecting.value || connected.value) return;

    connecting.value = true;
    message.value = '正在连接…';
    try {
      final d = result.device;
      await d.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 20),
      );

      device.value = d;
      _connectionSub?.cancel();
      _connectionSub = d.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnected();
        }
      });

      final services = await d.discoverServices();
      BluetoothService? service;
      for (final s in services) {
        if (s.uuid.str.toLowerCase() == BleProtocol.serviceUuid) {
          service = s;
          break;
        }
      }
      if (service == null) {
        throw StateError('未找到 EPD 服务');
      }

      for (final c in service.characteristics) {
        switch (c.uuid.str.toLowerCase()) {
          case BleProtocol.controlUuid:
            controlChar.value = c;
            break;
          case BleProtocol.statusUuid:
            statusChar.value = c;
            break;
          case BleProtocol.infoUuid:
            infoChar.value = c;
            break;
        }
      }

      if (controlChar.value == null || statusChar.value == null) {
        throw StateError('BLE 特征值不完整');
      }

      final infoBytes = await infoChar.value?.read();
      if (infoBytes != null && infoBytes.isNotEmpty) {
        deviceInfo.value = String.fromCharCodes(infoBytes);
      }

      final negotiatedMtu = await _waitMtu(d);
      mtu.value = negotiatedMtu;
      connected.value = true;
      message.value = '已连接';
      Get.find<SettingsController>().saveLastDevice(d);
    } catch (e) {
      message.value = '连接失败：$e';
      await _safeDisconnect();
    } finally {
      connecting.value = false;
    }
  }

  Future<int> _waitMtu(BluetoothDevice d) async {
    for (var i = 0; i < 20; i++) {
      if (d.mtuNow > 23) return d.mtuNow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return d.mtuNow;
  }

  void _onStatusBytes(List<int> bytes) {
    final s = EpdStatus.fromBytes(bytes);
    status.value = s;
    if (s.total > 0) {
      progress.value = s.progress;
    }
    if (s.isFinished &&
        _commitCompleter != null &&
        !_commitCompleter!.isCompleted) {
      _commitCompleter!.complete(s);
    }
  }

  Future<void> sendImage(Uint8List image, {required String sourceName}) async {
    final ctrl = controlChar.value;
    final stat = statusChar.value;
    final d = device.value;

    if (!connected.value ||
        ctrl == null ||
        stat == null ||
        d == null) {
      message.value = '请先连接设备';
      return;
    }
    if (image.length != BleProtocol.imageBytes) {
      message.value = '图像长度错误：${image.length}';
      return;
    }
    if (sending.value) return;

    sending.value = true;
    progress.value = 0;
    status.value = EpdStatus.idle;
    message.value = '准备发送…';

    // Capture the source now: the user may load another image while the BLE
    // transfer is in progress.
    final historySourcePath = Get.find<ImageController>().sourcePath.value;
    final started = DateTime.now();
    try {
      final negotiatedMtu = await _waitMtu(d);
      final packetLimit = math.min(
        BleProtocol.maxPacket,
        math.max(20, negotiatedMtu - 3),
      );
      final dataLimit = packetLimit - 5;
      mtu.value = negotiatedMtu;

      message.value = '发送 START（MTU $negotiatedMtu）…';
      await ctrl.write(
        BleProtocol.startPacket(image),
        withoutResponse: false,
        timeout: 15,
      );

      var offset = 0;
      var packetIndex = 0;
      while (offset < image.length) {
        final end = math.min(offset + dataLimit, image.length);
        final chunk = Uint8List.sublistView(image, offset, end);
        await ctrl.write(
          BleProtocol.dataPacket(offset, chunk),
          // Data is write-without-response for throughput. START/COMMIT
          // remain acknowledged. The firmware checks every offset.
          withoutResponse: true,
          timeout: 15,
        );
        offset = end;
        packetIndex++;
        progress.value = offset / image.length;
        if ((packetIndex & 15) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      }

      message.value = '等待设备接收完成…';
      var received = false;
      for (var i = 0; i < 100; i++) {
        final s = EpdStatus.fromBytes(await stat.read());
        if (s.state == EpdState.error) {
          throw StateError('设备接收错误：${s.errorLabel}');
        }
        if (s.received >= image.length) {
          received = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!received) {
        throw TimeoutException('设备接收超时');
      }

      message.value = '校验并刷新…';
      final completer = Completer<EpdStatus>();
      _commitCompleter = completer;
      await ctrl.write(
        BleProtocol.commitPacket,
        withoutResponse: false,
        timeout: 15,
      );

      final deadline = DateTime.now().add(const Duration(seconds: 240));
      while (!completer.isCompleted) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('刷新超时');
        }
        try {
          final read = await stat.read();
          final s = EpdStatus.fromBytes(read);
          _onStatusBytes(read);
          if (s.isFinished) break;
        } catch (_) {
          // A missed notification is harmless; keep polling until timeout.
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      final result = await completer.future;
      if (result.state != EpdState.done) {
        throw StateError(
          '设备返回错误：${result.errorLabel}'
          '${result.error == EpdError.none ? '' : ' (${result.error.name})'}',
        );
      }

      final elapsed = DateTime.now().difference(started).inMilliseconds;
      try {
        await Get.find<HistoryController>().add(
          fileName: sourceName,
          bytes: image.length,
          durationMs: elapsed,
          deviceName: device.value?.platformName ?? 'HUAWEI-EPD-A0',
          sourcePath: historySourcePath,
        );
      } catch (_) {
        // The image is already on screen; never fail the send over history.
      }

      progress.value = 1;
      status.value = result;
      message.value = '刷新完成，用时 ${(elapsed / 1000).toStringAsFixed(1)} s';
    } catch (e) {
      message.value = '发送失败：$e';
      try {
        await ctrl.write(BleProtocol.abortPacket);
      } catch (_) {
        // Device may already be disconnected.
      }
    } finally {
      _commitCompleter = null;
      sending.value = false;
    }
  }

  Future<void> disconnect() async {
    await _safeDisconnect();
    message.value = '已断开';
  }

  Future<void> _safeDisconnect() async {
    try {
      await device.value?.disconnect();
    } catch (_) {}
    _handleDisconnected();
  }

  void _handleDisconnected() {
    connected.value = false;
    controlChar.value = null;
    statusChar.value = null;
    infoChar.value = null;
    deviceInfo.value = '';
    mtu.value = 0;
    status.value = EpdStatus.idle;
    progress.value = 0;
    if (_commitCompleter != null && !_commitCompleter!.isCompleted) {
      _commitCompleter!.completeError(StateError('设备已断开'));
    }
    _commitCompleter = null;
    sending.value = false;
  }

  String get adapterLabel => switch (adapterState.value) {
        BluetoothAdapterState.unknown => '蓝牙状态未知',
        BluetoothAdapterState.unavailable => '蓝牙不可用',
        BluetoothAdapterState.unauthorized => '未授权蓝牙',
        BluetoothAdapterState.turningOn => '正在打开蓝牙',
        BluetoothAdapterState.on => '蓝牙已开启',
        BluetoothAdapterState.turningOff => '正在关闭蓝牙',
        BluetoothAdapterState.off => '蓝牙已关闭',
      };

  @override
  void onClose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _connectionSub?.cancel();
    super.onClose();
  }
}
