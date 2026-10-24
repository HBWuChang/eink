import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ble_protocol.dart';

enum DitherAlgorithm {
  none('不使用抖动'),
  fs('FS'),
  jjn('JJN'),
  stucki('Stucki');

  const DitherAlgorithm(this.label);
  final String label;
}

const _fs = [(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)];
const _jjn = [
  (1, 0, 7),
  (2, 0, 5),
  (-2, 1, 3),
  (-1, 1, 5),
  (0, 1, 7),
  (1, 1, 5),
  (2, 1, 3),
  (-2, 2, 1),
  (-1, 2, 3),
  (0, 2, 5),
  (1, 2, 3),
  (2, 2, 1),
];
const _stucki = [
  (1, 0, 8),
  (2, 0, 4),
  (-2, 1, 2),
  (-1, 1, 4),
  (0, 1, 8),
  (1, 1, 4),
  (2, 1, 2),
  (-2, 2, 1),
  (-1, 2, 2),
  (0, 2, 4),
  (1, 2, 2),
  (2, 2, 1),
];

typedef RenderResult = ({Uint8List packed, Uint8List previewPng});

/// Decoded, EXIF-baked and rotated image used for on-screen editing.
typedef DisplayImage = ({Uint8List png, int width, int height});

/// Decode, apply EXIF orientation, rotate, crop (padding out-of-image areas
/// with [blankColor]), rotate the crop by [cropAngle], scale to fill
/// 768x552, quantize to the four e-paper colors, and pack 2bpp.
///
/// [cropLeft]..[cropBottom] are normalized coordinates of the rotated image and
/// may fall outside 0..1; those parts are filled with [blankColor].
///
/// This function is pure Dart and can run in an isolate.
RenderResult renderImageSync({
  required Uint8List sourceBytes,
  required int rotation,
  required double cropLeft,
  required double cropTop,
  required double cropRight,
  required double cropBottom,
  required int cropAngle,
  required int blankColor,
  required DitherAlgorithm algorithm,
}) {
  img.Image? decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw const FormatException('无法解码图片');
  }

  img.Image work = img.bakeOrientation(decoded);

  final angle = ((rotation % 360) + 360) % 360;
  if (angle != 0) {
    work = img.copyRotate(work, angle: angle);
  }

  work = _cropWithPadding(
    work,
    cropLeft,
    cropTop,
    cropRight,
    cropBottom,
    blankColor,
  );

  final cropRotation = ((cropAngle % 360) + 360) % 360;
  if (cropRotation != 0) {
    work = img.copyRotate(work, angle: cropRotation);
  }

  const targetW = BleProtocol.imageWidth;
  const targetH = BleProtocol.imageHeight;

  final canvas = img.copyResize(
    work,
    width: targetW,
    height: targetH,
    interpolation: img.Interpolation.linear,
  );

  // Same palette as the Android QPollLab app:
  // black, white, yellow (0xF5CD00), red (0xC80000).
  const palette = <List<int>>[
    [0, 0, 0],
    [255, 255, 255],
    [245, 205, 0],
    [200, 0, 0],
  ];

  final packed = Uint8List(BleProtocol.imageBytes);
  final preview = img.Image(width: targetW, height: targetH, numChannels: 3);

  final kernel = switch (algorithm) {
    DitherAlgorithm.none => const <(int, int, int)>[],
    DitherAlgorithm.fs => _fs,
    DitherAlgorithm.jjn => _jjn,
    DitherAlgorithm.stucki => _stucki,
  };
  final divisor = switch (algorithm) {
    DitherAlgorithm.jjn => 48,
    DitherAlgorithm.stucki => 42,
    _ => 16,
  };
  // Three rolling rows cover the two-row JJN and Stucki kernels.
  final errors = List.generate(
    3,
    (_) => List.generate(3, (_) => Float64List(targetW)),
  );

  var out = 0;
  for (var y = 0; y < targetH; y++) {
    for (var x = 0; x < targetW; x++) {
      final p = canvas.getPixel(x, y);

      final current = errors[y % 3];
      final r = _clamp(p.r.toDouble() + current[0][x]);
      final g = _clamp(p.g.toDouble() + current[1][x]);
      final b = _clamp(p.b.toDouble() + current[2][x]);

      var best = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < palette.length; i++) {
        final dr = r - palette[i][0];
        final dg = g - palette[i][1];
        final db = b - palette[i][2];
        final distance = dr * dr + dg * dg + db * db;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = i;
        }
      }

      final c = palette[best];
      for (final (dx, dy, weight) in kernel) {
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || nx >= targetW || ny >= targetH) continue;
        final row = errors[ny % 3];
        row[0][nx] += (r - c[0]) * weight / divisor;
        row[1][nx] += (g - c[1]) * weight / divisor;
        row[2][nx] += (b - c[2]) * weight / divisor;
      }

      if ((x & 3) == 0) {
        out = y * BleProtocol.rowBytes + (x >> 2);
      }
      packed[out] |= best << (6 - 2 * (x & 3));
      preview.setPixelRgb(
        x,
        y,
        palette[best][0],
        palette[best][1],
        palette[best][2],
      );
    }

    for (final channel in errors[y % 3]) {
      channel.fillRange(0, channel.length, 0);
    }
  }

  return (
    packed: packed,
    previewPng: Uint8List.fromList(img.encodePng(preview)),
  );
}

double _clamp(double value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return value;
}

Future<RenderResult> renderImage({
  required Uint8List sourceBytes,
  required int rotation,
  required double cropLeft,
  required double cropTop,
  required double cropRight,
  required double cropBottom,
  required int cropAngle,
  required int blankColor,
  required DitherAlgorithm algorithm,
}) {
  return Isolate.run(
    () => renderImageSync(
      sourceBytes: sourceBytes,
      rotation: rotation,
      cropLeft: cropLeft,
      cropTop: cropTop,
      cropRight: cropRight,
      cropBottom: cropBottom,
      cropAngle: cropAngle,
      blankColor: blankColor,
      algorithm: algorithm,
    ),
  );
}

/// Crop the normalized [left]..[bottom] region of [src], padding every part
/// outside the image with [blankColor] (0xRRGGBB).
img.Image _cropWithPadding(
  img.Image src,
  double left,
  double top,
  double right,
  double bottom,
  int blankColor,
) {
  final w = src.width;
  final h = src.height;
  if (right <= left) right = left + 0.001;
  if (bottom <= top) bottom = top + 0.001;

  final cx = (left * w).round();
  final cy = (top * h).round();
  final cw = ((right - left) * w).round().clamp(1, math.max(1, w * 8)).toInt();
  final ch = ((bottom - top) * h).round().clamp(1, math.max(1, h * 8)).toInt();

  final r = (blankColor >> 16) & 0xFF;
  final g = (blankColor >> 8) & 0xFF;
  final b = blankColor & 0xFF;

  final out = img.Image(width: cw, height: ch, numChannels: 3);
  img.fill(out, color: img.ColorRgb8(r, g, b));

  for (var y = 0; y < ch; y++) {
    final sy = cy + y;
    if (sy < 0 || sy >= h) continue;
    for (var x = 0; x < cw; x++) {
      final sx = cx + x;
      if (sx < 0 || sx >= w) continue;
      final p = src.getPixel(sx, sy);
      out.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return out;
}

/// Decode + EXIF bake + rotate, downscale when larger than [maxEdge] and
/// re-encode as PNG. Pure Dart, safe to run in an isolate.
DisplayImage buildDisplayImageSync({
  required Uint8List sourceBytes,
  required int rotation,
  int maxEdge = 3200,
}) {
  img.Image? decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw const FormatException('无法解码图片');
  }

  img.Image work = img.bakeOrientation(decoded);
  final angle = ((rotation % 360) + 360) % 360;
  if (angle != 0) {
    work = img.copyRotate(work, angle: angle);
  }

  final longest = math.max(work.width, work.height);
  if (longest > maxEdge) {
    final scale = maxEdge / longest;
    work = img.copyResize(
      work,
      width: math.max(1, (work.width * scale).round()),
      height: math.max(1, (work.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }

  return (
    png: Uint8List.fromList(img.encodePng(work)),
    width: work.width,
    height: work.height,
  );
}

Future<DisplayImage> buildDisplayImage({
  required Uint8List sourceBytes,
  required int rotation,
}) {
  return Isolate.run(
    () => buildDisplayImageSync(sourceBytes: sourceBytes, rotation: rotation),
  );
}

Uint8List createTestPatternPng() {
  const w = BleProtocol.imageWidth;
  const h = BleProtocol.imageHeight;
  final image = img.Image(width: w, height: h, numChannels: 3);

  const colors = <List<int>>[
    [0, 0, 0],
    [255, 255, 255],
    [255, 255, 0],
    [255, 0, 0],
  ];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final band = ((x * 4) ~/ w).clamp(0, 3);
      final c = colors[band];
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }

  // Black frame + diagonal marker to expose rotation/mirroring.
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: w - 1,
    y2: 5,
    color: img.ColorRgb8(0, 0, 0),
  );
  img.fillRect(
    image,
    x1: 0,
    y1: h - 6,
    x2: w - 1,
    y2: h - 1,
    color: img.ColorRgb8(0, 0, 0),
  );
  for (var i = 0; i < 80; i++) {
    img.fillRect(
      image,
      x1: i * 8,
      y1: i * 6,
      x2: i * 8 + 5,
      y2: i * 6 + 5,
      color: img.ColorRgb8(0, 0, 0),
    );
  }

  return Uint8List.fromList(img.encodePng(image));
}
