import 'package:controller/controllers/app_controllers.dart';
import 'package:controller/pages/home_page.dart';
import 'package:controller/services/image_pipeline.dart';
import 'package:controller/widgets/crop_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _TestBleController extends BleController {
  // Keep layout tests independent of native BLE and Hive initialization.
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _TestHistoryController extends HistoryController {
  // Keep layout tests independent of native BLE and Hive initialization.
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  for (final size in [
    const Size(360, 800),
    const Size(800, 1200),
    const Size(1200, 800),
    const Size(800, 360),
  ]) {
    testWidgets('home layout at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Get.testMode = true;
      Get.put(ImageController());
      Get.put<BleController>(_TestBleController());
      final history = Get.put<HistoryController>(_TestHistoryController());
      history.records.assignAll(
        List.generate(20, (i) => {'fileName': 'history-$i', 'timestamp': i}),
      );
      addTearDown(Get.reset);
      await tester.pumpWidget(const GetMaterialApp(home: HomePage()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Radio<DitherAlgorithm>), findsNWidgets(4));
      final group = tester.widget<RadioGroup<DitherAlgorithm>>(
        find.byType(RadioGroup<DitherAlgorithm>),
      );
      expect(group.groupValue, DitherAlgorithm.none);
      // The entire labelled option is clickable.
      await tester.ensureVisible(find.text('JJN'));
      await tester.tap(find.text('JJN'));
      await tester.pump();
      expect(
        Get.find<ImageController>().ditherAlgorithm.value,
        DitherAlgorithm.jjn,
      );
      await tester.ensureVisible(find.byType(CropEditor));
      await tester.pumpAndSettle();
      final editor = tester.getRect(find.byType(CropEditor));
      final ble = tester.getRect(find.byType(BlePanel));
      if (size.height > size.width) {
        expect(editor.width, closeTo(editor.height, 0.01));
        expect(ble.top, greaterThan(editor.bottom));
        final scroll = find.byKey(const ValueKey('portrait-scroll'));
        expect(scroll, findsOneWidget);
        await tester.drag(scroll, const Offset(0, -2500));
        await tester.pumpAndSettle();
        expect(find.text('history-19').hitTestable(), findsOneWidget);
      } else {
        expect(ble.left, greaterThan(editor.right));
        expect(find.byKey(const ValueKey('portrait-scroll')), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
