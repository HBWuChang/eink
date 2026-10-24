import 'dart:io';
import 'package:controller/controllers/yt_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

class _Controller extends YtController {
  final triggers = <String>[];
  @override
  Future<void> updateStatus({
    bool send = true,
    String trigger = 'manual',
  }) async {
    triggers.add(trigger);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native enable handshake, tick, wake and disable', () async {
    final dir = await Directory.systemTemp.createTemp('yt-background-test');
    Hive.init(dir.path);
    final box = await Hive.openBox<dynamic>('settings');
    await box.put('yt.config', {'token': 'test-only', 'query': 'test'});
    Get.testMode = true;
    final calls = <bool>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(YtController.channel, (call) async {
      expect(call.method, 'setEnabled');
      final enabled = call.arguments as bool;
      calls.add(enabled);
      return {'enabled': enabled, 'sleepAssertion': enabled};
    });
    final controller = Get.put<_Controller>(_Controller());
    try {
      await controller.setEnabled(true);
      expect(controller.backgroundStatus.value, contains('断言已建立'));
      expect(controller.triggers, ['startup']);
      Future<void> event(String method) async {
        await messenger.handlePlatformMessage(
          'epd/background',
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (_) {},
        );
      }

      await event('tick');
      await event('wake');
      expect(controller.triggers, ['startup', 'tick', 'wake']);
      await controller.setEnabled(false);
      await event('tick');
      expect(controller.triggers, ['startup', 'tick', 'wake']);
      expect(calls, [true, false]);
      expect(box.get('yt.enabled'), false);
    } finally {
      Get.reset();
      messenger.setMockMethodCallHandler(YtController.channel, null);
      await Hive.close();
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
