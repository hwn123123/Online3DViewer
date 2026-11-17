# Android 离线查看器原型

这个原型复用项目的网页查看器和离线 JS / WASM 解析器，通过 Android WebView 和系统文件选择器运行，不上传模型。直接导入的 STL 和 3DM 已接入安卓本机分块读取、分页显示、内存和存储检查，以及取消操作。3DM 支持基本颜色、材质、曲线和块实例，支持图层显隐；尚未完整支持贴图、渲染材质、无显示网格的曲面及文字标注。未显示或部分显示的对象会提示。其他格式仍使用网页解析器；提供本地模型库和持久缓存；不能将 iOS 上的 SKP、DWG / DXF 支持等同于安卓，MAX / BLEND 原始工程也不支持。

## 构建

需要 JDK 17、Android SDK 35、NDK 27.2.12479018 和 CMake 3.22.1；项目自带 Gradle 8.9 Wrapper，首次使用需要下载 Gradle 和 Android Gradle Plugin 8.7.2。当前 APK 构建目标为 Android 10（API 29）及以上的 arm64 设备。网页离线资源目前由 `tools/prepare_ios.py` 生成至 `build/ios/WebAssets`（构建资源所需步骤见 `ios/README.md`）；它不是 iOS 应用或 iOS 原生解析器。准备好离线网页资源后，在仓库根目录准备固定版本的 openNURBS 源码：

```sh
python3 tools/prepare_android_opennurbs.py
```

然后运行：

```sh
cd android
./gradlew :app:assembleDebug
```

产物为 `app/build/outputs/apk/debug/app-debug.apk`。无需后台服务；资源以 WebView 的本地请求方式提供。文件选择器将选中模型和配套文件复制至应用私有模型库，原文件不变。模型库可重新打开、清理显示缓存或删除 App 内副本；清理缓存不会删除模型副本。卸载 App 会删除其私有数据。

直接导入的 STL 以最多 16,384 个三角面为一块写入临时缓存，边读取边显示；不使用旧的文件大小上限，但仍受设备的可用内存、存储和渲染能力限制。读取和显示期间可以取消，清理未完成的缓存；内存或存储不足、文件损坏时会停止并提示。直接导入的 3DM 使用本机 openNURBS 增量读取，逐对象写入缓存；大量小对象会按样式合批并保留对象范围。单个复杂对象、块实例、存储和可用内存仍有设备限制。其他使用网页解析的格式，导入总大小暂限为 128 MiB 与设备 Java 内存等级五分之一中的较小值。STL 和 3DM 完成的显示缓存可在下次打开时复用；其他格式仍需重新解析。相同名称及内容的文件组会复用已有副本。 几何分页预算会根据设备总内存和当前可用内存选择 24、48、96 或 192 MiB，低内存设备优先使用较小预算。系统报告内存压力时立即降至 12 MiB，资源恢复后再回升；回升时需要重新填充缓存。该预算仅覆盖分页器管理的几何数据，并不是整个 App、WebView 或 GPU 的内存上限。

查看画面右下角的“测量”可选取两点并显示距离，靠近命中的网格顶点或线段端点时吸附；未吸附时使用表面或线段上的点。结果基于显示几何，可能与原始 CAD 曲面有误差。新生成的 3DM 缓存识别毫米、厘米、米、英寸和英尺；旧缓存或未提供单位的格式需手动选择文件坐标单位，选择不会换算模型。更换单位前应先确认文件原始单位。

测量面板支持撤销上一个点，并显示两个点分别吸附到了顶点还是落在表面或线段上。FBX 带有可识别的标准单位元数据时自动显示该单位；缺失或不是常用单位时仍需手动确认。

## 真机冒烟测试

安装 Debug APK 后运行（需要设备可通过 ADB 连接）：

```sh
python3 tools/test_android_model_library.py --device 设备序列号
python3 tools/test_android_device.py --device 设备序列号
python3 tools/test_android_stl_device.py --device 设备序列号
python3 tools/test_android_rhino_device.py --device 设备序列号
```

冒烟测试检查内置 STL、GLB、3DM 示例及 Debug 专用 content URI 导入；STL 测试核对二进制与文本 STL 的几何、低预算分段读取及损坏文件处理。3DM 设备测试依赖已准备的 iOS 对照缓存与块实例样本，核对对象、嵌套变换、颜色和二进制几何。合批缓存可用 `tools/verify_android_rhino_batches.py --reference 参考缓存目录 --android 安卓缓存目录` 独立核对对象、样式和抽样几何。结果写入 `build/android-tests/`。它们不能代替外部 App 分享和不同设备上大模型的测试。Debug 文件提供器不包含在 Release 版本中。

`tools/generate_rhino_instances.mm` 可生成包含大量独立对象与嵌套块的 `mixed-batches.3dm`。将它放在 `build/android-tests/mixed-fixtures/`，并用 `build/ios/rhino-stream` 生成 `build/android-tests/mixed-reference/` 对照缓存后，3DM 设备测试会自动检查合批对象、块实例、变换及几何。完成的缓存清单采用流式校验，清单超过 32 MiB 时仍可复用；文件缺失或长度不符会触发重建。

## 后续移植

- 将 iOS 原生读取器中可共用的 C/C++ 解析和分块输出逐步拆分为平台无关核心，再以 Android NDK / JNI 接入；文件访问、线程取消及内存压力监听由 Android 实现。
- 在 STL 和 3DM 分块读取、分页显示与清理的基础上，逐个移植 GLB / glTF、OBJ / FBX、SKP 和 CAD。每种格式需分别验证几何、材质、异常恢复及不同设备的资源压力。
- 完善设置、外部分享及加载取消，并在真实手机和平板上验证；现有网页读取路径和 iOS 的功能范围不同。

## 导航性能与内存保护

`MemoryPolicy` 选择显示几何缓存预算，不会修改模型内容。内存充足时提高预算，以减少旋转时的重复读取；预算不足以容纳画面时仍会分批绘制，因此复杂模型和低内存设备可能需要等待。系统仅通知界面隐藏不作为内存不足处理；真正的内存压力会降低缓存，资源恢复时再逐步恢复预算。

缓存预算分级逻辑可在电脑上独立检查：

```sh
mkdir -p build/android-tests/memory-policy
javac -d build/android-tests/memory-policy android/app/src/main/java/com/hwn/modelviewer/MemoryPolicy.java android/tests/MemoryPolicyTest.java
java -cp build/android-tests/memory-policy com.hwn.modelviewer.MemoryPolicyTest
```
