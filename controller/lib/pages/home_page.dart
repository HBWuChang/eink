import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/app_controllers.dart';
import '../services/ble_protocol.dart';
import '../widgets/crop_editor.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('墨水屏控制器'),
        actions: [
          TextButton(
            onPressed: () => Get.toNamed('/yt-status'),
            child: const Text('YT 状态'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight > constraints.maxWidth) {
              return SingleChildScrollView(
                key: const ValueKey('portrait-scroll'),
                padding: const EdgeInsets.all(16),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ImageEditorPanel(squarePreview: true),
                    SizedBox(height: 16),
                    BlePanel(scrollable: true),
                  ],
                ),
              );
            }
            final wide = constraints.maxWidth >= 1000;
            final editor = const Expanded(
              flex: 3,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: ImageEditorPanel(),
              ),
            );
            final side = const SizedBox(
              width: 390,
              child: Padding(
                padding: EdgeInsets.fromLTRB(0, 16, 16, 16),
                child: BlePanel(),
              ),
            );
            final content = Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: wide
                  ? [editor, side]
                  : [
                      editor,
                      SizedBox(
                        width: constraints.maxWidth * 0.40,
                        child: const Padding(
                          padding: EdgeInsets.fromLTRB(0, 16, 16, 16),
                          child: BlePanel(),
                        ),
                      ),
                    ],
            );
            if (constraints.maxHeight < 700) {
              return SingleChildScrollView(
                child: SizedBox(height: 700, child: content),
              );
            }
            return content;
          },
        ),
      ),
    );
  }
}

class ImageEditorPanel extends StatelessWidget {
  const ImageEditorPanel({super.key, this.squarePreview = false});

  final bool squarePreview;

  @override
  Widget build(BuildContext context) {
    final image = Get.find<ImageController>();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Obx(() {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              if (squarePreview)
                const AspectRatio(aspectRatio: 1, child: CropEditor())
              else
                const Expanded(child: CropEditor()),
              const SizedBox(height: 12),
              if (image.error.value.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    image.error.value,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: image.pickImage,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('选择图片'),
                  ),
                  OutlinedButton.icon(
                    onPressed: image.loadTestPattern,
                    icon: const Icon(Icons.grid_on),
                    label: const Text('四色测试图'),
                  ),
                  IconButton.filledTonal(
                    tooltip: '左转 90°',
                    onPressed: () => image.rotateBy(-90),
                    icon: const Icon(Icons.rotate_left),
                  ),
                  IconButton.filledTonal(
                    tooltip: '右转 90°',
                    onPressed: () => image.rotateBy(90),
                    icon: const Icon(Icons.rotate_right),
                  ),
                  TextButton.icon(
                    onPressed: image.resetCrop,
                    icon: const Icon(Icons.crop_free),
                    label: const Text('重置裁剪'),
                  ),
                  Row(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.image_outlined),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FittedBox(
                          fit: .scaleDown,
                          child: Text(
                            image.fileName.value,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text('旋转 ${image.rotation.value}°'),
                ],
              ),
              const SizedBox(height: 8),
              _CropAngleRow(
                value: image.cropAngle.value,
                onChanged: image.setCropAngle,
              ),
              _BlankColorRow(
                color: image.blankColor.value,
                onChanged: image.setBlankColor,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('抖动处理（Floyd–Steinberg）'),
                subtitle: const Text('与手机 App 四色抖动一致；细碎色点更多'),
                value: image.dither.value,
                onChanged: image.setDither,
              ),
              const SizedBox(height: 4),
              Text(image.info, style: Theme.of(context).textTheme.bodySmall),
            ],
          );
        }),
      ),
    );
  }
}

class _CropAngleRow extends StatelessWidget {
  const _CropAngleRow({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text('裁剪方向', style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: RadioGroup<int>(
            groupValue: value,
            onChanged: (angle) {
              if (angle != null) onChanged(angle);
            },
            child: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final angle in ImageController.cropAngles)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Radio<int>(value: angle),
                      Text('$angle°'),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BlankColorRow extends StatelessWidget {
  const _BlankColorRow({required this.color, required this.onChanged});

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final hex = (color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text('留白颜色', style: Theme.of(context).textTheme.bodySmall),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final picked = await showDialog<Color>(
              context: context,
              builder: (_) => _BlankColorDialog(initial: color),
            );
            if (picked != null) onChanged(picked);
          },
          child: Container(
            width: 44,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('#$hex', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '超出图像的部分',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).disabledColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _BlankColorDialog extends StatefulWidget {
  const _BlankColorDialog({required this.initial});

  final Color initial;

  @override
  State<_BlankColorDialog> createState() => _BlankColorDialogState();
}

class _BlankColorDialogState extends State<_BlankColorDialog> {
  late double _r;
  late double _g;
  late double _b;

  @override
  void initState() {
    super.initState();
    _r = widget.initial.r * 255;
    _g = widget.initial.g * 255;
    _b = widget.initial.b * 255;
  }

  Color get _color => Color.fromARGB(255, _r.round(), _g.round(), _b.round());

  void _apply(Color color) {
    setState(() {
      _r = color.r * 255;
      _g = color.g * 255;
      _b = color.b * 255;
    });
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(value.round().toString(), textAlign: TextAlign.end),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const presets = <Color>[
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFFF5CD00),
      Color(0xFFC80000),
    ];
    return AlertDialog(
      title: const Text('留白颜色'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black26),
              ),
            ),
            const SizedBox(height: 12),
            _slider('R', _r, (v) => setState(() => _r = v)),
            _slider('G', _g, (v) => setState(() => _g = v)),
            _slider('B', _b, (v) => setState(() => _b = v)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final preset in presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _apply(preset),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: preset,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.black26),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '输出会量化到四色（黑/白/黄/红），可能与该颜色略有差异。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class BlePanel extends StatelessWidget {
  const BlePanel({super.key, this.scrollable = false});

  final bool scrollable;

  Widget _historyArea(Widget child) =>
      scrollable ? child : Expanded(child: child);

  @override
  Widget build(BuildContext context) {
    final ble = Get.find<BleController>();
    final image = Get.find<ImageController>();
    final history = Get.find<HistoryController>();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Obx(() {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.sensors),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '蓝牙设备',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '扫描',
                    onPressed: ble.scanning.value ? null : ble.scan,
                    icon: ble.scanning.value
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              Text(
                '${ble.adapterLabel} · ${ble.scanResults.length} 个结果',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!ble.connected.value && ble.message.value.isNotEmpty)
                Text(ble.message.value),
              const SizedBox(height: 8),
              if (!ble.connected.value) ...[
                SizedBox(
                  height: 220,
                  child: ble.scanResults.isEmpty
                      ? Center(
                          child: Text(
                            '点击右上角扫描\n目标广播名 ${BleProtocol.deviceName}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : ListView.separated(
                          itemCount: ble.scanResults.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final r = ble.scanResults[index];
                            final name = ble.scanName(r);
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.bluetooth),
                              title: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text('${r.rssi} dBm'),
                              trailing: ble.connecting.value
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : TextButton(
                                      onPressed: () => ble.connectTo(r),
                                      child: const Text('连接'),
                                    ),
                            );
                          },
                        ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bluetooth_connected, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              ble.device.value?.platformName.isNotEmpty == true
                                  ? ble.device.value!.platformName
                                  : 'HUAWEI-EPD-A0',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: ble.disconnect,
                            child: const Text('断开'),
                          ),
                        ],
                      ),
                      if (ble.deviceInfo.value.isNotEmpty)
                        Text(
                          ble.deviceInfo.value,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      Text(
                        'MTU ${ble.mtu.value} · ${ble.status.value.stateLabel}'
                        '${ble.status.value.errorLabel.isEmpty ? '' : ' · ${ble.status.value.errorLabel}'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: ble.sending.value ? ble.progress.value : null,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 6),
                Text(
                  ble.message.value.isEmpty ? '等待发送' : ble.message.value,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed:
                      (ble.connecting.value ||
                          ble.sending.value ||
                          image.processing.value ||
                          image.packed.value == null)
                      ? null
                      : () {
                          final packed = image.packed.value;
                          if (packed == null) return;
                          ble.sendImage(
                            packed,
                            sourceName: image.fileName.value,
                          );
                        },
                  icon: ble.sending.value
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send),
                  label: Text(ble.sending.value ? '发送中…' : '发送并刷新'),
                ),
                if (image.packed.value == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('请先选择图片并生成预览。', style: TextStyle(fontSize: 12)),
                  ),
              ],
              const SizedBox(height: 12),
              const Divider(),
              Row(
                children: [
                  const Icon(Icons.history, size: 18),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '发送历史',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: history.records.isEmpty ? null : history.clear,
                    child: const Text('清空'),
                  ),
                ],
              ),
              _historyArea(
                history.records.isEmpty
                    ? const SizedBox(
                        height: 64,
                        child: Center(
                          child: Text('暂无历史', style: TextStyle(fontSize: 12)),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: scrollable,
                        physics: scrollable
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        itemCount: history.records.length,
                        itemBuilder: (context, index) {
                          final r = history.records[index];
                          final ts = DateTime.fromMillisecondsSinceEpoch(
                            (r['timestamp'] as num?)?.toInt() ?? 0,
                          );
                          final restorable = history.hasSource(r);
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.check_circle_outline,
                              size: 18,
                            ),
                            title: Text(
                              (r['fileName'] as String?) ?? '图片',
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_time(ts)} · ${(((r['durationMs'] as num?) ?? 0) / 1000).toStringAsFixed(1)} s'
                              '${restorable ? '' : ' · 源图已丢失'}',
                            ),
                            trailing: Tooltip(
                              message: restorable ? '载入此图片替换当前图片' : '历史记录未保存源图',
                              child: Icon(
                                restorable
                                    ? Icons.restore
                                    : Icons.image_not_supported_outlined,
                                size: 18,
                              ),
                            ),
                            onTap: restorable
                                ? () async {
                                    try {
                                      final bytes = await history.readSource(r);
                                      if (bytes == null) {
                                        image.error.value = '历史图片已丢失';
                                        return;
                                      }
                                      await image.loadSource(
                                        bytes,
                                        (r['fileName'] as String?) ?? '历史图片',
                                        path: r['sourcePath'] as String?,
                                      );
                                    } catch (e) {
                                      image.error.value = '载入历史图片失败：$e';
                                    }
                                  }
                                : null,
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
    );
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
