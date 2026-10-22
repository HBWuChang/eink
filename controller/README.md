# HUAWEI A0 墨水屏 macOS 控制器

Flutter macOS 应用：选择图片、旋转、裁剪、四色量化，通过 BLE 发送到 ESP32-S3 并刷新 A0 墨水屏。

## 运行

```bash
flutter pub get
flutter run -d macos
```

构建：

```bash
flutter build macos
```

首次使用会触发 macOS 蓝牙权限。应用已配置蓝牙和用户选择文件的 sandbox 权限。

## 技术栈

- GetX 状态管理
- Hive 本地发送历史、上次设备
- flutter_blue_plus BLE
- image 图片解码/旋转/裁剪/量化
- Floyd–Steinberg 四色抖动，与 Android 项目 `ImageRaster` 一致

## BLE 设备

广播名：`HUAWEI-EPD-A0`

完整协议、接线和固件构建见上一级目录的 `README.md`。
