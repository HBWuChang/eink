import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import '../services/ble_protocol.dart';
import 'package:get/get.dart';
import '../controllers/yt_controller.dart';
import '../services/youtrack_service.dart';

class YtStatusPage extends StatefulWidget {
  const YtStatusPage({super.key});
  @override
  State<YtStatusPage> createState() => _YtStatusPageState();
}

class _YtStatusPageState extends State<YtStatusPage> {
  final controller = Get.find<YtController>();
  late final fields = {
    for (final entry in controller.config.values.entries)
      entry.key: TextEditingController(text: '${entry.value}'),
  };
  String error = '';
  String previewError = '';
  Uint8List? previewPng;
  bool renderingPreview = false;
  Timer? previewDebounce;
  Worker? issueWorker;
  StreamSubscription<dynamic>? baseSubscription;
  int previewVersion = 0;

  Map<String, dynamic> get draft => {
    for (final entry in fields.entries) entry.key: entry.value.text,
  };

  @override
  void initState() {
    super.initState();
    for (final key in [
      'text_rotation',
      'text_position',
      'warning_hours',
      'timezone',
    ]) {
      fields[key]!.addListener(schedulePreview);
    }
    issueWorker = ever(controller.issues, (_) => schedulePreview());
    baseSubscription = controller.box
        .watch(key: 'lastBaseImage')
        .listen((_) => schedulePreview());
    schedulePreview();
  }

  void schedulePreview() {
    previewDebounce?.cancel();
    // Invalidate an older render immediately, even during debounce.
    final version = ++previewVersion;
    previewDebounce = Timer(
      const Duration(milliseconds: 180),
      () => renderPreview(version),
    );
  }

  Future<void> renderPreview(int version) async {
    if (!mounted) return;
    setState(() {
      renderingPreview = true;
      previewError = '';
    });
    try {
      final config = YtConfig(draft);
      final hours = config.number('warning_hours');
      if (hours < 1 || hours > 8760) {
        throw const FormatException('预警时间范围：1–8760 小时');
      }
      final now = DateTime.now();
      final local = tz.TZDateTime.from(
        now,
        tz.getLocation(config.text('timezone')),
      );
      final saved = controller.box.get('lastBaseImage');
      final base = saved is List
          ? Uint8List.fromList(saved.cast<int>())
          : (Uint8List(BleProtocol.imageBytes)
              ..fillRange(0, BleProtocol.imageBytes, 0x55));
      // Use explicit sample data until a successful query, including a true zero result.
      final issues = controller.hasData.value
          ? controller.issues.toList()
          : [
              YtIssue(
                '示例1',
                '',
                now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
              ),
              YtIssue(
                '示例2',
                '',
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
              ),
              YtIssue('示例3', '', null),
            ];
      final packed = await overlayYt(
        base,
        issues,
        now,
        hours,
        local.toString().substring(0, 16),
        rotation: config.number('text_rotation'),
        position: config.text('text_position'),
      );
      if (!mounted || version != previewVersion) return;
      final png = packedYtPreview(packed);
      setState(() {
        previewPng = png;
        renderingPreview = false;
      });
    } catch (e) {
      if (!mounted || version != previewVersion) return;
      setState(() {
        previewError = '$e';
        renderingPreview = false;
        previewPng = null;
      });
    }
  }

  Future<void> action(Future<void> Function() callback) async {
    try {
      await callback();
      if (mounted) setState(() => error = '');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    previewVersion++;
    previewDebounce?.cancel();
    issueWorker?.dispose();
    baseSubscription?.cancel();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('YT 状态')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '每 10 分钟检查并叠加至最后一次正常发送的底图。红：已过期；黄：预警时间内到期；黑：其余。YT 更新不会保留为底图或发送历史。',
        ),
        Obx(
          () => SwitchListTile(
            title: const Text('后台定时更新'),
            subtitle: const Text('macOS 关闭窗口后继续运行，菜单栏可重新打开或退出'),
            value: controller.enabled.value,
            onChanged: (v) => action(() => controller.setEnabled(v)),
          ),
        ),
        for (final key in YtConfig.defaults.keys.where(
          (key) => key != 'text_rotation' && key != 'text_position',
        ))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TextField(
              controller: fields[key],
              obscureText: key == 'token',
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: key,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('rotation-${fields['text_rotation']!.text}'),
          initialValue:
              ['0', '90', '180', '270'].contains(fields['text_rotation']!.text)
              ? fields['text_rotation']!.text
              : null,
          decoration: const InputDecoration(
            labelText: '文字旋转方向',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final angle in [0, 90, 180, 270])
              DropdownMenuItem(value: '$angle', child: Text('$angle°')),
          ],
          onChanged: (value) {
            if (value != null) fields['text_rotation']!.text = value;
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('position-${fields['text_position']!.text}'),
          initialValue:
              YtConfig.positions.containsKey(fields['text_position']!.text)
              ? fields['text_position']!.text
              : null,
          decoration: const InputDecoration(
            labelText: '文字位置（九宫格）',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final entry in YtConfig.positions.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) {
            if (value != null) fields['text_position']!.text = value;
          },
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '实际发送效果 · 768 × 552',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text('旋转、位置、预警时间和时区修改后自动预览；保存配置后用于发送。预览不会连接蓝牙。'),
                Obx(
                  () => Text(
                    controller.hasData.value
                        ? '数量来自最近一次成功查询'
                        : '示例数据：3 条（用于预览，非实际数量）',
                  ),
                ),
                Text(
                  controller.box.get('lastBaseImage') is List
                      ? '底图：最后一次正常发送的图像'
                      : '尚无底图，使用白底预览；正式发送前需先发送底图',
                ),
                const SizedBox(height: 8),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 768),
                    child: AspectRatio(
                      aspectRatio: 768 / 552,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.black26),
                        ),
                        child: previewPng != null
                            ? Image.memory(
                                previewPng!,
                                key: const ValueKey('yt-preview'),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.none,
                                gaplessPlayback: true,
                              )
                            : Center(
                                child: Text(
                                  previewError.isNotEmpty
                                      ? previewError
                                      : '正在生成预览…',
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                if (renderingPreview) const LinearProgressIndicator(),
                Obx(
                  () => TextButton.icon(
                    onPressed: controller.busy.value
                        ? null
                        : () => action(() async {
                            await controller.save(draft);
                            await controller.updateStatus(send: false);
                          }),
                    icon: const Icon(Icons.refresh),
                    label: const Text('保存配置并查询数量（仅预览）'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => action(() async {
                final config = await controller.importConfig();
                if (config != null) {
                  for (final entry in config.entries) {
                    fields[entry.key]?.text = '${entry.value}';
                  }
                }
              }),
              child: const Text('导入 ytstatus config.json'),
            ),
            FilledButton(
              onPressed: () => action(
                () => controller.save({
                  for (final entry in fields.entries)
                    entry.key: entry.value.text,
                }),
              ),
              child: const Text('保存配置'),
            ),
            Obx(
              () => OutlinedButton(
                onPressed: controller.busy.value
                    ? null
                    : controller.updateStatus,
                child: Text(controller.busy.value ? '更新中…' : '立即检查并发送'),
              ),
            ),
          ],
        ),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.red)),
        Obx(() => Text(controller.message.value)),
        Obx(() => Text(controller.ranking.value)),
        Obx(
          () => Column(
            children: controller.issues
                .map(
                  (issue) => ListTile(
                    title: Text('${issue.id} · ${issue.summary}'),
                    subtitle: Text(controller.date(issue.expiration)),
                    leading: Icon(
                      Icons.circle,
                      color: switch (issue.colorIndex(
                        DateTime.now(),
                        controller.config.number('warning_hours'),
                      )) {
                        3 => Colors.red,
                        2 => Colors.amber,
                        _ => Colors.black,
                      },
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
}
