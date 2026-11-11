# Android 离线查看器原型

这个原型复用项目的网页查看器和离线 JS / WASM 解析器，通过 Android WebView 和系统文件选择器运行，不上传模型。直接导入的 STL 已接入安卓本机分块读取、分页显示、内存和存储检查，以及取消操作。其他格式仍使用网页解析器；模型库和持久缓存尚未实现，大模型可能无法打开。尤其不能将 iOS 上对 3DM、SKP、DWG / DXF 等格式的支持等同于本原型，MAX / BLEND 原始工程也不支持。请只用测试文件验证。

## 构建

需要 JDK 17、Android SDK 35；项目自带 Gradle 8.9 Wrapper，首次使用需要下载 Gradle 和 Android Gradle Plugin 8.7.2。网页离线资源目前由 `tools/prepare_ios.py` 生成至 `build/ios/WebAssets`（构建资源所需步骤见 `ios/README.md`）；它不是 iOS 应用或 iOS 原生解析器。之后运行：

```sh
cd android
./gradlew :app:assembleDebug
```

产物为 `app/build/outputs/apk/debug/app-debug.apk`。无需后台服务；资源以 WebView 的本地请求方式提供。文件选择器将选中模型和配套文件复制至应用缓存，原文件不变，缓存不是持久模型库。

直接导入的 STL 以最多 16,384 个三角面为一块写入临时缓存，边读取边显示；不使用旧的文件大小上限，但仍受设备的可用内存、存储和渲染能力限制。读取和显示期间可以取消，清理未完成的缓存；内存或存储不足、文件损坏时会停止并提示。其他使用网页解析的格式，导入总大小暂限为 128 MiB 与设备 Java 内存等级五分之一中的较小值。选择的文件保存在 App 缓存，下一次成功打开模型后清理旧导入副本。 默认几何分页预算为 48 MiB，系统内存压力时降低；该预算仅覆盖分页器管理的几何数据，并不是整个 App、WebView 或 GPU 的内存上限。

## 真机冒烟测试

安装 Debug APK 后运行（需要设备可通过 ADB 连接）：

```sh
python3 tools/test_android_device.py --device 设备序列号
python3 tools/test_android_stl_device.py --device 设备序列号
```

冒烟测试检查内置 STL、GLB、3DM 示例及 Debug 专用 content URI 导入；STL 测试另外校验二进制与文本 STL 的全部三角面、低预算分段读取及损坏文件处理，截图和结果写入 `build/android-tests/`。它们不能代替外部 App 分享和不同设备上大模型的测试。Debug 文件提供器不包含在 Release 版本中。

## 后续移植

- 将 iOS 原生读取器中可共用的 C/C++ 解析和分块输出逐步拆分为平台无关核心，再以 Android NDK / JNI 接入；文件访问、线程取消及内存压力监听由 Android 实现。
- 在 STL 分块读取、分页显示与清理的基础上，逐个移植 3DM、GLB / glTF、OBJ / FBX、SKP 和 CAD。每种格式需分别验证几何、材质、异常恢复及不同设备的资源压力。
- 补齐模型库、持久缓存、设置、外部分享及加载取消，并在真实手机和平板上验证；现有网页读取路径和 iOS 的功能范围不同。
