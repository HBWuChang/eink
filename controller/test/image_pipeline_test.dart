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
      algorithm: DitherAlgorithm.none,
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
      algorithm: DitherAlgorithm.none,
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
        algorithm: DitherAlgorithm.none,
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
      algorithm: DitherAlgorithm.fs,
    );
    expect(result.packed.length, BleProtocol.imageBytes);
    final preview = img.decodePng(result.previewPng)!;
    expect(preview.width, BleProtocol.imageWidth);
    expect(preview.height, BleProtocol.imageHeight);
  });

  test('all diffusion modes produce distinct valid packed previews', () {
    final source = img.Image(width: 768, height: 552, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(128, 128, 128));
    final bytes = img.encodePng(source);
    final outputs = <List<int>>[];
    const palette = [(0, 0, 0), (255, 255, 255), (245, 205, 0), (200, 0, 0)];
    for (final algorithm in DitherAlgorithm.values) {
      final result = renderImageSync(
        sourceBytes: bytes,
        rotation: 0,
        cropLeft: 0,
        cropTop: 0,
        cropRight: 1,
        cropBottom: 1,
        cropAngle: 0,
        blankColor: 0xFFFFFF,
        algorithm: algorithm,
      );
      expect(result.packed.length, BleProtocol.imageBytes);
      final preview = img.decodePng(result.previewPng)!;
      final indices = <int>{};
      for (var y = 0; y < preview.height; y++) {
        for (var x = 0; x < preview.width; x++) {
          final index =
              (result.packed[y * BleProtocol.rowBytes + (x >> 2)] >>
                  (6 - 2 * (x & 3))) &
              3;
          indices.add(index);
          final pixel = preview.getPixel(x, y);
          expect((
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
          ), palette[index]);
        }
      }
      expect(
        indices.length,
        algorithm == DitherAlgorithm.none ? 1 : greaterThan(1),
      );
      for (final previous in outputs) {
        expect(result.packed, isNot(orderedEquals(previous)));
      }
      outputs.add(result.packed);
    }
  });

  test('display image is rotated and reports rotated dimensions', () {
    final source = createTestPatternPng();
    final display = buildDisplayImageSync(sourceBytes: source, rotation: 90);
    expect(display.width, BleProtocol.imageHeight);
    expect(display.height, BleProtocol.imageWidth);
  });
}
