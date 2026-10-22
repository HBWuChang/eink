import 'package:controller/services/ble_protocol.dart';
import 'package:controller/services/image_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('renders 768x552 packed image for an in-bounds crop', () {
    final source = createTestPatternPng();
    final result = renderImageSync(
      sourceBytes: source,
      rotation: 0,
      cropLeft: 0,
      cropTop: 0,
      cropRight: 1,
      cropBottom: 1,
      cropAngle: 0,
      blankColor: 0xFFFFFF,
      dither: false,
    );
    expect(result.packed.length, BleProtocol.imageBytes);
    final preview = img.decodePng(result.previewPng)!;
    expect(preview.width, BleProtocol.imageWidth);
    expect(preview.height, BleProtocol.imageHeight);
  });

  test('pads out-of-image crop with the blank color', () {
    final source = createTestPatternPng();
    final result = renderImageSync(
      sourceBytes: source,
      rotation: 0,
      cropLeft: -0.5,
      cropTop: -0.5,
      cropRight: 1.5,
      cropBottom: 1.5,
      cropAngle: 0,
      blankColor: 0x000000,
      dither: false,
    );
    expect(result.packed.length, BleProtocol.imageBytes);
    final preview = img.decodePng(result.previewPng)!;
    // Corners come from the padding, so they must be black.
    final corner = preview.getPixel(0, 0);
    expect(corner.r, 0);
    expect(corner.g, 0);
    expect(corner.b, 0);
  });

  test('blank color keeps RGB channel order', () {
    final source = createTestPatternPng();
    (int, int, int) padCorner(int blankColor) {
      final result = renderImageSync(
        sourceBytes: source,
        rotation: 0,
        cropLeft: -1,
        cropTop: -1,
        cropRight: 2,
        cropBottom: 2,
        cropAngle: 0,
        blankColor: blankColor,
        dither: false,
      );
      final corner = img.decodePng(result.previewPng)!.getPixel(0, 0);
      return (corner.r.toInt(), corner.g.toInt(), corner.b.toInt());
    }

    // Pure red, green and blue after four-colour quantisation. If G/B were
    // swapped, green would become black and blue would become yellow.
    expect(padCorner(0xFF0000), (200, 0, 0));
    expect(padCorner(0x00FF00), (245, 205, 0));
    expect(padCorner(0x0000FF), (0, 0, 0));
  });

  test('portrait crop rotated by 90 fills the landscape target', () {
    final source = createTestPatternPng();
    final result = renderImageSync(
      sourceBytes: source,
      rotation: 90,
      cropLeft: 0.25,
      cropTop: 0.25,
      cropRight: 0.75,
      cropBottom: 0.75,
      cropAngle: 90,
      blankColor: 0xFFFFFF,
      dither: true,
    );
    expect(result.packed.length, BleProtocol.imageBytes);
    final preview = img.decodePng(result.previewPng)!;
    expect(preview.width, BleProtocol.imageWidth);
    expect(preview.height, BleProtocol.imageHeight);
  });

  test('display image is rotated and reports rotated dimensions', () {
    final source = createTestPatternPng();
    final display = buildDisplayImageSync(sourceBytes: source, rotation: 90);
    expect(display.width, BleProtocol.imageHeight);
    expect(display.height, BleProtocol.imageWidth);
  });
}
