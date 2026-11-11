# DWG / DXF 本地读取验证工具

这是电脑端的只读格式验证工具。它没有接入 iOS App，不会改变 App 的可导入扩展名。目标是先确认真实图纸的版本、对象、图层、块引用、解析完整性和资源开销，再实现显示缓存转换。

依赖固定为 [acadrust 0.6.8，提交 362561c](https://github.com/hakanaktt/acadrust/tree/362561cd8b44bbb4bbf5cad5b95fb16eb976b93d)，采用 MPL-2.0，源码、许可证及第三方声明保留在下载目录。当前未修改或向 App 分发该库。Cargo.lock 固定传递依赖；验证使用 Rust 1.99.1。

## 构建

需要 macOS、Rust 1.99.1。脚本优先使用项目内 `build/ios/rust-tools/` 中已有的 rustup，否则使用 PATH 中的工具链。首次构建需联网获取源码和 Cargo 依赖，读取图纸时不联网。

```sh
python3 tools/build_cad_probe.py --test
```

检查 iOS 代码兼容性时先安装目标，再运行：

```sh
rustup target add aarch64-apple-ios
python3 tools/build_cad_probe.py --test --check-ios
```

若使用项目内的 Rust，先将 `build/ios/rust-tools/cargo/bin` 加入 PATH，并分别设置 CARGO_HOME、RUSTUP_HOME 为 `build/ios/rust-tools/cargo` 和 `build/ios/rust-tools/rustup` 的绝对路径。iOS 检查仅执行 cargo check，不包含链接、签名、安装或真机运行。

## 运行

```sh
build/ios/cad-probe-target/release/o3dv-cad-probe /绝对路径/图纸.dwg strict
build/ios/cad-probe-target/release/o3dv-cad-probe /绝对路径/图纸.dwg sharded
build/ios/cad-probe-target/release/o3dv-cad-probe /绝对路径/图纸.dxf strict
```

默认解压预算为 256 MiB，环境变量 `O3DV_CAD_DECOMPRESS_LIMIT` 可改为以字节计的值。这个预算只覆盖 DWG 的部分解压分配，不覆盖全部拓扑和对象内存。分批读取的目标为 5,000 个实体，块定义和部分内部数据仍会集中读取。DXF 当前由候选库完整读取，不具有分批内存保证。

输出一行 JSON；退出码 0 表示读取统计没有检测到缺失或恢复错误，仍需检查 UNKNOWN、代理对象、块引用及后续几何转换。退出码 1 表示解析失败或结果未经完整验证，2 表示缺少参数。`failsafe` 仅用于调查错误恢复，不把保留原始数据的未解码对象当成已显示的几何。

第三方读取器可能在对象区提取失败时返回 Ok；本工具额外检查 record_stream_read、stream_completed、recovered_errors 和 skipped_source_records，避免返回一个空模型却报告成功。ACIS 原始数据和线框都不代表实体表面已经完成网格化。

## 批量验证

`tools/audit_cad_models.py` 读取模型清单 JSON。每项至少有 path、format（dwg / dxf）、bytes；工作目录已有的清单位于 `build/ios/work-model-tests/inventory.json`。

```sh
python3 tools/audit_cad_models.py --representative
python3 tools/audit_cad_models.py
```

每个文件在独立电脑子进程里检查，超时和 RSS 监控仅用于验证。短任务可能在两次采样间结束，因此同时检查任务自身 getrusage 峰值；超限任务不能因为退出码为 0 就通过资源检查。源文件只读，额外记录测试前后大小与修改时间是否一致。

基于上次全量结果，选择超过 200 MiB 或存在异常的文件写入 `large-inventory.json`，再用 `--mode sharded` 进行对照。DXF 参考清单来自固定依赖的 `tests/**/*.dxf`。完整原始记录保存在 `build/ios/dwg-dxf-tests/`，`tools/report_cad_audit.py` 生成说明和汇总。结果只表示 Mac 上的解析验证，不表示 App 已能显示文件。
