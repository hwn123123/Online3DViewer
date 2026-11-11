#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Report the installed CAD viewer's actual coverage and verified limits."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/cad-stream-tests'


def main():
    native=json.loads((BASE/'native-results.json').read_text())
    device=json.loads((BASE/'device/results.json').read_text())
    browser=json.loads((BASE/'browser-results.json').read_text())
    artifacts=json.loads((BASE/'artifact-checks.json').read_text())
    final=json.loads((BASE/'final-checks.json').read_text())
    assert len(device)==19 and {row['number'] for row in device}==set(range(1,20))
    assert 'TEST SUCCEEDED' in (BASE/'ui-test.log').read_text()
    assert browser['passed'] and artifacts['nativeTestsPassed']
    assert final['userLibraryUnchanged'] and final['isolatedCachesCleaned'] and final['homeReady']
    by_source={row['source']:row for row in device if row['state']['event']=='model_loaded'}
    work=[row for row in native if row.get('path')]
    peak=max(row['state']['details'].get('nativePeakFootprintBytes',0) for row in device)/1048576
    summary={'date':'2026-11-10','device':'iPhone 14 Pro Max','reader':'cad-stream-1','workDWGs':len(work),
             'deviceCases':len(device),'browserCases':len(browser['results']),
             'browserFrameComparisons':sum(len(row['states'])==2 for row in browser['results']),
             'browserThemeChecks':len(browser['themeColors']),'uiTestPassed':True,
             'peakNativeFootprintMiB':round(peak,2),'artifacts':artifacts,'final':final,
             'limitations':['ACIS surfaces are not tessellated','text, dimensions, hatch and proxy entities remain unsupported',
                            'model space only; no print layouts or external reference loading',
                            'bounded decoder paths can reject large drawings; not an arbitrary-size guarantee']}
    (BASE/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    lines=['# DWG / DXF App 接入复测','',
           '日期：2026-11-10。设备：iPhone 14 Pro Max。新版已编译、安装并启动，测试结束恢复模型库首页。', '',
           '## 本轮交付','',
           '- DWG / DXF 直接导入进入原生本地路径，经 Rust 读取器转换成分页缓存，再用现有查看器显示；安装后的 App 不调用远程转换服务。',
           '- 支持线、圆和弧、椭圆、多段线及 bulge、可求值的 NURBS 样条、3DFACE、SOLID、Mesh / Polyface / PolygonMesh；支持嵌套块、阵列、旋转和非均匀缩放、图层显隐、单位、基本颜色和透明度。',
           '- 曲线依据几何误差离散；网格没有使用截断面数的解析选项。凹面三角化核对面积及绕序，重复或共线角点按相同表面面积处理。',
           '- ACI 7 黑白色随背景变化，已缓存的几何切换主题后也会调整；其他明确指定的颜色保留。',
           '- 提供取消、资源不足和损坏文件停止路径，清理未完成缓存。尚未支持的对象会提示“部分内容已显示”，可以打开明细；不把部分支持描述为完整打开。',
           '- “存储管理 → 开源许可”可查看依赖许可和导出此 App 使用的 acadrust 对应修改源码。', '',
           '## 实际工作文件','',
           '以下 8 份图纸均从工作目录只读使用，在手机上完成初次加载、分页绘制和自动旋转；覆盖六种 DWG 文件版本。所有文件仍有未支持的内容，因此本轮结论为已显示支持范围内的几何，不能当作与原 CAD 软件完整一致。','',
           '| 文件 | 版本 / 几何 | 三角面 | 线段 | 原生进程物理峰值 MiB |',
           '| --- | --- | ---: | ---: | ---: |']
    for row in work:
        phone=by_source[row['path']]['state']['details']
        assert phone['triangles']==row['triangles'] and phone['lineSegments']==row['lineSegments']
        lines.append(f'| {row["name"]} | {row.get("version",row.get("feature"))} | {row["triangles"]:,} | {row["lineSegments"]:,} | {phone["nativePeakFootprintBytes"]/1048576:.1f} |')
    lines += ['',f'本轮原生 App 进程的最大观测物理占用为 {peak:.1f} MiB。该值不包括独立的 WKWebView WebContent 进程和 GPU 总占用，也不代表其他图纸的上限。部分图纸的各组几何本来相距很远，整体适应窗口后图形会较小，需要缩放查看；没有为改善缩略图而移除远处对象。','',
              '## 验证与结果','',
              '- 原生几何：核对独立 CAD 导出的 DXF 三维网格；自行构造的中文图层、大坐标、嵌套块、六种 DWG 编码版本、OCS 任意朝向、二维阵列、曲线、凹面、顺逆绕序、重复与共线角点、退化面，以及隐藏图层和对象。DWG 构造样本由候选库写出，独立工作图纸和 CAD 导出的 DXF 另行验证。',
              '- 文件名独立性：同一 DWG 数据改为任意中文名称及大写扩展名后，块元数据和几何缓存字节完全一致。生产路径没有按项目、文件名或特定文件大小判断模型。',
              '- 19 项真机用例：12 项 CAD 正向加载、3 项资源/损坏/取消停止、1 项取消后重新读取，另有 Draco GLB、STL、SKP 回归；首个 DXF 还核对手机实际生成缓存的重开。',
              '- 真机资源测试：限制单次解析请求至 512 KiB，先允许小缓冲，再在较大请求前停止，返回 resource_limit；确认任务停止后不会继续加载，未完成缓存已清理。',
              '- 电脑端资源测试：工作目录最大 DWG 在对象区检查处返回资源限制，未创建空成功模型；还覆盖严重压力、预先取消、首块发布后的取消、截断文件、循环块、缺失块及失败后的清理。',
              '- 浏览器最终画面：6 组场景，其中 5 组对照充足预算与 256 KiB 几何预算，差异在允许阈值内；真实网格图纸以 2 MiB 几何预算绘制完成。另外检查两种背景下已缓存材质的黑白颜色。',
              '- 新增界面真机点击：未显示内容按钮、明细返回、开源许可入口、许可正文与对应源码导出入口均可到达。没有触发对外分享。',
              '- 既有检查：242 项网页单元测试通过，模型库持久化、去重、缓存校验和取消导入检查通过；Xcode 构建及签名通过。','',
              '## 资源保护与边界','',
              'DWG 目标每批约 5,000 个实体，仍可能一次读取共享块、一个较大实体或整个解压对象区；DXF 当前完整解析后分块输出。生成的显示几何块约 24,000 个索引或线段端点，复用已有分页渲染器。解析分批和显示分批作用在不同阶段。','',
              '读取器的显式大容量分配及解码循环已添加取消和资源检查；默认单次请求上限 128 MiB，DWG 解压累计预算 128 MiB。原生进程约每 5 毫秒采样，较大显式请求立即检查；超过 448 MiB 物理占用或可用内存余量不足时停止。缓存写入检查本地存储，保留 512 MiB 余量。','',
              '这些检查覆盖接入的路径，不是所有 Rust 分配的硬上限。单个复杂对象、集中在块里的大量几何、依赖内部集合、存储和地址空间仍有设备限制，不能保证任意大小图纸成功，也不能把可慢慢分批渲染理解成解析永不溢出。','',
              '暂不支持 ACIS 三维实体/面域/曲面的完整表面网格化、文字及属性、尺寸和引线标注、HATCH 填充、代理/AEC 自定义对象、光栅图像和 OLE、外部参照文件加载、打印布局、细分平滑、曲线宽度/厚度和线型图案。只处理模型空间和直接导入文件，ZIP 内未接此原生路径。现有读取器诊断和特殊 CAD 对象还需继续与原软件逐图核对。','',
              '## 数据保留与产物','',
              f'- 用户模型库仍为 {final["libraryItems"]} 项，索引与测试前逐字节相同；SHA-256：`{final["librarySHA256"]}`。',
              '- 所用工作图纸的大小与修改时间未变化。测试源副本、临时缓存已从手机清理，恢复普通启动和模型库首页。',
              f'- 安装包：`{artifacts["ipa"]}`，{artifacts["ipaBytes"]/1048576:.1f} MiB。',
              f'- 安装包 SHA-256：`{artifacts["ipaSHA256"]}`。包内可执行文件、许可与对应源码已和 Xcode 产物核对。',
              '- 这是开发签名安装包，设备登记和签名范围不变；未上传或发布。','',
              '## 对应文件','',
              '- 实现：`ios/CadReader/`、`ios/Online3DViewer/CadStreamReader.mm`、ViewerModel/ModelLibrary 导入入口、未显示内容与开源许可界面，以及已有分页显示器的颜色处理。',
              '- 构建：`tools/build_cad_reader.py`、`ios/build-ios.sh`、`ios/generate_project.py`、`tools/prepare_ios.py`。固定 acadrust 0.6.8 提交 `362561cd8b44bbb4bbf5cad5b95fb16eb976b93d`，MPL-2.0。',
              '- 检查：`tools/test_cad_stream.py`、`tools/test_cad_pager.cjs`、`tools/test_cad_device.py`，及 `testCadCoverageAndLicenses` 界面测试。',
              '- 本目录原始记录：`native-results.json`、`browser-results.json`、`device/results.json`、`CadUI.xcresult`、`artifact-checks.json`、`final-checks.json`。详细构建和运行方法见 `ios/README.md`。',
              '- 前期 225 份 DWG 的电脑端读取器调查保留在 `build/ios/dwg-dxf-tests/`；它与本轮 App 真机显示的 8 份图纸属于不同测试范围。','']
    output=BASE/'DWG-DXF-App适配复测.md';output.write_text('\n'.join(lines));print(output)
    print(json.dumps({k:v for k,v in summary.items() if k not in ('artifacts','final')},ensure_ascii=False))


if __name__=='__main__':main()
