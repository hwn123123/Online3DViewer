#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Summarize parser qualification without claiming visual format support."""
import collections
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/dwg-dxf-tests'
MIB = 1024*1024


def category(row, audit):
    error = row['decoder'].get('error')
    if error == 'host-rss-guard':
        return '资源限制'
    if error == 'host-timeout':
        return '超时'
    if error == 'incomplete-record-stream':
        return '对象区未读到'
    if error == 'unverified-source-records':
        return '存在未验证的记录'
    if error or row['exitCode']:
        return '解析报错'
    # The child may finish between two samples; its own getrusage peak is
    # authoritative even when the monitor never had a chance to stop it.
    if row['sampledPeakRSS'] > audit['limits']['rssGuardBytes']:
        return '资源限制'
    if not row.get('sourceUnchanged', False):
        return '源文件状态变化'
    return '通过解析检查'


def counts(row, key='allEntityTypes'):
    value = collections.Counter()
    for shard in row['decoder']['shards']:
        value.update(shard['inventory'][key])
    return value


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def main():
    audits = {name: json.loads((BASE / f'{name}.json').read_text())
              for name in ['all-strict', 'large-sharded', 'dxf-reference']}
    for name, audit in audits.items():
        assert audit['completed'] == audit['total'], f'{name} is incomplete'
    strict, sharded, dxf = (audits[name] for name in ['all-strict', 'large-sharded', 'dxf-reference'])
    full_by_path = {row['path']: row for row in strict['results']}
    shard_by_path = {row['path']: row for row in sharded['results']}
    totals = collections.Counter(category(row, strict) for row in strict['results'])
    combined = sum(category(row, strict) == '通过解析检查' or
                   (row['path'] in shard_by_path and category(shard_by_path[row['path']], sharded) == '通过解析检查')
                   for row in strict['results'])
    comparisons, mismatches = [], []
    for row in sharded['results']:
        original = full_by_path[row['path']]
        has_both = bool(original['decoder']['shards']) and bool(row['decoder']['shards'])
        equal = has_both and counts(row) == counts(original) and counts(row, 'modelEntityTypes') == counts(original, 'modelEntityTypes')
        if has_both and not equal and not row['decoder']['error'] and not original['decoder']['error']:
            mismatches.append(row['path'])
        comparisons.append({'path': row['path'], 'name': Path(row['path']).name,
                            'strictMiB': round(original['sampledPeakRSS']/MIB, 2),
                            'shardedMiB': round(row['sampledPeakRSS']/MIB, 2),
                            'shards': len(row['decoder']['shards']), 'entityCountsEqual': equal if has_both else None,
                            'strictCategory': category(original, strict), 'shardedCategory': category(row, sharded)})
    assert not mismatches, f'Shard entity counts changed: {mismatches}'
    summary = {'strictCategories': totals, 'strictFiles': strict['total'],
               'combinedQualified': combined, 'shardedCategories': collections.Counter(category(row, sharded) for row in sharded['results']),
               'dxfCategories': collections.Counter(category(row, dxf) for row in dxf['results']),
               'unknownEntityFiles': sum(bool(counts(row).get('UNKNOWN')) for row in strict['results']),
               'unresolvedBlockFiles': sum(any(shard['inventory']['missingBlockNames'] for shard in row['decoder']['shards']) for row in strict['results']),
               'sourceStateUnchanged': all(row['sourceUnchanged'] for audit in audits.values() for row in audit['results']),
               'comparisons': comparisons, 'scope': 'desktop parser qualification; no app integration or visual validation'}
    (BASE / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    metadata = json.loads((BASE / 'build-metadata.json').read_text())
    lines = ['# DWG / DXF 本地读取可行性实测', '',
             '日期：2026-11-10。当前阶段是读取器验证，尚未把 DWG / DXF 加入 App，也没有把解析成功当成真机显示成功。', '',
             '## 结论', '',
             f'- 工作目录现有 {strict["total"]} 个 DWG 路径，覆盖六种文件版本；包含项目备份和重复文件。当前没有找到 DXF 工作文件。',
             f'- 完整读取模式：{totals["通过解析检查"]} 份通过本轮解析与资源检查，{strict["total"]-totals["通过解析检查"]} 份未通过。',
             f'- 对 {sharded["total"]} 份较高占用或异常文件复测分批读取；两种读法合并后，{combined} 个路径至少有一种通过检查。',
             '- 本地读取在技术上可继续推进，但当前候选库不能直接作为完整 DWG 查看功能发布。仍需缓存转换、解析内存保护、三维实体网格化以及最终画面验证。', '',
             '## 数据和测试方法', '',
             f'候选为 acadrust 0.6.8，固定提交 `{metadata["acadrustRevision"]}`，MPL-2.0；未修改依赖源码。Rust 构建、3 项针对性测试及 arm64 iOS 的 cargo check 已通过。cargo check 不包含 iOS 链接、安装和真机运行。', '',
             'DWG 关闭并行解码，禁用保存用的重复原始数据，延迟 ACIS 参考点计算，不限制网格面数；不通过截断面或删对象降低占用。解压预算为 256 MiB，分批目标为 5,000 个实体。', '',
             '电脑端每个文件在独立子进程读取，30 秒超时，768 MiB RSS 检查线，每 0.1 秒采样。完成后读取 getrusage 峰值，补判采样间隔内已经结束但超限的任务。被终止任务的内存数值只是观测到的下限；采样保护可能越过检查线。此保护用于电脑验证，不能替代 iOS 解析器内部的分配前检查。', '',
             '以下内存均来自 Mac，不能用来断言 iPhone 的实际峰值。对象类型数量相同只说明这项检查一致，不能替代逐坐标、块变换和最终画面的核对。', '',
             f'所有测试前后源文件的大小和修改时间均未变化：{summary["sourceStateUnchanged"]}。测试程序只读打开原图，不向工作目录保存转换文件。', '',
             '## DWG 文件版本', '', '| 文件头 | 文件数 |', '| --- | ---: |']
    for version, count in sorted(strict['versionCounts'].items()):
        lines.append(f'| {version} | {count} |')
    lines += ['', '## 完整读取结果', '', '| 分类 | 文件数 |', '| --- | ---: |']
    for name, count in totals.items():
        lines.append(f'| {name} | {count} |')
    lines += ['', '“存在未验证的记录”包括关联阵列等辅助对象解码失败后保留原始记录的情况，不能据此断言可见几何全部缺失，也不能直接认为显示完整。', '',
              '“对象区未读到”包含解压预算不足以及对象区超过库当前大小限制的情况。当前库可能返回 Ok 和 stream_completed=true，但 record_stream_read=false；验证工具会拒绝该结果。不能通过去掉资源限制来把它算成成功。', '',
              '## 分批读取对照', '', '| 文件 | 完整模式 MiB | 分批模式 MiB | 批数 | 实体计数一致 | 分批结果 |', '| --- | ---: | ---: | ---: | --- | --- |']
    seen, examples = set(), []
    for row in sorted(comparisons, key=lambda item: item['strictMiB']-item['shardedMiB'], reverse=True):
        if row['name'] not in seen and row['shardedCategory'] == '通过解析检查':
            seen.add(row['name']);examples.append(row)
    for row in examples[:8]:
        lines.append(f'| {cell(row["name"])} | {row["strictMiB"]:.1f} | {row["shardedMiB"]:.1f} | {row["shards"]} | {row["entityCountsEqual"]} | {row["shardedCategory"]} |')
    lines += ['', '部分图纸改善明显，部分图纸仍在 500–700 MiB 以上，另有文件触发监控终止。第一批仍包含块定义等共享数据，底层仍会合并整个解压对象区，因此 5,000 个实体的目标不代表固定内存上限。', '',
              '## 几何覆盖观察', '']
    for kind in ['3DFACE', 'MESH', 'REGION', '3DSOLID', 'UNKNOWN', 'EXTENDED_ENTITY']:
        number = sum(bool(counts(row).get(kind)) for row in strict['results'])
        lines.append(f'- {kind}：在 {number} 个已返回实体清单的文件中出现。报错或被终止而没有清单的文件不计入该数。')
    lines += ['', '3DSOLID / REGION / BODY / SURFACE 的 ACIS SAT/SAB 数据可被读取，不等于已生成可显示的三角面。本轮没有实现通用 ACIS 网格化；已有线框不能代替完整实体表面。UNKNOWN 与 AEC / 自定义对象还需要代理图形或专门的几何支持。', '',
              f'本轮有 {summary["unresolvedBlockFiles"]} 份返回清单的文件含未解析到块定义的引用，需要单独追踪，不能在转换时忽略该引用。读取过程没有错误与最终场景完整属于不同的检查项。', '',
              '## DXF 验证', '',
              f'使用固定依赖仓库里的 {dxf["total"]} 份 DXF 参考文件，均完成解析检查；其中包含 CAD 导出的 R12 三维多段线、2×3 多边形网格和四边形多面网格。另单独核对了具体三维坐标、面索引、大坐标和中文图层名。二进制 DXF 用候选库生成的数据做读回核对，不把它当成独立 CAD 导出参考。', '',
              '这些结果没有覆盖用户自己的 DXF，也没有完成 App 显示、字体、尺寸标注、填充或打印布局验证。', '',
              '## 接入顺序和验收条件', '',
              '1. 先打通 DWG / DXF 共用的几何转换层，覆盖线、弧、圆、椭圆、多段线、样条、面和网格；保留单位、OCS 坐标、图层、颜色及嵌套块变换，输出已有的分页缓存。',
              '2. 在读取器内部补齐取消与分配前资源检查，处理超大解压对象区和集中在块定义里的几何；保留完整性检查，失败时清理缓存并明确提示。',
              '3. 对 ACIS 实体、代理对象、文字和标注分别建立真实文件与参考画面的验证，未通过的能力明确标记，不把部分图形当成完整模型。',
              '4. 完成上述可支持范围后再启用 App 导入入口，真机验证旋转、图层、缓存重开、取消、连续切换及内存压力。', '',
              '## 未通过的工作文件', '', '| 路径 | 分类 | 观测峰值 MiB | 错误 / 首条诊断 |', '| --- | --- | ---: | --- |']
    for row in strict['results']:
        state = category(row, strict)
        if state == '通过解析检查':
            continue
        diagnostic = row['decoder']['error'] or '解析完成，但 getrusage 峰值超过本轮资源线'
        if row['decoder']['shards']:
            messages = row['decoder']['shards'][0]['stats']['diagnostics']
            if messages:
                diagnostic += ': ' + messages[0]['message'][:240]
        lines.append(f'| {cell(row["relative"])} | {state} | {row["sampledPeakRSS"]/MIB:.1f} | {cell(diagnostic)} |')
    lines += ['', '## 复现和原始记录', '',
              '- 构建与检查：`python3 tools/build_cad_probe.py --test --check-ios`。',
              '- 工作文件全量读取：`python3 tools/audit_cad_models.py`。',
              '- 分批对照：`python3 tools/audit_cad_models.py --inventory build/ios/dwg-dxf-tests/large-inventory.json --mode sharded --output build/ios/dwg-dxf-tests/large-sharded.json`。',
              '- 本报告：`python3 tools/report_cad_audit.py`。原始结果为同目录的 `all-strict.json`、`large-sharded.json`、`dxf-reference.json`、`summary.json`；每个任务另有输出与错误日志。', '',
              '## 源码依据', '',
              '- [acadrust 固定版本源码和许可证](https://github.com/hakanaktt/acadrust/tree/362561cd8b44bbb4bbf5cad5b95fb16eb976b93d)。',
              '- [DWG 读取选项与分批实现](https://github.com/hakanaktt/acadrust/blob/362561cd8b44bbb4bbf5cad5b95fb16eb976b93d/src/io/dwg/dwg_reader.rs)。',
              '- [ACIS 实体数据结构](https://github.com/hakanaktt/acadrust/blob/362561cd8b44bbb4bbf5cad5b95fb16eb976b93d/src/entities/solid3d.rs)。',
              '- [CAD 导出参考文件说明](https://github.com/hakanaktt/acadrust/blob/362561cd8b44bbb4bbf5cad5b95fb16eb976b93d/tests/fixtures/r12/cad-created/README.md)。', '']
    target = BASE / 'DWG-DXF本地读取验证.md'
    target.write_text('\n'.join(lines))
    print(json.dumps({key: value for key, value in summary.items() if key != 'comparisons'}, ensure_ascii=False))
    print(target)


if __name__ == '__main__':
    main()
