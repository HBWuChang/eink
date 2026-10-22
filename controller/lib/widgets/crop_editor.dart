import 'dart:async';
import 'dart:math' as math;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/app_controllers.dart';

/// Fixed-ratio crop editor.
///
/// The crop frame is fixed at the centre of the viewport (80% of the largest
/// same-ratio box that fits) and never moves or resizes. Only the image can be
/// panned and zoomed; the visible region under the frame is what gets cropped.
/// Nothing is animated when a gesture ends, so the composition picked by the
/// user is never changed behind their back.
class CropEditor extends StatefulWidget {
  const CropEditor({super.key});

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor>
    with SingleTickerProviderStateMixin {
  final ImageController _image = Get.find<ImageController>();

  late final AnimationController _fade;
  final List<Worker> _workers = [];

  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  Size _viewport = Size.zero;
  Rect _frame = Rect.zero;
  bool _viewReady = false;
  bool _interacting = false;
  bool _resetScheduled = false;
  bool _commitScheduled = false;
  Timer? _idleTimer;

  static const _frameFactor = 0.8;
  static const _minZoomFactor = 0.1;
  static const _maxZoomFactor = 20.0;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 0,
    );
    _workers.add(ever<int>(_image.viewResetToken, (_) => _scheduleReset()));
    _workers.add(
      ever<int>(_image.renderToken, (_) {
        if (!_interacting) _fadeIn();
      }),
    );
    _workers.add(
      ever<bool>(_image.processing, (processing) {
        if (processing) _fadeOut();
      }),
    );
    _workers.add(ever<Size?>(_image.displaySize, (_) => _scheduleCropCommit()));
  }

  @override
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _idleTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Frame and view helpers
  // ---------------------------------------------------------------------------

  Rect _frameRect(Size viewport, double ratio) {
    var width = viewport.width;
    var height = width / ratio;
    if (height > viewport.height) {
      height = viewport.height;
      width = height * ratio;
    }
    width *= _frameFactor;
    height *= _frameFactor;
    return Rect.fromCenter(
      center: viewport.center(Offset.zero),
      width: width,
      height: height,
    );
  }

  double _containScale(Size image, Rect frame) =>
      math.min(frame.width / image.width, frame.height / image.height);

  void _scheduleReset() {
    if (_resetScheduled) return;
    _resetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetScheduled = false;
      if (!mounted) return;
      _resetView();
    });
  }

  /// Fit the whole image inside the frame, keeping it centred.
  void _resetView() {
    final image = _image.rotatedImageSize;
    if (image == null || image.isEmpty || _viewport.isEmpty) return;

    final frame = _frameRect(_viewport, _image.cropAspectRatio);
    final scale = _containScale(image, frame);
    setState(() {
      _frame = frame;
      _scale = scale;
      _offset =
          frame.center -
          Offset(image.width * scale / 2, image.height * scale / 2);
      _viewReady = true;
    });
    _fade.value = 0;
    _pushCrop(commit: true);
  }

  void _scheduleCropCommit() {
    if (_commitScheduled) return;
    _commitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _commitScheduled = false;
      if (!mounted || !_viewReady) return;
      _pushCrop(commit: true);
    });
  }

  void _pushCrop({required bool commit}) {
    final image = _image.rotatedImageSize;
    if (image == null || _viewport.isEmpty || _frame.isEmpty) return;

    final width = image.width * _scale;
    final height = image.height * _scale;
    if (width <= 0 || height <= 0) return;

    _image.setCropRect(
      Rect.fromLTRB(
        (_frame.left - _offset.dx) / width,
        (_frame.top - _offset.dy) / height,
        (_frame.right - _offset.dx) / width,
        (_frame.bottom - _offset.dy) / height,
      ),
      commit: commit,
    );
  }

  Offset _clampOffset(Offset value, Size image, double scale) {
    final width = image.width * scale;
    final height = image.height * scale;
    const margin = 48.0;
    final minX = -width + margin;
    final maxX = _viewport.width - margin;
    final minY = -height + margin;
    final maxY = _viewport.height - margin;
    return Offset(
      value.dx.clamp(minX, maxX).toDouble(),
      value.dy.clamp(minY, maxY).toDouble(),
    );
  }

  // ---------------------------------------------------------------------------
  // Interaction
  // ---------------------------------------------------------------------------

  void _beginInteraction() {
    _idleTimer?.cancel();
    if (_interacting) return;
    _interacting = true;
    _fadeOut();
  }

  void _endInteraction() {
    _idleTimer?.cancel();
    _interacting = false;
    _pushCrop(commit: true);
  }

  void _fadeOut() {
    _fade.duration = const Duration(milliseconds: 120);
    _fade.animateTo(0, curve: Curves.easeOut);
  }

  void _fadeIn() {
    _fade.duration = const Duration(milliseconds: 260);
    _fade.animateTo(1, curve: Curves.easeIn);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _beginInteraction();
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final image = _image.rotatedImageSize;
    if (image == null) return;

    final base = _containScale(image, _frame);
    final nextScale = (_startScale * details.scale)
        .clamp(base * _minZoomFactor, base * _maxZoomFactor)
        .toDouble();
    final imagePoint = (_startFocal - _startOffset) / _startScale;
    final nextOffset = _clampOffset(
      details.localFocalPoint - imagePoint * nextScale,
      image,
      nextScale,
    );

    setState(() {
      _scale = nextScale;
      _offset = nextOffset;
    });
    _pushCrop(commit: false);
  }

  void _onScaleEnd(ScaleEndDetails details) => _endInteraction();

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final image = _image.rotatedImageSize;
    if (image == null || _viewport.isEmpty) return;
    if (event.scrollDelta.dy == 0) return;

    final base = _containScale(image, _frame);
    final factor = math.exp(-event.scrollDelta.dy * 0.0015);
    final nextScale = (_scale * factor)
        .clamp(base * _minZoomFactor, base * _maxZoomFactor)
        .toDouble();
    if ((nextScale - _scale).abs() < 1e-6) return;

    final focal = event.localPosition;
    final imagePoint = (focal - _offset) / _scale;
    final nextOffset = _clampOffset(
      focal - imagePoint * nextScale,
      image,
      nextScale,
    );

    _beginInteraction();
    setState(() {
      _scale = nextScale;
      _offset = nextOffset;
    });
    _pushCrop(commit: false);
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 260), _endInteraction);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final display = _image.displayBytes.value;
      if (display == null) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1D1B),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const _EmptyHint(),
        );
      }

      final blank = _image.blankColor.value;
      final preview = _image.previewPng.value;
      final processing = _image.processing.value;
      final image = _image.rotatedImageSize;
      final ratio = _image.cropAspectRatio;

      return LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          if (viewport != _viewport) {
            final hadView = _viewReady;
            _viewport = viewport;
            _frame = _frameRect(viewport, ratio);
            if (!hadView) {
              _scheduleReset();
            }
          } else {
            _frame = _frameRect(viewport, ratio);
            if (!_viewReady) _scheduleReset();
          }

          return ClipRect(
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Color(0xFF1A1D1B)),
                    // Blank colour behind the image, inside the frame only.
                    Positioned.fromRect(
                      rect: _frame,
                      child: ColoredBox(color: blank),
                    ),
                    if (image != null && _viewReady)
                      Positioned(
                        left: _offset.dx,
                        top: _offset.dy,
                        width: math.max(1, image.width * _scale),
                        height: math.max(1, image.height * _scale),
                        child: ExtendedImage.memory(
                          display,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          enableLoadState: false,
                        ),
                      ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _CropMaskPainter(frame: _frame),
                        ),
                      ),
                    ),
                    if (preview != null)
                      Positioned.fromRect(
                        rect: _frame,
                        child: IgnorePointer(
                          child: FadeTransition(
                            opacity: _fade,
                            child: ClipRect(
                              child: Obx(
                                () => Transform.rotate(
                                  angle:
                                      -(_image.cropAngle.value / 90.0 % 4) *
                                      math.pi /
                                      2,
                                  child: OverflowBox(
                                    minWidth: 0,
                                    minHeight: 0,
                                    maxWidth: double.infinity,
                                    maxHeight: double.infinity,
                                    child: SizedBox(
                                      width:
                                          (_image.cropAngle.value / 90.0 % 4) %
                                                  2 ==
                                              0
                                          ? _frame.width
                                          : _frame.height,
                                      height:
                                          (_image.cropAngle.value / 90.0 % 4) %
                                                  2 ==
                                              0
                                          ? _frame.height
                                          : _frame.width,
                                      child: Image.memory(
                                        preview,
                                        fit: BoxFit.fill,
                                        gaplessPlayback: true,
                                        filterQuality: FilterQuality.none,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (processing)
                      Positioned.fromRect(
                        rect: _frame,
                        child: const IgnorePointer(child: _FrameProgress()),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
  }
}

class _CropMaskPainter extends CustomPainter {
  const _CropMaskPainter({required this.frame});

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRect(frame);
    final mask = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    final guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = frame.left + frame.width * i / 3;
      canvas.drawLine(Offset(dx, frame.top), Offset(dx, frame.bottom), guide);
      final dy = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(frame.left, dy), Offset(frame.right, dy), guide);
    }

    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_CropMaskPainter oldDelegate) =>
      oldDelegate.frame != frame;
}

class _FrameProgress extends StatelessWidget {
  const _FrameProgress();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: LinearProgressIndicator(
          minHeight: 2,
          backgroundColor: Colors.transparent,
          color: Colors.white.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.add_photo_alternate_outlined,
            size: 72,
            color: Colors.white.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 12),
          Text(
            '选择图片，或加载四色测试图',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 6),
          const Text(
            '输出固定为 768 × 552，四色 2bpp',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
