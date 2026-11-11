#!/usr/bin/env python3
"""Build a local, searchable compatibility report from device observations."""
from collections import Counter, defaultdict
from pathlib import Path
import html
import json

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/ios/work-model-tests'
LABELS = {
    'loaded': '已加载并显示',
    'loaded_missing_files': '能显示，缺配套文件',
    'partial_geometry': '部分对象未显示',
    'no_visible_geometry': '未发现可见几何',
    'unsupported_no_importer': '尚未接入导入器',
    'no_importable_file': '未找到可导入模型',
    'failed_to_load_file': '读取失败',
    'import_failed': '解析失败',
    'javascript_error': '显示错误',
    'native_read_error': '原生读取失败',
    'webcontent_terminated': '查看进程退出',
    'timeout': '150 秒内未完成',
    'not_tested': '待测试',
}


def main():
    inventory = json.loads((OUT / 'inventory.json').read_text())
    results = json.loads((OUT / 'device-results.json').read_text())
    capabilities = json.loads((OUT / 'importer-capabilities.json').read_text())
    by_path = {r['path']: r for r in results}
    rows = []
    for original in inventory:
        if original.get('category') not in {'model', 'backup', 'drawing'}:
            continue
        result = by_path.get(original['path'])
        status = result['status'] if result else ('unsupported_no_importer' if not capabilities.get(original['format']) else 'not_tested')
        if result and result['test_kind'] == 'unsupported_probe':
            status = 'unsupported_no_importer'
        detail = result.get('state', {}).get('details', {}) if result else {}
        notes = []
        if original['category'] == 'backup':
            notes.append('备份扩展名不直接支持；仅在临时副本改为原格式后测试' if result else '备份扩展名尚未识别')
        if status == 'unsupported_no_importer':
            notes.append('依据当前导入器能力核对；未复制大文件到手机逐份解析')
        if result and result['test_kind'] == 'unsupported_probe':
            notes.append('已在真机验证不支持提示')
        if detail.get('unsupportedCount'):
            notes.append(str(detail['unsupportedCount']) + ' 个对象未显示')
        if detail.get('missingFiles'):
            notes.append('缺少：' + '、'.join(detail['missingFiles']))
        if status == 'timeout':
            notes.append('最后状态：' + str(result.get('state', {}).get('event', '无结果')))
            if detail.get('displayed') is not None:
                notes.append('已显示 ' + str(detail['displayed']) + ' / ' + str(detail.get('total', '?')) + ' 个对象')
        if status in {'javascript_error', 'native_read_error'}:
            notes.append(str(result.get('state', {}).get('name', '')))
        rows.append({**original, 'status': status, 'status_label': LABELS.get(status, status), 'notes': '；'.join(notes),
                     'seconds': result.get('seconds') if result else None,
                     'objects': detail.get('objectCount', detail.get('total')), 'displayed': detail.get('displayed'),
                     'triangles': detail.get('triangles'),
                     'screenshot': str(Path(result['screenshot']).relative_to('build/ios/work-model-tests')) if result and result.get('screenshot') else None,
                     'device_tested': bool(result), 'raw_details': detail})
    models = [r for r in rows if r['category'] == 'model']
    formats = defaultdict(list)
    for row in models:
        formats[row['format']].append(row)
    summary = []
    for ext, group in sorted(formats.items()):
        counts = Counter(r['status_label'] for r in group)
        summary.append({'format': ext.upper(), 'files': len(group), 'results': '；'.join(f'{label} {n}' for label, n in counts.items())})
    report = {'root': str(Path.home() / '工作'), 'models': len(models), 'device_cases_completed': len(results),
              'device_cases_planned': len(json.loads((OUT / 'cases.json').read_text())),
              'summary': summary, 'rows': rows}
    (OUT / 'compatibility-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    lines = [
        '# 工作目录模型兼容性测试（2026-11-07）', '',
        '扫描目录：当前用户的工作目录。原文件只读；真机使用隔离副本，不加入用户模型库，测试后清理临时副本。',
        '', f'发现 {len(models)} 个模型文件；真机完成 {len(results)} / {report["device_cases_planned"]} 个用例（含备份别名测试与不支持格式对照）。',
        '', '| 格式 | 原始模型数量 | 本轮结果 |', '|---|---:|---|',
    ]
    for entry in summary:
        lines.append(f'| {entry["format"]} | {entry["files"]} | {entry["results"]} |')
    lines += ['', '“已加载并显示”表示本轮真机可以看到几何；完整材质、文字标注与原软件的显示效果仍需对照。部分显示、缺文件、超时与进程退出分别记录，不计作完整支持。',
              '', 'MAX、SKP、DWG 的导入器尚未接入。选取每种格式一个真实文件做真机不支持对照；其余同格式逐文件登记，不把未实际加载的文件标为真机已测。',
              '', '## 模型逐文件结果', '', '| 文件 | 格式 | 大小 MiB | 结果 | 读取至结果秒数 | 说明 |', '|---|---|---:|---|---:|---|']
    for row in sorted(models, key=lambda r: (r['format'], r['relative'])):
        name = row['relative'].replace('|', '\\|')
        link = f'[{name}]({row["screenshot"]})' if row['screenshot'] else name
        lines.append(f'| {link} | {row["format"].upper()} | {row["bytes"] / 1048576:.2f} | {row["status_label"]} | {row["seconds"] or "—"} | {row["notes"].replace("|", "/")} |')
    lines += ['', '## 3DM 原文件独立核对', '', '| 文件 | 对象数 | 原文件缺少显示网格的曲面面数 | 缺显示网格的 Extrusion 数量 |', '|---|---:|---:|---:|']
    source = json.loads((OUT / 'source-3dm-analysis.json').read_text())
    for item in source:
        if 'objects' in item:
            lines.append(f'| {item["file"]} | {item["objects"]} | {item["missing_mesh_faces"]} | {item["missing_extrusion_meshes"]} |')
    lines += ['', '3DM 中的块实例、文字、尺寸标注、填充和未保存显示网格的曲面，目前可能缺失；具体源对象类型见 source-3dm-analysis.json。',
              '', '## 其他文件', '',
              f'- DWG：{sum(r["category"] == "drawing" for r in rows)} 个，当前没有 DWG 导入器；没有把它们默认当成可查看的 3D 模型。',
              f'- 备份：{sum(r["category"] == "backup" for r in rows)} 个，部分用临时别名验证原格式解析，原文件未改名。',
              '- 检查了 27 个 ZIP/RAR。包内另有 7 个 MAX/SKP 模型条目，均属于当前未接入的格式；没有额外的已适配格式工作样本。未将压缩包格式本身当作内部模型格式支持。',
              '- 37 个 .gz 为 SQLite 数据库压缩文件，不作为三维模型测试。',
              '', '## 本轮修正', '',
              '- 修正多对象 3DM 的中间 JSON 未及时释放及发布过密问题。相同 10,620 对象样本的桌面原生读取驻留峰值从 2,195.03 MiB 降到 38.83 MiB；该数字不代表 iPhone 总内存。',
              '- 修正前后全部对象记录相同，全部几何块 SHA-256 一致；没有通过删除对象或减少网格来降低这部分内存。',
              '- 多对象模型增加每批对象数，同时限制每批几何字节；避免反复排序和重复调整视角。',
              '', '## 原始证据', '',
              '- device-results.json：逐用例事件、数量、耗时、文件未变化核对。',
              '- inventory.json / unsupported.json：原始目录文件清单及未接入格式。',
              '- archives.json：压缩包目录核对。',
              '- source-3dm-analysis.json / source-obj-analysis.json：独立源几何核对。',
              '- screenshots/：真机截图；contact-*.png 为查看用联系表。',
              '- native-memory-fix-check.json：中间数据内存修正的独立核对。',
              '']
    (OUT / '兼容性测试报告.md').write_text('\n'.join(lines))
    embedded = json.dumps(rows, ensure_ascii=False).replace('<', '\\u003c')
    page = """<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>工作目录模型兼容性</title><style>
body{font:15px system-ui;margin:24px;background:#f5f6f8;color:#20242b}h1{font-size:25px}p{max-width:1000px;line-height:1.7}
.controls{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}input,select{font:inherit;padding:9px;border:1px solid #ccd0d8;border-radius:8px}input{min-width:280px}
table{border-collapse:collapse;width:100%;background:white}th,td{padding:12px;text-align:left;border-bottom:1px solid #ddd;vertical-align:top}th{background:#edf0f5;position:sticky;top:0}.path{max-width:440px;overflow-wrap:anywhere}.muted{color:#667085;font-size:13px}.good{color:#167347}.bad{color:#b42318}.warn{color:#986500}a{color:#175cd3}td:nth-child(3),td:nth-child(5){white-space:nowrap}
</style><h1>工作目录模型兼容性测试</h1><p>目录：工作目录 · 2026-11-07 · iPhone 14 Pro Max 真机。通过扩展名检查的文件与实际真机加载结果分开标记。点击“截图”查看实际显示。</p>
<div class="controls"><input id="q" placeholder="搜索文件名或目录"><select id="category"><option value="model">模型文件</option><option value="backup">备份文件</option><option value="drawing">DWG 图纸</option><option value="">全部</option></select><select id="format"><option value="">全部格式</option></select><select id="status"><option value="">全部结果</option></select></div>
<p id="count"></p><table><thead><tr><th>文件</th><th>格式</th><th>大小 MiB</th><th>结果 / 说明</th><th>秒</th><th>证据</th></tr></thead><tbody id="body"></tbody></table>
<script>const rows=DATA;
const $=id=>document.getElementById(id);const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
for(const [id,values] of [['format',[...new Set(rows.map(r=>r.format))].sort()],['status',[...new Set(rows.map(r=>r.status_label))]]])for(const value of values){const o=document.createElement('option');o.value=value;o.textContent=value;$(id).append(o)}
function render(){const selected=rows.filter(r=>(!$('category').value||r.category===$('category').value)&&(!$('format').value||r.format===$('format').value)&&(!$('status').value||r.status_label===$('status').value)&&(!r.relative||r.relative.toLowerCase().includes($('q').value.toLowerCase())));$('count').textContent='显示 '+selected.length+' 个文件';$('body').innerHTML=selected.map(r=>'<tr><td class="path">'+escape(r.relative)+'</td><td>'+escape(r.format.toUpperCase())+'</td><td>'+(r.bytes/1048576).toFixed(2)+'</td><td><strong class="'+(r.status==='loaded'?'good':r.status==='partial_geometry'||r.status==='loaded_missing_files'?'warn':'bad')+'">'+escape(r.status_label)+'</strong><div class="muted">'+escape(r.notes)+'</div><div class="muted">'+(r.objects!=null?'对象 '+r.objects+' · ':'')+(r.triangles!=null?'三角形 '+r.triangles:'')+'</div></td><td>'+escape(r.seconds??'—')+'</td><td>'+(r.screenshot?'<a href="'+encodeURI(r.screenshot)+'" target="_blank">截图</a>':r.device_tested?'真机':'能力核对')+'</td></tr>').join('')}
for(const id of ['q','category','format','status'])$(id).addEventListener('input',render);render();</script></html>""".replace('DATA', embedded)
    (OUT / 'report.html').write_text(page)
    print(json.dumps({'models': len(models), 'cases_completed': len(results), 'summary': summary}, ensure_ascii=False))


if __name__ == '__main__':
    main()
