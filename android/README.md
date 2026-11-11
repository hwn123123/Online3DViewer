# Android 离线查看器原型

这个原型复用项目的网页查看器和离线 JS / WASM 解析器，通过 Android WebView 和系统文件选择器运行，不上传模型。它尚未移植 iOS 的原生分块读取器、模型库、缓存与内存保护；大模型可能无法打开。尤其不能将 iOS 上对 3DM、SKP、DWG / DXF 等格式的支持等同于本原型，MAX / BLEND 原始工程也不支持。请只用测试文件验证。

## 构建

需要 JDK 17、Android SDK 35；项目自带 Gradle 8.9 Wrapper，首次使用需要下载 Gradle 和 Android Gradle Plugin 8.7.2。网页离线资源目前由 `tools/prepare_ios.py` 生成至 `build/ios/WebAssets`（构建资源所需步骤见 `ios/README.md`）；它不是 iOS 应用或 iOS 原生解析器。之后运行：

```sh
cd android
./gradlew :app:assembleDebug
```

产物为 `app/build/outputs/apk/debug/app-debug.apk`。无需后台服务；资源以 WebView 的本地请求方式提供。文件选择器将选中模型和配套文件复制至应用缓存，原文件不变，缓存不是持久模型库。

为避免原型使用网页解析器读取大文件时耗尽内存，直接导入总大小当前限制为 128 MiB 和设备 Java 内存等级的五分之一中较小的值。大模型的流式加载需要后续移植原生读取器；这个限制不是最终产品能力。选择的文件保存在 App 缓存，下一次成功打开模型后清理旧导入副本。

## 真机冒烟测试

安装 Debug APK 后运行（需要设备可通过 ADB 连接）：

```sh
python3 tools/test_android_device.py --device 设备序列号
```

测试依次检查内置 STL、GLB、3DM 示例及 Debug 专用 content URI 导入，截图写入 `build/android-tests/`。它不能代替系统文件选择器、外部 App 分享或大模型的测试。Debug 文件提供器不包含在 Release 版本中。

## 后续移植

- 将 iOS 原生读取器中可共用的 C/C++ 解析和分块输出逐步拆分为平台无关核心，再以 Android NDK / JNI 接入；文件访问、线程取消及内存压力监听由 Android 实现。
- 先从 STL 打通分块读取、分页显示与清理，再逐个移植 3DM、GLB / glTF、OBJ / FBX、SKP 和 CAD。每种格式需分别验证几何、材质、异常恢复及不同设备的资源压力。
- 补齐模型库、持久缓存、设置、外部分享及加载取消，并在真实手机和平板上验证；现有网页读取路径和 iOS 的功能范围不同。
