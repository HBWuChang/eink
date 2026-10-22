import 'package:controller/controllers/app_controllers.dart';
import 'package:controller/services/image_pipeline.dart';
import 'package:controller/widgets/crop_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('crop editor keeps a fixed ratio frame and reports a crop rect',
      (tester) async {
    Get.testMode = true;
    final controller = Get.put(ImageController());

    // A square source: the landscape 768x552 frame must select a sub-rect of it.
    final square = img.Image(width: 800, height: 800, numChannels: 3);
    img.fill(square, color: img.ColorRgb8(200, 120, 40));
    final source = img.encodePng(square);
    final display = buildDisplayImageSync(sourceBytes: source, rotation: 0);
    controller.originalBytes.value = source;
    controller.displayBytes.value = display.png;
    controller.displaySize.value = Size(
      display.width.toDouble(),
      display.height.toDouble(),
    );

    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: CropEditor(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final rect = controller.cropRect.value;
    expect(rect.width, greaterThan(0));
    expect(rect.height, greaterThan(0));
    expect(rect.width / rect.height, closeTo(controller.cropAspectRatio, 1e-3));
    // A square source cannot cover a landscape frame: the contain reset makes
    // the crop wider than the image, and the sides are filled with blanks.
    expect(rect.width, greaterThan(1.0));
    expect(rect.height, closeTo(1.0, 1e-3));
    // Centred on the image.
    expect(rect.center.dx, closeTo(0.5, 1e-3));
    expect(rect.center.dy, closeTo(0.5, 1e-3));

    Get.reset();
  });
}
