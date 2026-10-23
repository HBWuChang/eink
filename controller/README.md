# HUAWEI A0 墨水屏控制器

Flutter macOS / Android 应用：选择图片、旋转、裁剪、四色量化，通过 BLE 发送到 ESP32-S3 并刷新 A0 墨水屏。

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

## Android

```bash
flutter run -d <Android设备ID>
flutter build apk --debug
```

APK 输出：`build/app/outputs/flutter-apk/app-debug.apk`。
首次扫描时允许蓝牙/附近设备权限；Android 11 及以下还需要定位权限和开启系统定位服务。
蓝牙未开启时会弹出系统开启请求。图片通过系统文件选择器选择。

页面使用安全区域的可用宽高：高大于宽时，图片编辑区、蓝牙设备和发送历史从上到下排列，展示区为 1:1，整页可滚动；横屏保留左右分栏，高度不足时可上下滚动。
展示区的正方形比例不改变墨水屏输出的 768 × 552 尺寸与裁剪框比例。

## 技术栈

- GetX 状态管理
- Hive 本地发送历史、上次设备
- flutter_blue_plus BLE
- image 图片解码/旋转/裁剪/量化
- Floyd–Steinberg 四色抖动，与 Android 项目 `ImageRaster` 一致

## BLE 设备

广播名：`HUAWEI-EPD-A0`

完整协议、接线和固件构建见上一级目录的 `README.md`。
