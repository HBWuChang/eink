import 'dart:io';
import 'dart:typed_data';
import 'package:controller/controllers/yt_controller.dart';
import 'package:controller/pages/yt_status_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

void main() {
  testWidgets(
    'draft rotation updates pixel preview without saving or sending',
    (tester) async {
      final directory = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('yt-preview-test');
        Hive.init(dir.path);
        await Hive.openBox<dynamic>('settings');
        return dir;
      }))!;
      Get.testMode = true;
      final controller = Get.put(YtController());
      tester.view.physicalSize = const Size(1100, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        Get.reset();
        await Hive.close();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(const GetMaterialApp(home: YtStatusPage()));
      Future<void> render() async {
        for (var attempt = 0; attempt < 5; attempt++) {
          await tester.pump(const Duration(milliseconds: 250));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          });
          await tester.pump();
        }
      }

      await render();
      final preview = find.byKey(const ValueKey('yt-preview'));
      await tester.scrollUntilVisible(
        preview,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      Uint8List bytes() =>
          ((tester.widget<Image>(preview)).image as MemoryImage).bytes;
      final original = Uint8List.fromList(bytes());
      final rotation = find.byKey(const ValueKey('rotation-0'));
      await tester.scrollUntilVisible(
        rotation,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(rotation);
      await tester.pumpAndSettle();
      await tester.tap(find.text('90°').last);
      await tester.pump();
      await render();
      await tester.scrollUntilVisible(
        preview,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(bytes(), isNot(orderedEquals(original)));
      expect(controller.box.get('yt.config'), isNull);
      expect(controller.busy.value, isFalse);
      expect(find.text('示例数据：3 条（用于预览，非实际数量）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
