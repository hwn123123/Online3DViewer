# iPhone / iPad App

这是基于 Online3DViewer 的本地 iOS App，使用 SwiftUI + WKWebView，支持 iOS / iPadOS 17.0 及以上。

## 使用

- 首页为本地模型库：显示缩略图、名称、大小和最近打开时间，可搜索名称。右上角加号通过系统文件选择器导入模型，每次选择一个模型，可同时选择 MTL、贴图等配套文件，也可以尝试打开包含它们的 ZIP。
- 首页“内置示例”可打开 GLB、STL、FBX、Rhino 3DM、STEP、IFC 示例，首次打开后也会加入模型库。
- 点击模型卡片再次打开；右上角存储管理查看占用并清理全部缓存；卡片更多菜单可清理单个模型缓存或删除 App 内的模型副本。清理缓存保留模型副本，删除模型不会改动导入前的原始文件。
- 原始模型副本、模型库索引和缩略图保存在 Application Support；显示缓存单独放在 Caches。导入时按文件内容识别重复文件；从模型库再次打开无需重新复制，3DM、STL、GLB / glTF、SKP / SKPBAK 及原生路径读取的大 OBJ / FBX 会验证并复用已完成的分块缓存。其他格式目前复用模型副本，仍需重新解析。
- 导入、读取和显示阶段均有原生状态条和取消按钮。取消会返回模型库，停止当前任务并释放网页解析上下文，未完成的导入与几何缓存会清理。3DM 原生读取在当前对象完成后响应取消。
- 模型准备期间阻止旋转、缩放、对象选择和图层更改，完成读取、缓存整理和最终画面后才恢复操作；取消及返回模型库仍可使用。
- “设置”可选择白色或深色背景、自由旋转或固定向上、透视或正交投影、是否查看时保持屏幕常亮，以及自动或节省内存的显示策略。设置保存在本机；节省内存会降低显示缓存预算，系统内存压力保护始终生效。设置中可进入存储管理、查看占用、清理缓存及查阅开源许可。
- 支持从“文件”等其他 App 的“共享 / 用其他应用打开”入口传入文件。
- 模型、贴图和解析器全部在设备本地处理，不上传模型，不依赖电脑、远程网页或转换服务。
- 直接导入的 3DM 使用原生分批读取：每次处理一个对象，将显示网格写入本地分块缓存，视图逐批显示。右上角图层按钮可开关图层、查看对象列表，点击模型可查看对象属性。
- 直接导入且达到 16 MiB 的 OBJ / FBX 使用原生 ufbx 读取，解析后分批生成并显示几何块。保留原有网格三角形、法线、UV、顶点色、材质分配与对象名称；支持静态场景、实例变换、NURBS 曲面与可验证的参数域裁剪边界。没有通过删对象或删三角形减小模型。ZIP 内的模型仍走网页导入器。
- 直接打开的 STL，不论大小，均使用原生文本 / 二进制分块读取与缓存，最多每块 16,384 个三角形；保留全部三角面和绕序，缺少或为零的法线按面计算。读取、显示可取消，损坏文件和资源不足会停止任务并返回模型库。
- 直接打开的 GLB / glTF 2.0 使用原生本地读取及分块显示。支持外置 BIN / 贴图、base64 内嵌数据、实例共享、默认形变和骨骼姿态，以及基础 PBR、透明模式和纹理变换。Draco 压缩网格现已接入原生路径，Meshopt / KTX2 等未接入的必需扩展会明确报错。ZIP 内的文件仍走原有导入器。
- App 默认自由旋转，单指上下拖动可以连续翻转，双指用于缩放和平移。App 的旋转模式偏好独立保存；旧版“保持向上”的网页偏好不会继续限制 App 的上下翻转。
- 直接打开的 SKP / SKPBAK 使用本地 OpenSKP 读取，支持网格、组件实例、独立边线、图层显隐及基本材质贴图。文字、标注、辅助几何和剖切设置会提示尚未显示。ZIP 内的 SKP 尚未接入此路径。
- 所有 JS / WASM 解析器随 App 安装。新增格式仍需要对应的本地导入器；当前不包含 MAX / BLEND 原始工程文件的通用转换器。
- 直接导入的 DWG / DXF 使用本地 acadrust 读取，转换为分块缓存显示。支持基本几何、块、文字、标注及部分填充；ACI 7 黑白色随背景调整。ACIS 实体表面、代理对象及其他未适配内容会在状态栏提示，可打开未显示内容明细。只显示模型空间，暂不处理打印布局及 ZIP 内的 DWG / DXF。具体范围见下方 DWG / DXF 说明。

## 构建

需要 macOS、Xcode、Node.js 22+、Python 3、Rust 1.99.1 及 `aarch64-apple-ios` 目标（`rustup target add aarch64-apple-ios`）。CAD 构建脚本优先使用项目内已安装的 `build/ios/rust-tools/`，否则使用 PATH 中的 Rust。首次准备构建资源需要联网下载固定版本的第三方解析器；安装后的 App 不需要这些下载。

```sh
npm ci --no-audit --no-fund
npm run create_dist
python3 tools/build_opennurbs.py
python3 tools/build_draco.py
python3 tools/build_openskp.py
python3 tools/build_cad_reader.py --ios
python3 tools/prepare_ios.py
python3 ios/generate_project.py
open ios/Online3DViewer.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择自己的 Team，选择连接的 iPhone / iPad 后 Run。工程不保存个人签名信息。

命令行完整构建并生成开发测试 IPA：

```sh
O3DV_TEAM_ID=你的TeamID zsh ios/build-ios.sh
```

产物：`build/ios/Online3DViewer.ipa`；Xcode 的设备 `.app` 位于 `build/ios/DerivedData/Build/Products/Debug-iphoneos/Online3DViewer.app`。

IPA 为开发签名，仅能安装到描述文件登记的设备，签名有效期由 Apple 账号及描述文件决定。给另一台 iPad 测试时，需要先在 Xcode 登记该设备并重新构建。

## 离线资源

`tools/prepare_ios.py` 将正式网页产物复制到 `build/ios/WebAssets`，并从固定版本 npm 包提取 Rhino、web-ifc、Draco、Open CASCADE 的 JS / WASM 及许可证。构建缓存和二进制资源放在 Git 忽略的 `build/` 目录。

`tools/build_opennurbs.py` 下载固定提交的 openNURBS 并编译 iPhoneOS 静态库，首次需要联网及 CMake。脚本找不到 CMake 时会安装固定版本到构建目录的 Python 虚拟环境。openNURBS 的许可证随 App 资源打包。

`ios/Online3DViewer/ThirdParty` 包含固定版本的 ufbx 及 earcut.hpp 源码，均保留上游许可证并随 App 打包。大 OBJ / FBX 在原生层读取。可拆分的二进制 FBX 按几何对象组织解析批次，保留原始层级、实例、静态骨骼变换和材质；每批的数组解码预算为 64 MiB，单个不可再拆的源几何可能超过此值。其余场景使用同一解析器的磁盘映射工作区，避免把所有解码数据同时留在私有物理内存中。分配前检查本地空间，保留 512 MiB 存储余量；分批完成、取消和进程退出时释放临时工作文件。物理占用和系统可用内存也会触发停止保护。缓存、临时存储、地址空间及单个原子对象仍有设备限制，不承诺任意大小的模型都能成功打开。

App 内的 `LocalAssetServer` 仅监听设备自身的 `127.0.0.1` 随机端口，用于让 WKWebView 读取内置文件、模型副本与分块缓存，不监听 Wi-Fi 地址。内容安全策略限制外部资源连接。选中的文件通过系统协调器以小块复制进模型库，并计算内容指纹；不把大模型整份放进内存。

## DWG / DXF 本地分块显示

`ios/CadReader` 是 Rust 静态库，`CadStreamReader.mm` 负责取消、设备资源检查和 Swift 桥接。固定使用 acadrust 0.6.8（提交 `362561cd8b44bbb4bbf5cad5b95fb16eb976b93d`，MPL-2.0）。`tools/build_cad_reader.py` 生成单独的源码副本，给解析器的显式大容量分配和解码循环添加检查，不覆盖全局分配器。原始依赖和模型均不修改。所用依赖的许可及对应修改源码随 App 打包，可在“存储管理 → 开源许可”查看和导出。

DWG 按约 5,000 个实体一批处理，网格不使用截断面数的解析选项；块成员通过共享引用保留，支持后续批次引用。DXF 当前由依赖库完整解析后分块输出。两者均生成固定规模的几何块，最多约 24,000 个索引或线段端点，然后交给原有分页显示器。曲线按几何容差离散；原始三角面保留，凹多边形经过三角化并核对面积和绕序，重复或共线的角点允许产生较少的非零面积三角形，完全退化的面保留确定的退化三角形。

解析单次请求默认上限 128 MiB，DWG 解压累计预算 128 MiB；另外检查进程物理占用、系统可用内存和磁盘余量。读取过程中约每 5 毫秒采样，较大显式请求立即检查，物理占用超过 448 MiB 或预留余量不足会停止；保留 512 MiB 存储余量。这些检查覆盖已接入的分配和解码路径，并非整个 Rust 堆的硬上限。共享块、单个复杂实体、依赖内部集合及解压对象区仍可能受限，不能保证任意大小的图纸都能打开。资源不足、取消、损坏或未完整解析时清理本次缓存；不会把缺少对象区的空结果当成成功。

文字通过 Core Text 排版、生成矢量几何，再复用同一分页显示器。支持 TEXT 的基本对齐、旋转、宽度、倾斜、镜像、OCS，以及 MTEXT 的基本换行、字体、局部字高/字宽、颜色和装饰线。字体轮廓先按非零绕序规范化，合并中文重叠笔画，再进行带孔三角化；字形缓存限制为 8 MiB，每次转换前后清理。未安装的原字体和 SHX 使用系统替代字体，App 提示可能存在字形和宽度差异。

块引用显示 ATTRIB 的实际值和常量 ATTDEF；属性坐标按所在绘图空间处理，避免重复应用所属 INSERT 的变换。尺寸标注优先显示文件保存的匿名图形块；未保存图形时按读取器支持的尺寸样式重建，并在“显示说明”提示。后者的特殊尺寸样式、布局及文字测量仍需与原 CAD 软件对照，不作为精确测量或出图依据。

支持 LEADER 的引线、标准实心箭头及块变换；样条引线近似重建并提示，自定义箭头暂不显示并提示。HATCH 支持纯色、线条及虚线图案，内部孔洞和嵌套边界，直线、多段线、圆弧、椭圆弧及可求值样条边界；曲线按显示容差离散。渐变、双重图案、含点图案、MPolygon、无效边界及过密图案暂不显示并提示。暂不处理 ACIS 实体网格化、MLEADER、光栅图像、OLE、代理对象、外部参照文件、曲线厚度和宽度、细分网格平滑、线型图案、打印布局或动画。文字竖排不显示并提示；多栏、特殊段落、堆叠分数和背景遮罩目前按基本排版显示或提示缺失。上述原始数据仍保留在导入副本中。部分支持的类型会列入提示；现有图层颜色与坐标核对不能代替与原 CAD 软件逐图比较，尤其需继续检查自定义对象和读取器诊断。CAD 缓存版本为 `cad-stream-4`，旧版本缓存重新生成，以免沿用缺少填充等内容的结果。

验证入口：

```sh
python3 tools/build_cad_reader.py
xcrun clang++ -O2 -std=c++17 -fobjc-arc -I ios/Online3DViewer tools/cad_stream_cli.mm ios/Online3DViewer/CadStreamReader.mm ios/Online3DViewer/CadTextRenderer.mm build/ios/cad-target/release/libo3dv_cad.a -framework Foundation -framework CoreText -framework CoreGraphics -liconv -o build/ios/cad-stream
build/ios/model-analysis-env/bin/python tools/test_cad_stream.py --executable build/ios/cad-stream --work-files
python3 tools/test_cad_device.py --device 你的设备UDID
```

几何核对脚本需要 NumPy。`tools/test_cad_pager.cjs` 检查完整与受限预算下的最终画面一致性、提示信息和黑白背景颜色；复用 `tools/build_gltf_test_bundle.cjs`、`tools/serve_gltf_tests.swift` 的本地测试环境。真机用例使用隔离副本，测试后清理，不加入用户模型库。原先 225 份图纸的电脑端可行性调查仍见 [读取器验证说明](../tools/cad_probe/README.md)，不将该调查的解析通过率当成 App 的显示支持率。

文字与标注检查见 `tools/test_cad_text.py`、`tools/test_cad_text_pager.cjs`、`tools/test_cad_text_device.py`。原生脚本默认使用 `build/ios/cad-text-stream`，可用上面的命令修改输出路径生成；检查字形孔洞、重叠笔画、变换、局部字宽、装饰范围、块属性实际值和坐标、保存及重建尺寸标注，以及取消和资源不足后的清理。macOS 与 iOS 的系统替代字体可能不同，不要求两者生成完全相同的三角面数；同一设备的缓存重开及分页画面仍需一致。

## 验证

```sh
python3 tools/test_ios_device.py --device 你的设备UDID
```

该脚本会在已解锁设备上启动 App 的内置示例，读取本地加载结果并截图；结果位于 `build/ios/device-tests/`。不会修改设备网络设置。

测试已放入 App Documents 的大模型：

```sh
python3 tools/test_ios_device.py --device 你的设备UDID --documents SSBX-1106.3dm
```

## 3DM 渐进显示的范围

- 保留对象 ID、名称、图层与材质索引；直接使用文件中保存的 Mesh、Brep / Extrusion 渲染网格，不删对象、不减少原有网格顶点。曲线按模型容差离散为显示线段。
- 目前支持基本材质颜色、透明度及顶点色，完整贴图与 Rhino 渲染材质尚未接入。当前依赖文件保存的渲染网格；完全缺少可用网格的曲面、文字标注及其他尚未实现的几何会标记为不支持。其他 3DM 的曲面覆盖情况仍需逐文件核对。
- 对含大量小对象的 3DM，显示缓存会一次性合并可安全合并的相邻块，保留原对象的选择范围、名称、图层和材质；原始模型不变。旋转时优先复用已驻留的几何。超过缓存预算时，新的视角逐批绘制，完成后替换上一张完整画面，避免零件逐批消失。
- 显示预算回升时，等正在绘制或选择的工作结束后再应用更高预算并填充缓存；预算下降仍立即生效以响应内存压力。状态栏显示当前可见显示块的更新进度，并在上一张完整画面可用时提示正在保留。重新打开、切换图层或快速旋转均按同一调度规则处理。
- 所有原生分块路径共用按预算工作的显示调度器，包含 3DM、STL、GLB / glTF、OBJ 和 FBX。即使当前可见的几何也超过缓存预算，仍可在保留颜色和深度的帧缓冲中分批画完，再释放几何继续下一批；过大的单块通过本地 HTTP Range 进一步拆分读取。几何预算根据可用内存从 64 MiB 自适应提高到 96 或 192 MiB，贴图预算通常为 24 MiB；内存压力下分别降为 24 MiB、12 MiB。帧缓冲单独限制像素数。这些是调度器管理的数据预算，不能当作整个 App、WebContent 或 GPU 的内存总上限。贴图按显示预算生成本地缩略版本，源贴图不变；后台暂停，回前台与图形上下文恢复后重新绘制。
- 此次已验证 SSBX-1106.3dm 的 683 个对象、12 个图层全部读出，没有不支持对象；不代表所有 3DM 文件和其他格式均已使用这条原生读取路径。ZIP 内的 3DM 仍走原有导入器。
- 原文件的精确 CAD 数据不会被修改。本 App 当前提供查看功能，不提供 Rhino 工程编辑或回写。

`ios/generate_project.py` 可以重新生成 Xcode 工程。通常直接使用仓库中已生成的工程即可，重新生成会覆盖工程文件。

模型库的文件去重、持久化、取消和缓存校验测试：

```sh
xcrun swiftc ios/Online3DViewer/ModelLibrary.swift tools/test_model_library.swift -o build/ios/test-model-library
build/ios/test-model-library
```

工程包含 `Online3DViewerUITests`，可在 Xcode 运行真机界面测试。大模型流程测试要求 App Documents 中已有 `SSBX-1106.3dm`，首次运行需要在 iPhone 上允许 UI 自动化。测试包含缓存复用、清理后重建、取消后重开、重启保留模型库，以及删除导入副本。

原生 OBJ 的几何面积、坐标轴、材质、贴图、取消和错误返回检查见 `tools/test_mesh_stream.py`；裁剪边界孔洞验证见 `tools/test_trimmed_surface.cpp`。界面测试 `testNativeFormatInteractionAndCancel` 使用隔离的真实 FBX 副本，验证加载、旋转、缩放和取消；运行前需使用 `tools/audit_work_models.py` 为对应 UUID 放入测试副本。

## 真实工作文件兼容性

2026-11-07 首次对工作目录登记了 40 个模型，现有导入器覆盖的 20 个模型均逐个进行真机加载；加上备份与未支持格式对照，共 26 个用例。初测结果为：3DM 六个中三个显示、两个缺对象、一个 150 秒内未完成；FBX 九个中六个显示、三个大文件导致查看进程退出；OBJ 两个中一个缺 MTL、一个进程退出；两个 3DS 和一个 STL 显示。SKP、MAX、DWG 未接入导入器。

逐文件结果与截图位于 `build/ios/work-model-tests/兼容性测试报告.md`，可筛选页面为同目录 `report.html`。不得将单个文件加载成功当成所有版本、对象类型和文件大小均已支持。测试使用隔离副本，未改变模型库或原始文件。

本轮同时修正了原生 3DM 中间清单的释放与发布频率，以及多对象显示时重复排序、重复适应视角的开销；未通过删对象或减面实现优化。当时大批曲线、块实例、文字标注和缺少保存网格的曲面仍有适配缺口；后续已补齐下述块引用路径。

后续大文件适配复测：`123.obj`（326.65 MiB，1,571,376 三角形）、`123.fbx`（459.65 MiB，99,890 个场景几何对象，含 696 个裁剪曲面）、`天宫6.4.fbx`（280.70 MiB，13,839,793 三角形）均已在 iPhone 完成显示。`123.obj` 原目录缺少 `123.mtl`，显示中明确提示；当时 `入口 妖洞 永宁村6.4.fbx`（1404.73 MiB）仍超出原生解析预算，返回错误；后续通用资源管理已另行复测，结果见 `build/ios/memory-stream-tests/资源管理复测.md`。旧版详情见 `build/ios/native-mesh-tests/大文件适配复测.md`。

## 通用资源管理验证

- `tools/test_fbx_pages.py`：生成 FBX 7400 / 7700 场景，与整场景解析对照几何、变换、实例、法线、UV、显隐、材质及嵌入贴图；另用带骨骼的模型核对静态姿态，并验证批次间取消后的清理。
- `tools/test_mapped_workspace.cpp`：检查磁盘映射扩容/缩容的数据一致性、同步回写、区域复用、取消、失败和文件描述符清理。
- `tools/test_local_asset_server.swift`：核对本地 Range/HEAD/416、响应长度和贴图像素上限。
- `tools/generate_pager_fixtures.py`、`tools/serve_pager_tests.py` 与 `tools/test_native_pager*.cjs`：生成与用户模型无关的几何，用完整缓存与 256 KiB 缓存对照最终像素；检查透明度、预算变化、选择被回收对象、显隐、后台恢复、GPU 上下文恢复、模型替换与渐进清单。浏览器测试需要 Playwright，可设置 `O3DV_PLAYWRIGHT_MODULE`、`O3DV_BROWSER_EXECUTABLE` 指定已有安装。
- 真机界面测试 `testBoundedPagingInteractionAndLifecycle` 使用隔离的生成场景，验证点击对象后恢复绘制、旋转、缩放和前后台切换，不将测试模型写入用户模型库。

资源管理代码按格式、对象结构与预算选择路径，没有用户模型名称或工作目录条件。MAX / BLEND 等未实现的工程格式、尚未支持的几何类型，以及超出设备资源的原子数据块仍需继续适配。SKP 的后续接入见文末。

本轮实现、复测数据及已知限制见 `build/ios/memory-stream-tests/资源管理复测.md`。

## 3DM 块引用与嵌套实例

原生 3DM 读取现支持块定义、嵌套引用、平移/旋转/镜像/非均匀缩放/剪切，以及父级材质、颜色、显隐和图层继承。源对象按原有方式逐个读取并释放，块展开使用几何缓存的元数据；每个实例复用定义的二进制文件，不重复保存网格或曲线。显示调度器继续按预算读取实例所需数据。

定义成员不直接显示；实际放置的叶对象带有源 ID、实例路径和累积变换。空块可以正常读取；缺失的定义/成员、循环引用、无效变换和定义内未支持几何会明确标记。仍未提供外部链接块文件的自动查找与下载，也不会给缺少保存网格的曲面生成新的曲面网格。

旧版含未支持对象的 3DM 缓存在下一次打开时自动重建；当前版本仍含其他未支持对象的缓存不会每次反复重建。完整旧缓存可继续使用。

验证工具：

- `tools/inspect_rhino_model.mm`：逐个对象登记实际 openNURBS 类别、块定义、引用、矩阵和定义成员身份。
- `tools/generate_rhino_instances.mm`、`tools/test_rhino_instances.py`：独立生成嵌套、镜像、非均匀缩放、剪切、继承属性、隐藏父图层、空块及缺失/循环引用场景，核对矩阵、数据范围、几何共享与取消。
- `tools/test_rhino_instances.cjs`：按实例放置的画面与独立烘焙后的参考几何像素对照，检查低预算重绘、层级显隐及变换后网格/曲线拾取。

本轮真机结果见 `build/ios/rhino-geometry-tests/块实例适配复测.md`。

## 分块显示性能

原生分块显示器共用 CPU/GPU 几何资源，实例保留各自的矩阵和材质。最多两个分块读取任务共用几何预算，放置节点数量也有上限；批量提交前固定资源，GPU 完成后再允许回收。缓存齐全时直接绘制，快速操作期间合并等待中的视角，保证最多一幅 GPU 视图在进行。

`tools/generate_render_benchmarks.py`、`tools/benchmark_rendering.cjs`、`tools/benchmark_native_navigation.py` 用于相同工作量的前后对照；`tools/test_render_pipeline.cjs` 核对共享、预算、取消、快速切换、快速转动、贴图回收和最终像素。真机自动转动接口只在 Debug 桥接中开放；测试结束后恢复普通启动。结果和限制见 `build/ios/render-performance-tests/交互性能复测.md`。

## STL 本地分块读取

`StlStreamReader` 使用 64 KiB 输入缓冲及固定容量的几何缓冲，每块最多 16,384 个三角形，边读边写完整缓存。二进制按文件长度和面数判断，支持以 `solid` 开头的二进制头；文本支持注释、指数数值、UTF-8 名称、多个 solid 及省略法线的面。逐块保存双精度原点与相对单精度坐标，保留三角形顺序和绕序；不焊接、不减面、不丢弃退化面。空模型、截断文件、非有限坐标及结构错误会明确报错。

分块读取会检查取消、进程物理占用、系统可用内存和缓存存储空间；二进制预估完整缓存空间，文本逐块检查。标准 STL 不提供统一单位、贴图或材质；非标准二进制属性记录数量，但暂不解码其颜色扩展。源文件保留原始数据。ZIP 中的 STL 仍走原有网页导入器。缓存大小和设备资源仍决定能否完成读取，固定缓冲不意味着任意大小都保证成功。

- `tools/test_stl_stream.py --large`：八个上游 STL、内置示例、真实工作文件与生成场景，核对完整面数、坐标、面积、边界、绕序、分块边界、大坐标、重命名一致性，以及损坏、取消和压力错误。
- `tools/test_stl_pager.cjs`：完整缓存与 256 KiB 显示预算的最终像素对照、分片读取、源 solid 拾取，以及同一相机重绘后的测试等待。
- `tools/test_stl_device.py --device UDID`：隔离真机用例，检查本地解析、缓存重开、旋转、低预算显示、取消后重新读取和错误后的缓存清理；测试素材不加入用户模型库。先运行原生测试生成大文件，再启动本地测试静态资源服务供浏览器验证。

独立原生测试程序可用 `xcrun clang++ -O2 -std=c++17 -fobjc-arc -I ios/Online3DViewer tools/stl_stream_cli.mm ios/Online3DViewer/StlStreamReader.mm -framework Foundation -o build/ios/stl-stream` 编译。真机与几何核对结果见 `build/ios/stl-stream-tests/STL适配复测.md`。

## GLB / glTF 本地读取

使用固定版本 cgltf 解析元数据，二进制数据从只读本地文件映射读取，不调用整文件加载 buffer 的接口。base64 buffer 以固定缓冲解码到临时文件，再读取；完成、失败、取消均清理临时数据。几何每块最多 24,576 个索引，保留三角面和绕序，不减面。实例复用几何文件并保留节点和放置矩阵；不同形变权重及骨骼姿态分别生成对应缓存。

支持索引 / 无索引的三角形、条带、扇形、线段、线环、线带和点，支持交错、归一化及稀疏顶点属性。缓存 v3 保留 RGBA 顶点色、两套 UV 和切线；v1 / v2 原缓存继续可用。glTF 的 Y 轴向上通过放置矩阵转换到查看器的 Z 轴向上。保留场景节点层级元数据；当前界面仍按模型图层和源节点对象提供查看入口。

显示包含基础 metallic-roughness PBR、unlit、法线、金属度 / 粗糙度、AO、自发光贴图、OPAQUE / MASK / BLEND、双面、UV 通道、纹理变换和重复 / 镜像 / 最近邻采样。贴图按预算生成显示版本，已满足预算的小图直接使用原始编码，源图始终不修改；显示贴图不承诺与全分辨率纹理逐像素相同。支持默认 morph 权重及默认骨骼姿态，不播放动画。`extensionsRequired` 中未接入的功能明确失败，可选的部分材质扩展保留基础 PBR 并提示。

元数据 JSON 及解析器堆分配各有限额 64 MiB；内存和存储检查与其他原生读取路径一致，不能保证任意大小、任意扩展的 glTF 均可打开。Meshopt、KTX2 / Basis、GPU 实例扩展、两套以外的 UV，以及其他材质扩展仍需继续适配；未接入的必需扩展会明确报错。Draco 的原生解码范围见下节。

验证入口：

- `tools/test_gltf_stream.py --large`：上游样本与生成场景，独立读取 accessor / topology / 层级变换，比对缓存坐标、面数、线段、点、实例共享、默认形变和骨骼姿态；另检查异常范围、层级循环、取消及内存压力。
- `tools/gltf_reference.js`、`tools/build_gltf_test_bundle.cjs`、`tools/test_gltf_pager.cjs`：使用独立 GLTFLoader 参考场景，核对 PBR / 贴图 / 透明模式；对稀疏交错和剪切场景使用独立烘焙几何，避免参考加载器自身的解码与矩阵分解影响。比较完整缓存和 256 KiB 几何预算的最终画面。测试插桩仅用于测试路由，不进入 App。
- `tools/serve_gltf_tests.swift`：复用 App 的本地 HTTP Range 和 ImageIO 贴图变体服务，静态资源只监听电脑回环地址。
- `tools/test_gltf_device.py --device UDID`：独立 UUID 的真机加载、缓存复用、旋转、取消后重开、外置配套文件、损坏和未支持扩展检查，以及 STL / 3DM 回归。

命令行程序需先构建 macOS Draco 库：`python3 tools/build_draco.py --platform macosx`，再用 `xcrun clang++ -O2 -std=c++17 -fobjc-arc -I ios/Online3DViewer -I build/ios/draco-bounded-src/src -I build/ios/draco-macosx tools/gltf_stream_cli.mm ios/Online3DViewer/GltfStreamReader.mm build/ios/draco-macosx/libdraco.a -framework Foundation -o build/ios/gltf-stream` 编译。最初的基础格式结果与当时缺口见 `build/ios/gltf-stream-tests/GLTF适配复测.md`，后续 Draco 结果见下节。

## Draco 压缩网格

使用固定版本 Draco 1.5.7 的原生静态库，解码三角形及三角形条带，再写入同一 v3 分块缓存。保留解码后的全部几何、法线、颜色、UV、切线和索引，非压缩属性继续按普通 accessor 读取。压缩及未压缩网格可混合存在；实例完成首次转换后复用已有几何缓存。条带恢复会包含连接条带所需的退化面，保留所有有效三角面。

Draco 解码需要还原一个完整压缩网格。修改仅限于解码容器的分配器、资源计数及协作检查，不改上游的几何编码算法：大数组使用已有的磁盘映射工作区，工作文件立即取消目录链接，完成、失败、取消和进程退出均释放。分配前检查存储空间，原生物理占用和系统可用内存继续受保护；解码输入 / 数据写入也会检查取消。工作区沿用 24 MiB 小块堆策略及 512 MiB 存储余量。单个解码操作默认有 1 GiB **逻辑分配量** 上限，其中可以包含文件映射数据，不代表常驻 RAM；内存压力下会降低此上限。小对象 / 元数据另有保守计数。无法满足资源要求时停止加载，不做几何减面。

`DracoMemory.hpp` 的容器分配器只用于固定版本 Draco，不替换 App 全局 new / delete。`tools/build_draco.py` 校验源压缩包 SHA-256，生成受控源码副本并构建 iPhoneOS / macOS 库；许可随 App 安装。cgltf 的本地补丁保留完整 unsigned 32-bit Draco 属性 ID，避免把 ID 当成 accessor 索引，并拒绝无效 ID。

验证入口：

- `python3 tools/prepare_draco_tests.py`：开发电脑上准备固定版本的原版 WASM 编解码器及官方模型，生成小型 / 大型测试素材和独立参考。App 运行时不使用网络转换。
- `tools/test_draco_stream.py`：原生解码缓存与未经修改的官方 WASM 解码结果对照，检查属性、索引、变换、网格数、混合属性、实例、条带、取消及资源失败。
- `tools/test_draco_pager.cjs`：完整缓存与较低几何预算的最终像素对照，并使用独立 GLTFLoader 渲染 WASM 解码后的参考场景。大场景对比 256 MiB / 8 MiB，其余场景对比 256 MiB / 256 KiB。
- `tools/test_draco_memory.cpp`：受控分配、映射内容、移动 / 复制、预算拒绝、取消和释放检查。
- `tools/test_draco_reopen.mm`：同一进程内反复打开、资源拒绝、解码中取消及再次打开，核对物理占用和文件描述符没有持续增长。
- `tools/test_draco_device.py --device UDID`：隔离真机测试，包含 Blender / COLLADA2GLTF 官方模型、材质和贴图、默认骨骼、混合网格、缓存复用、旋转、解码中取消、资源保护和旧格式回归。

`tools/build_draco.py --platform macosx --sanitize` 可构建完整 ASan / UBSan 库。专用 sanitizer 构建将解码容器置于受控堆分配，以便检查分配边界；生产构建使用映射工作区。

本轮实现与结果见 `build/ios/draco-stream-tests/Draco适配复测.md`。仍不承诺所有导出器版本、异常文件及任意大的单一压缩网格均可打开；静态姿态、材质和贴图的其他限制沿用基础 glTF 路径。

## SketchUp SKP / SKPBAK 本地读取

原生读取器使用 MIT 许可的 `iamahsanmehmood/openskp`，固定提交 `c98561147ea502c6d4d53a257fa4581d0c6cde1d`。仅构建读取、拓扑和三角化代码，不引入其 GLB 导出器和大型导出依赖。`tools/build_openskp.py` 校验源压缩包，生成可复现的受控源码副本；许可证随 App 打包。

直接从 SKP 拓扑写入现有分块缓存，保留面、孔洞、法线、UV、独立边线、组件层级、实例矩阵和基本材质。实例复用定义几何，保留镜像和非均匀缩放；支持组件材质继承、不同正反面贴图、图层和对象显隐。贴图按完整内容哈希去重。SKP 使用英寸到米的单位转换及 Z 轴向上。当前仅用于静态查看，不回写工程。

解析器仍需要建立文件拓扑。受控容器使用磁盘映射工作区，较小节点合并到映射页；默认逻辑分配上限 4 GiB，同时检查物理占用、系统可用内存、取消及本地存储余量。逻辑分配量和映射文件大小不等于常驻 RAM，也不代表整个 App 的内存上限。每个几何块最多 24,576 个展开顶点；解析、转换和显示均可停止，失败会清理未完成缓存。

所有原生格式共用的显示调度器将不透明对象按贴图分组，减少贴图反复解码和绘制提交；透明对象继续按从远到近的顺序绘制。预算能同时容纳的贴图可在同一批次使用，并固定到 GPU 完成后才允许回收；已缓存贴图不重复预留像素空间。模型完整几何保留，低预算时分批画完当前视角。

文字、尺寸标注、辅助线和剖切设置会登记并提示尚未显示；场景动画、完整 SketchUp 风格、投影贴图及复杂纹理映射尚不保证与 SketchUp 完全一致。ZIP 中的 SKP 未接入原生路径。实际文件版本、损坏数据和设备资源仍决定能否打开，不能承诺任意文件都成功。

验证入口：

- `tools/prepare_skp_tests.py`：使用独立的上游 Python 写入器生成已知形状，包含孔洞、不同正反面纹理、组件实例、材质继承和显隐。
- `tools/test_skp_stream.py --work-files`：核对坐标、面积、三角面数、单位、实例共享、完整贴图哈希、损坏输入、取消及资源拒绝，并解析工作目录的六份 SKP。
- `tools/test_skp_pager.cjs`：完整缓存与 256 KiB 显示预算的最终像素对照，以及复杂工作模型的绘制测量。复用 `tools/serve_gltf_tests.swift` 的本地资源服务。
- `tools/test_skp_reopen.mm`：同一进程反复读取、资源拒绝、解码中取消和重新打开，检查物理占用和文件描述符回收。
- `tools/test_skp_device.py --device UDID`：隔离真机测试、缓存重开、旋转、取消、资源保护、SKPBAK，以及 Draco / STL / 3DM 回归。

`python3 tools/build_openskp.py --platform macosx --sanitize` 可构建 ASan / UBSan 库；该构建使用受控堆分配，以便检查精确分配边界。生产构建使用映射工作区。原生测试程序链接 `build/ios/openskp-macosx/libopenskp.a`，并包含生成的受控源码头文件。

独立命令行读取器的编译命令：

```sh
python3 tools/build_openskp.py --platform macosx
xcrun clang++ -O2 -std=c++17 -fobjc-arc \
  -I ios/Online3DViewer -I build/ios/openskp-bounded-src/include \
  -I build/ios/openskp-bounded-src/src -I build/ios/openskp-reader-project/include \
  tools/skp_stream_cli.mm ios/Online3DViewer/SkpStreamReader.mm \
  build/ios/openskp-macosx/libopenskp.a -framework Foundation -o build/ios/skp-stream
```

生成素材和几何核对需要开发电脑的 Python 环境安装 `numpy`、`defusedxml`；这些包不会随 App 运行。`test_skp_stream.py --executable 路径 --results 结果路径` 可对单独编译的 sanitizer 程序运行同一套检查。

本轮真机数据、截图和已知限制见 `build/ios/skp-stream-tests/SKP适配复测.md`。
