import * as THREE from 'three';
import { IntersectionMode } from '../engine/viewer/viewermodel.js';

// Work in world coordinates after the model/instance transform. Only claim a
// vertex snap when the selected vertex is actually close in screen space.
export function MeasurementPoint (hit, camera, size, coordinates)
{
    const point = hit.point.clone ();
    const object = hit.object;
    const positions = object.geometry?.getAttribute ('position');
    const candidates = [];
    if (positions && hit.face) {
        candidates.push (hit.face.a, hit.face.b, hit.face.c);
    } else if (positions && object.isLineSegments && Number.isInteger (hit.index)) {
        candidates.push (hit.index, hit.index + 1);
    } else if (positions && object.isPoints && Number.isInteger (hit.index)) {
        candidates.push (hit.index);
    }
    let nearest = null, best = 18;
    for (const index of candidates) {
        if (index < 0 || index >= positions.count) continue;
        const world = new THREE.Vector3 ().fromBufferAttribute (positions, index).applyMatrix4 (object.matrixWorld);
        const projected = world.clone ().project (camera);
        const x = (projected.x + 1) * size.width / 2;
        const y = (1 - projected.y) * size.height / 2;
        const distance = Math.hypot (x - coordinates.x, y - coordinates.y);
        if (projected.z >= -1 && projected.z <= 1 && distance < best) {
            best = distance;
            nearest = world;
        }
    }
    return { point : nearest || point, snapped : !!nearest };
}

export class MobileMeasure
{
    constructor (website)
    {
        this.website = website;
        this.viewer = website.viewer;
        this.active = false;
        this.points = [];
        this.revision = 0;
        this.root = document.createElement ('div');
        this.root.className = 'o3dv-mobile-measure';
        this.root.hidden = true;
        this.root.innerHTML = '<button type="button" class="o3dv-measure-toggle">测量</button>' +
            '<div class="o3dv-measure-controls" hidden><label>模型单位 <select aria-label="模型单位">' +
            '<option value="">请选择单位</option><option value="mm">毫米 (mm)</option><option value="cm">厘米 (cm)</option>' +
            '<option value="m">米 (m)</option><option value="in">英寸 (in)</option><option value="ft">英尺 (ft)</option></select></label>' +
            '<small>选择文件中坐标使用的单位，不改变模型比例。</small>' +
            '<span class="o3dv-measure-result" aria-live="polite"></span><div><button type="button" class="o3dv-measure-undo">撤销选点</button> ' +
            '<button type="button" class="o3dv-measure-clear">重新测量</button> ' +
            '<button type="button" class="o3dv-measure-close">完成</button></div></div>';
        document.body.appendChild (this.root);
        this.controls = this.root.querySelector ('.o3dv-measure-controls');
        this.unit = this.root.querySelector ('select');
        this.result = this.root.querySelector ('.o3dv-measure-result');
        this.root.querySelector ('.o3dv-measure-toggle').onclick = () => this.SetActive (!this.active);
        this.root.querySelector ('.o3dv-measure-clear').onclick = () => this.Clear ();
        this.root.querySelector ('.o3dv-measure-undo').onclick = () => this.Undo ();
        this.root.querySelector ('.o3dv-measure-close').onclick = () => this.SetActive (false);
        this.unit.onchange = () => this.Update ();
        this.Update ();
    }

    Show (unit = '')
    {
        this.SetActive (false);
        if (unit === 'metres' || unit === 'meters') unit = 'm';
        this.unit.value = ['mm', 'cm', 'm', 'in', 'ft'].includes (unit) ? unit : '';
        this.root.hidden = false;
        this.Update ();
    }

    Hide ()
    {
        this.SetActive (false);
        this.root.hidden = true;
    }

    SetActive (active)
    {
        if (this.active === active) return;
        this.active = active;
        this.controls.hidden = !active;
        this.root.querySelector ('.o3dv-measure-toggle').hidden = active;
        if (!active) this.Clear ();
        this.Update ();
    }

    Clear ()
    {
        this.revision += 1;
        this.points = [];
        this.viewer.ClearExtra ();
        this.Update ();
    }

    Undo ()
    {
        this.revision += 1;
        this.points.pop ();
        this.DrawMarkers ();
        this.Update ();
    }

    Click (coordinates)
    {
        const revision = ++this.revision;
        const accept = (selected, failed = false) => {
            if (revision !== this.revision || !this.active) return;
            if (failed) this.result.textContent = '选点读取失败，请重试或释放设备资源。';
            else this.Accept (selected);
        };
        if (this.website.nativeStream?.active) {
            this.result.textContent = '正在查找选点，请稍候…';
            this.website.nativeStream.pager.Select (coordinates, accept);
        } else {
            const hit = this.viewer.GetMeshIntersectionUnderMouse (IntersectionMode.MeshAndLine, coordinates);
            if (hit) hit.object.updateWorldMatrix (true, false);
            accept (hit ? MeasurementPoint (hit, this.viewer.camera, this.viewer.GetCanvasSize (), coordinates) : null);
        }
    }

    Accept (selected)
    {
        if (!this.active) return;
        if (!selected) {
            this.result.textContent = '没有选中模型，请放大后重试。';
            return;
        }
        if (this.points.length === 2) this.Clear ();
        this.points.push (selected);
        this.DrawMarkers ();
        this.Update ();
    }

    DrawMarkers ()
    {
        this.viewer.ClearExtra ();
        const size = this.viewer.GetCanvasSize ();
        const camera = this.viewer.camera;
        for (const selected of this.points) {
            const distance = camera.position.distanceTo (selected.point);
            const radius = camera.isPerspectiveCamera ? distance * Math.tan (camera.fov * Math.PI / 360) * 12 / size.height : (camera.top - camera.bottom) * 6 / size.height;
            const marker = new THREE.Mesh (new THREE.SphereGeometry (Math.max (radius, 1e-8), 12, 8), new THREE.MeshBasicMaterial ({ color : 0xff4b24, depthTest : false }));
            marker.position.copy (selected.point);
            this.viewer.AddExtraObject (marker);
        }
        if (this.points.length === 2) {
            const geometry = new THREE.BufferGeometry ().setFromPoints (this.points.map ((p) => p.point));
            this.viewer.AddExtraObject (new THREE.Line (geometry, new THREE.LineBasicMaterial ({ color : 0xff4b24, depthTest : false })));
        }
    }

    Update ()
    {
        if (!this.result) return;
        if (!this.points.length) this.result.textContent = '选择第一个点；靠近顶点时自动吸附。';
        else if (this.points.length === 1) this.result.textContent = (this.points[0].snapped ? '已吸附顶点。' : '已选择表面或线上的点。') + '请选择第二个点。';
        else {
            const distance = this.points[0].point.distanceTo (this.points[1].point);
            const unit = this.unit.value;
            const formatted = Number (distance.toPrecision (8)).toString ();
            const points = '点1：' + (this.points[0].snapped ? '顶点' : '表面或线') + '；点2：' + (this.points[1].snapped ? '顶点' : '表面或线');
            this.result.textContent = unit ? '距离：' + formatted + ' ' + unit + '（显示几何近似值） · ' + points :
                '距离：' + formatted + '（模型单位未知，请选择单位） · ' + points;
        }
    }
}
