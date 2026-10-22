import 'dart:typed_data';

class BleProtocol {
  static const String deviceName = 'HUAWEI-EPD-A0';
  static const String serviceUuid =
      'e1d00001-7a3b-4c5d-8e9f-0123456789ab';
  static const String controlUuid =
      'e1d00002-7a3b-4c5d-8e9f-0123456789ab';
  static const String statusUuid =
      'e1d00003-7a3b-4c5d-8e9f-0123456789ab';
  static const String infoUuid =
      'e1d00004-7a3b-4c5d-8e9f-0123456789ab';

  static const int imageWidth = 768;
  static const int imageHeight = 552;
  static const int rowBytes = imageWidth ~/ 4;
  static const int imageBytes = rowBytes * imageHeight;

  static const int cmdStart = 0x01;
  static const int cmdData = 0x02;
  static const int cmdCommit = 0x03;
  static const int cmdAbort = 0x04;

  static const int maxPacket = 180;
  static const int maxDataChunk = maxPacket - 5;

  static Uint8List startPacket(Uint8List image) {
    final out = Uint8List(9);
    final data = ByteData.sublistView(out);
    out[0] = cmdStart;
    data.setUint32(1, image.length, Endian.little);
    data.setUint32(5, crc32(image), Endian.little);
    return out;
  }

  static Uint8List dataPacket(int offset, Uint8List chunk) {
    final out = Uint8List(5 + chunk.length);
    final data = ByteData.sublistView(out);
    out[0] = cmdData;
    data.setUint32(1, offset, Endian.little);
    out.setRange(5, out.length, chunk);
    return out;
  }

  static Uint8List get commitPacket => Uint8List.fromList([cmdCommit]);
  static Uint8List get abortPacket => Uint8List.fromList([cmdAbort]);

  /// CRC-32/ISO-HDLC (same as zlib / IEEE 802.3).
  static int crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

enum EpdState { idle, receiving, refreshing, done, error }

enum EpdError {
  none,
  length,
  offset,
  crc,
  busy,
  refresh,
  command,
  state,
}

class EpdStatus {
  const EpdStatus({
    required this.state,
    required this.error,
    required this.received,
    required this.total,
  });

  final EpdState state;
  final EpdError error;
  final int received;
  final int total;

  static const idle = EpdStatus(
    state: EpdState.idle,
    error: EpdError.none,
    received: 0,
    total: 0,
  );

  factory EpdStatus.fromBytes(List<int> bytes) {
    if (bytes.length < 10) return idle;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final stateIndex = bytes[0];
    final errorIndex = bytes[1];
    return EpdStatus(
      state: stateIndex >= 0 && stateIndex < EpdState.values.length
          ? EpdState.values[stateIndex]
          : EpdState.error,
      error: errorIndex >= 0 && errorIndex < EpdError.values.length
          ? EpdError.values[errorIndex]
          : EpdError.command,
      received: data.getUint32(2, Endian.little),
      total: data.getUint32(6, Endian.little),
    );
  }

  double get progress {
    if (total <= 0) return 0;
    return (received / total).clamp(0.0, 1.0);
  }

  bool get isFinished =>
      state == EpdState.done || state == EpdState.error;

  String get stateLabel => switch (state) {
        EpdState.idle => '空闲',
        EpdState.receiving => '接收中',
        EpdState.refreshing => '刷新中',
        EpdState.done => '完成',
        EpdState.error => '错误',
      };

  String get errorLabel => switch (error) {
        EpdError.none => '',
        EpdError.length => '数据长度错误',
        EpdError.offset => '接收偏移错误',
        EpdError.crc => 'CRC 校验失败',
        EpdError.busy => '设备忙',
        EpdError.refresh => '屏幕刷新失败',
        EpdError.command => '未知命令',
        EpdError.state => '状态错误',
      };
}
