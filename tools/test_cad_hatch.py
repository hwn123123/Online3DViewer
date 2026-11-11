#!/usr/bin/env python3
"""Compare CAD HATCH geometry to independent ezdxf fixtures and work files."""
import json
import os
from pathlib import Path
import subprocess
import numpy as np
import ezdxf
from ezdxf.render.hatching import hatch_entity
from ezdxf.math import Vec2
import test_cad_stream as cad

ROOT = cad.ROOT
BASE = ROOT/'build/ios/hatch-tests'
SOURCES = BASE/'sources'
CLI = ROOT/'build/ios/cad-text-stream'


def save(name, style=0, pattern=False, normal=None, dense=False, curved=False):
    doc=ezdxf.new('R2010');doc.header['$INSUNITS']=0
    hatch=doc.modelspace().add_hatch()
    if pattern:
        hatch.set_pattern_fill('CUSTOM', angle=25, scale=2, style=style, pattern_type=2,
                               definition=[[15,(0.2,0.3),(1.2,2.3),[1.5,-0.8]]])
        if dense:
            hatch.pattern.lines[0].offset=Vec2(0,1e-12)
            doc.modelspace().add_line((0,0),(1,0))
    else:hatch.set_solid_fill(style=style)
    if normal:hatch.dxf.extrusion=normal;hatch.dxf.elevation=(0,0,3)
    if curved:
        path=hatch.paths.add_edge_path(flags=1);path.add_arc(center=(0,0),radius=5,start_angle=0,end_angle=360)
    else:
        hatch.paths.add_polyline_path([(0,0),(10,0),(10,10),(0,10)],flags=1)
        hatch.paths.add_polyline_path([(2,2),(8,2),(8,8),(2,8)],flags=16)
        hatch.paths.add_polyline_path([(4,4),(6,4),(6,6),(4,6)],flags=0)
    path=SOURCES/(name+'.dxf');doc.saveas(path);return path


def run(source,name,env=None,expected=0,geometry=True):
    cache=BASE/'caches'/name
    result=subprocess.run([str(CLI),str(source),str(cache)],capture_output=True,text=True,
                          env={**os.environ,**(env or {})},timeout=240)
    assert result.returncode==expected,(str(source),result.stdout[-500:],result.stderr[-1500:])
    if expected:assert not cache.exists();return None
    m=json.loads((cache/'manifest.json').read_text());assert m['complete'] and m['reader']=='cad-stream-4'
    return m, cad.geometry(cache,m) if geometry else None


def area(tris):
    return np.linalg.norm(np.cross(tris[:,1]-tris[:,0],tris[:,2]-tris[:,0]),axis=1).sum()/2


def canonical(lines):
    out=[]
    for line in lines:
        endpoints=sorted(tuple(round(float(x),4) for x in p[:2]) for p in line)
        if np.linalg.norm(np.array(endpoints[0])-endpoints[1])>1e-5:out.append(tuple(endpoints))
    return sorted(out)


def main():
    SOURCES.mkdir(parents=True,exist_ok=True)
    for style,expected in [(0,68),(1,64),(2,100)]:
        source=save('solid-'+str(style),style);m,(_,tris)=run(source,source.stem)
        assert abs(area(tris)-expected)<1e-5,(style,area(tris),m['unsupported'])
        assert not m['unsupported'],m['unsupported']
    source=save('circular',curved=True);m,(_,tris)=run(source,'circular')
    assert abs(area(tris)-np.pi*25)<0.02 and not m['unsupported'],m['unsupported']
    doc=ezdxf.new('R2010');doc.header['$INSUNITS']=0
    hatch=doc.modelspace().add_hatch();hatch.set_solid_fill(style=0)
    edge=hatch.paths.add_edge_path(flags=1)
    edge.add_ellipse(center=(0,0),major_axis=(4,0),ratio=.5,start_angle=0,end_angle=180)
    edge.add_line((-4,0),(4,0));source=SOURCES/'ellipse.dxf';doc.saveas(source)
    m,(_,tris)=run(source,'ellipse')
    assert abs(area(tris)-4*np.pi)<0.01 and not m['unsupported'],m['unsupported']
    source=save('plane',normal=(0,1,0));m,(_,tris)=run(source,'plane')
    assert abs(area(tris)-68)<1e-4 and np.max(np.abs(tris[:,:,1]-3))<1e-6
    doc=ezdxf.new('R2010');doc.header['$INSUNITS']=0
    hatch=doc.modelspace().add_hatch();hatch.set_solid_fill(style=0)
    edge=hatch.paths.add_edge_path(flags=1)
    edge.add_spline(control_points=[(0,0),(5,10),(10,0)],knot_values=[0,0,0,1,1,1],degree=2)
    edge.add_line((10,0),(0,0))
    source=SOURCES/'spline.dxf';doc.saveas(source);m,(_,tris)=run(source,'spline')
    assert abs(area(tris)-100/3)<0.005 and not m['unsupported'],m['unsupported']
    doc=ezdxf.new('R2010');doc.header['$INSUNITS']=0
    block=doc.blocks.new('FILL');hatch=block.add_hatch();hatch.set_solid_fill(style=0)
    hatch.paths.add_polyline_path([(0,0),(10,0),(10,10),(0,10)],flags=1)
    hatch.paths.add_polyline_path([(2,2),(8,2),(8,8),(2,8)],flags=16)
    hatch.paths.add_polyline_path([(4,4),(6,4),(6,6),(4,6)],flags=0)
    doc.modelspace().add_blockref('FILL',(20,30,4),dxfattribs={'xscale':2,'yscale':3,'rotation':90})
    source=SOURCES/'block.dxf';doc.saveas(source);m,(_,tris)=run(source,'block')
    assert abs(area(tris)-408)<1e-3 and np.max(np.abs(tris[:,:,2]-4))<1e-6 and not m['unsupported'],m['unsupported']
    for style in (0,1,2):
        source=save('pattern-'+str(style),style,pattern=True)
        m,(lines,_)=run(source,source.stem);h=ezdxf.readfile(source).modelspace().query('HATCH')[0]
        reference=np.array([[list(a),list(b)] for a,b in hatch_entity(h,jiggle_origin=False)])
        actual=canonical(lines);expected=canonical(reference)
        assert actual==expected,(style,len(actual),len(expected),actual[:8],expected[:8],m['unsupported'])
    source=save('dense',pattern=True,dense=True);m,_=run(source,'dense')
    assert m['unsupported'] and not m['coverageComplete'],m
    doc=ezdxf.readfile(SOURCES/'pattern-0.dxf')
    doc.modelspace().query('HATCH')[0].pattern.lines[0].dash_length_items=[1.,-1.,0.]
    doc.modelspace().add_line((0,0),(1,0));source=SOURCES/'dotted.dxf';doc.saveas(source)
    m,_=run(source,'dotted')
    assert any(item['type']=='含点的填充图案' for item in m['unsupported']),m
    run(source,'cancel',{'O3DV_TEST_CANCEL':'1'},expected=1)
    for version in ['AC1015','AC1018','AC1021','AC1024','AC1027','AC1032']:
        source=SOURCES/(version+'.dwg')
        subprocess.run([str(cad.RUST/'cad-fixtures'),str(SOURCES/'solid-0.dxf'),str(source),version],check=True)
        m,(_,tris)=run(source,version);assert abs(area(tris)-68)<1e-4 and not m['unsupported'],(version,m['unsupported'])
    work=json.loads((ROOT/'build/ios/cad-leader-tests/results.json').read_text());results=[]
    for row in work:
        source=Path(row['path']);before=source.stat();m,_=run(source,row['cache'],geometry=False);after=source.stat()
        assert (before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
        results.append({'path':str(source),'cache':row['cache'],'triangles':m['triangles'],'lineSegments':m['lineSegments'],
                        'unsupported':m['unsupported'],'warnings':m['warnings']})
        print('PASS work',source.name,'triangles',m['triangles'],'lines',m['lineSegments'],'unsupported',m['unsupported'],flush=True)
    (BASE/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print('PASS solid holes and island rules, curved boundary, OCS, pattern comparison, six DWG versions, cancellation')

if __name__=='__main__':main()
