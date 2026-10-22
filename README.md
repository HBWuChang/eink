# HUAWEI A0 3.98" 墨水屏 · ESP32-S3 + macOS 控制器

两个部分：

```text
eink/       ESP32-S3 ESP-IDF 固件（BLE 接收图片 + A0 墨水屏刷新）
controller/ Flutter macOS 应用（选图、旋转、裁剪、四色量化、BLE 发送）
```

## 硬件

原 PCB 已拆除 U1（复旦微 FMSC NFC 控制芯片），保留 U3 高压 PMIC、FPC 和升压电路。

| 原 PCB | ESP32-S3 |
|---|---|
| `3V3` | `3V3` |
| `GND` | `GND` |
| `DIN` | `GPIO11` |
| `CLK` | `GPIO12` |
| `CS` | `GPIO10` |
| `DC` | `GPIO9` |
| `RST` | `GPIO8` |
| `BU` | `GPIO13` |

`DIN` 是 SPI MOSI，`BU` 是 BUSY（高=空闲，低=忙）。不要接 `VCOM/VGH/VGL/VSH/VSL` 等高压测试点。

## ESP32-S3 固件

```bash
source ~/.espressif/tools/activate_idf_v6.0.2.sh
cd /Users/cd022/HBWuChang/code/eink/eink
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

上电后只启动 BLE，不初始化 Wi-Fi。设备广播名：

```text
HUAWEI-EPD-A0
```

收到完整图片并通过 CRC 后，固件在独立任务中刷新屏幕，BLE 继续在线。

### BLE 协议

Service：

```text
e1d00001-7a3b-4c5d-8e9f-0123456789ab
```

| 特征值 | UUID | 属性 |
|---|---|---|
| Control | `e1d00002-7a3b-4c5d-8e9f-0123456789ab` | Write |
| Status | `e1d00003-7a3b-4c5d-8e9f-0123456789ab` | Read |
| Info | `e1d00004-7a3b-4c5d-8e9f-0123456789ab` | Read |

Control 命令：

```text
01 + 图像长度 LE32 + CRC32 LE32     START
02 + offset LE32 + 数据              DATA
03                                   COMMIT（校验并刷新）
04                                   ABORT
```

Status 10 字节：

```text
[state][error][received LE32][total LE32]
```

图像固定：

```text
768 × 552，2bpp，105984 字节
颜色码：0=黑 1=白 2=黄 3=红
A0 行交错：0..275 -> 偶数行；276..551 -> 奇数行反向
```

单包最大 180 字节（含 5 字节头），Flutter 会根据协商 MTU 自动缩小。

DATA 使用 write-without-response 提高吞吐；START / COMMIT 仍使用带响应写。发送完成后 App 轮询 Status 确认 `received`，再提交 COMMIT。Status 不使用 Notify，避免刷新任务跨任务调用 NimBLE 通知导致中断看门狗复位。

## Flutter macOS 应用

```bash
cd /Users/cd022/HBWuChang/code/eink/controller
flutter pub get
flutter run -d macos
# 或
flutter build macos
```

已配置 macOS：

- `NSBluetoothAlwaysUsageDescription`
- `com.apple.security.device.bluetooth`
- `com.apple.security.files.user-selected.read-only`

功能：

- GetX 作为状态管理
- Hive 保存发送历史与上次设备
- 选择图片，EXIF 方向修正
- 90° 旋转
- 横向/纵向裁剪
- 缩放到 768×552，白底居中
- 最近四色量化
- 可选 Floyd–Steinberg 四色抖动（与手机 App `ImageRaster` 相同）
- CRC32 + BLE 分包发送
- 等待 ESP32 返回完成状态

## 使用流程

1. ESP32-S3 上电，串口显示 `ready; BLE name=HUAWEI-EPD-A0`。
2. macOS 打开应用，点击扫描。
3. 连接 `HUAWEI-EPD-A0`。
4. 选择图片或加载四色测试图。
5. 调整旋转和裁剪，等待预览生成。
6. 点击“发送并刷新”。
7. 等待状态变为“完成”。

## 已知限制

- 当前只验证 macOS 构建；其他平台未配置权限。
- 只做全屏刷新，不做局刷。
- 固定 A0 768×552 四色，不做 A1/A1.1。
- 图片使用最近色量化；抖动默认关闭，可在界面开启。
- 四色调色板与手机 App 一致：黑、白、`0xF5CD00` 黄、`0xC80000` 红。
- BLE 未启用配对/加密，仅适合本地个人使用。
- 为了让刷新任务完全不碰 NimBLE，Status 只读；App 轮询状态，不依赖通知。
- 如果 U1 拆除后 U3 高压使能失效，屏幕不会刷新；需要检查 U3 EN/PMIC 使能，这是硬件问题。
