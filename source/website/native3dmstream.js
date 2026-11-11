import * as THREE from 'three';
import { Direction } from '../engine/geometry/geometry.js';
import { ShadingType } from '../engine/threejs/threeutils.js';
import { NativePager } from './nativepager.js';

const Pause = (milliseconds) => new Promise ((resolve) => setTimeout (resolve, milliseconds));

export class Native3dmStream
{
    constructor (website)
    {
        this.website = website;
        website.nativeStream = this;
        this.viewer = website.viewer;
        this.pager = new NativePager (this);
        this.active = false;
        this.generation = 0;
        this.root = null;
        this.entries = new Map ();
        this.layers = new Map ();
        this.layerIds = new Map ();
        this.overrides = {};
        this.materials = new Map ();
        this.textures = new Map ();
        this.materialDefinitions = new Map ();
        this.residentBytes = 0;
        this.userNavigated = false;
        this.installedNavigationListener = false;
    }

    Notify (message)
    {
        window.webkit?.messageHandlers?.o3dv?.postMessage (message);
    }

    Stop ()
    {
        this.pager.Stop ();
        this.active = false;
        this.generation += 1;
        this.entries.clear ();
        this.layers.clear ();
        this.layerIds.clear ();
        for (const material of this.materials.values ()) {
            material.dispose ();
        }
        for (const texture of this.textures.values ()) {
            texture.dispose ();
        }
        this.materials.clear ();
        this.textures.clear ();
        this.materialDefinitions.clear ();
        this.root = null;
        this.residentBytes = 0;
        this.overrides = {};
        document.body.classList.remove ('o3dv-native-stream');
        this.viewer.SetMouseClickHandler (this.website.OnModelClicked.bind (this.website));
        this.viewer.SetContextMenuHandler (this.website.OnModelContextMenu.bind (this.website));
    }

    async Start (manifestUrl)
    {
        this.Stop ();
        this.active = true;
        const generation = this.generation;
        this.manifestUrl = manifestUrl;
        this.lastFitBounds = null;
        this.initialFit = false;
        this.finalFit = false;
        this.userNavigated = false;
        if (!this.installedNavigationListener) {
            this.viewer.canvas.addEventListener ('pointerdown', () => { this.userNavigated = true; });
            this.viewer.canvas.addEventListener ('touchstart', () => { this.userNavigated = true; }, { passive : true });
            this.installedNavigationListener = true;
        }
        this.root = new THREE.Group ();
        this.website.BeginNativeStream (this.root);
        this.pager.Start (manifestUrl);
        this.viewer.SetUpVector (Direction.Z, false);
        this.viewer.shadingModel.SetShadingType (ShadingType.Phong);
        this.viewer.SetMouseClickHandler ((button, coordinates) => this.Select (coordinates));
        this.viewer.SetContextMenuHandler ((globalCoordinates, coordinates) => this.Select (coordinates));
        let manifest = null;
        let nextManifest = 0;
        let operation = '启动分块加载';
        const metadataIds = new Set ();
        try {
            while (this.active && generation === this.generation) {
                if ((!manifest || !manifest.complete) && performance.now () >= nextManifest) {
                    operation = '读取对象清单';
                    const response = await fetch (manifestUrl, { cache : 'no-store' });
                    if (!response.ok) {
                        throw new Error ('无法读取模型缓存：' + response.status);
                    }
                    const fresh = await response.json ();
                    if (generation !== this.generation) {
                        return;
                    }
                    manifest = fresh;
                    this.manifest = manifest;
                    for (const material of manifest.materials) {
                        this.materialDefinitions.set (material.index, material);
                    }
                    if (manifest.reader === 'gltf-stream-1' || manifest.reader === 'skp-stream-1') {
                        this.viewer.shadingModel.SetShadingType (ShadingType.Physical);
                    }
                    for (const layer of manifest.layers) {
                        this.layers.set (layer.index, layer);
                        this.layerIds.set (layer.id, layer);
                    }
                    for (const object of manifest.objects) {
                        if (!this.entries.has (object.id)) {
                            this.entries.set (object.id, { data : object, object : null, loadedOnce : false, lastUse : 0 });
                        }
                    }
                    this.website.parameters.fileNameDiv.textContent = manifest.name;
                    const metadata = [];
                    for (const item of manifest.objects) {
                        for (const part of item.parts || [item]) {
                            if (!metadataIds.has (part.id)) {
                                metadataIds.add (part.id);
                                metadata.push ({ id : part.id, name : part.name, type : part.type, layerIndex : item.layerIndex });
                            }
                        }
                    }
                    this.Notify ({ type : 'stream_metadata', name : manifest.name, layers : manifest.layers,
                        objects : metadata, append : true });
                    nextManifest = performance.now () + 200;
                    if (!this.userNavigated && manifest.bounds && (!this.initialFit || (manifest.complete && !this.finalFit))) {
                        const boundsKey = manifest.bounds.join (',');
                        if (this.lastFitBounds !== boundsKey) {
                            this.Fit (manifest.bounds);
                            this.lastFitBounds = boundsKey;
                        }
                        this.initialFit = manifest.bounds.slice (0, 3).some ((v, i) => v !== manifest.bounds[i + 3]);
                        this.finalFit = !!manifest.complete;
                    }
                    this.pager.Update (manifest);
                }
                await Pause (150);
            }
        } catch (error) {
            if (generation === this.generation) {
                this.Notify ({ type : 'javascript_error', name : operation + '：' + String (error),
                    stack : error.stack || '', manifestUrl });
            }
        }
    }

    Decode (data, buffer, shared = null)
    {
        const header = new DataView (buffer);
        const version = header.byteLength >= 32 ? header.getUint32 (4, true) : 0;
        if (header.byteLength < 32 || header.getUint32 (0, true) !== 0x3144334f || ![1, 2, 3].includes (version)) {
            throw new Error ('模型块格式不正确。');
        }
        const vertices = header.getUint32 (8, true);
        const indices = header.getUint32 (12, true);
        const lines = header.getUint32 (16, true);
        const colors = header.getUint32 (20, true) !== 0;
        const colorComponents = version >= 3 ? 4 : 3;
        const uvs = version >= 2 && (header.getUint32 (24, true) & 1) !== 0;
        const uv1 = version >= 3 && (header.getUint32 (24, true) & 2) !== 0;
        const tangents = version >= 3 && (header.getUint32 (28, true) & 1) !== 0;
        const expected = 32 + vertices * 24 + indices * 4 + lines * 12 + (colors ? vertices * colorComponents * 4 : 0) + (uvs ? vertices * 8 : 0) + (uv1 ? vertices * 8 : 0) + (tangents ? vertices * 16 : 0);
        if (buffer.byteLength !== expected) {
            throw new Error ('模型块数据不完整。');
        }
        let offset = 32;
        const positions = new Float32Array (buffer, offset, vertices * 3);
        offset += vertices * 12;
        const normals = new Float32Array (buffer, offset, vertices * 3);
        offset += vertices * 12;
        const faces = new Uint32Array (buffer, offset, indices);
        offset += indices * 4;
        const linePositions = new Float32Array (buffer, offset, lines * 3);
        offset += lines * 12;
        const group = new THREE.Group ();
        if (data.transform) {
            group.matrixAutoUpdate = false;
            group.matrix.makeTranslation (...data.origin);
            group.matrix.premultiply (new THREE.Matrix4 ().fromArray (data.transform));
        } else {
            group.position.fromArray (data.origin);
        }
        const userData = { nativeObject : data };
        const savedBounds = this.entries.get (data.sourceObjectId)?.data;
        const boundsData = savedBounds || data;
        const bounds = data.geometryBounds || boundsData.bounds;
        const localBox = new THREE.Box3 (new THREE.Vector3 ().fromArray (bounds), new THREE.Vector3 ().fromArray (bounds, 3));
        if (!data.geometryBounds && !savedBounds && data.transform) {
            localBox.applyMatrix4 (new THREE.Matrix4 ().fromArray (data.transform).invert ());
        }
        localBox.translate (new THREE.Vector3 ().fromArray (data.origin).negate ());
        const setSavedBounds = (geometry) => {
            geometry.boundingBox = localBox.clone ();
            geometry.boundingSphere = localBox.getBoundingSphere (new THREE.Sphere ());
            geometry.boundingSphere.radius = geometry.boundingSphere.radius * (1 + 1e-6) + 1e-6;
        };
        const key = JSON.stringify ([data.materialIndex, data.color, data.opacity, colors, uvs, data.drawMode, data.cadAutoColor]);
        if (vertices > 0) {
            const geometry = shared?.mesh || new THREE.BufferGeometry ();
            if (!shared?.mesh) {
                geometry.setAttribute ('position', new THREE.BufferAttribute (positions, 3));
                geometry.setAttribute ('normal', new THREE.BufferAttribute (normals, 3));
                geometry.setIndex (new THREE.BufferAttribute (faces, 1));
                setSavedBounds (geometry);
            }
            if (colors) {
                if (!shared?.mesh) {
                    geometry.setAttribute ('color', new THREE.BufferAttribute (new Float32Array (buffer, offset, vertices * colorComponents), colorComponents));
                }
                offset += vertices * colorComponents * 4;
            }
            for (const [enabled, name, components] of [[uvs, 'uv', 2], [uv1, 'uv1', 2], [tangents, 'tangent', 4]]) {
                if (enabled) {
                    if (!shared?.mesh) {
                        geometry.setAttribute (name, new THREE.BufferAttribute (new Float32Array (buffer, offset, vertices * components), components));
                    }
                    offset += vertices * components * 4;
                }
            }
            if (!this.materials.has (key)) {
                const definition = this.materialDefinitions.get (data.materialIndex);
                const gltf = definition?.shading === 'pbr' || definition?.shading === 'unlit';
                const blend = gltf ? definition.alphaMode === 'BLEND' : data.opacity < 1;
                const settings = {
                    color : new THREE.Color ().fromArray (data.cadAutoColor ? this.CadDisplayColor () : data.color), opacity : data.opacity,
                    transparent : blend, side : gltf && !definition.doubleSided ? THREE.FrontSide : THREE.DoubleSide,
                    vertexColors : colors, depthWrite : !blend,
                    alphaTest : definition?.alphaMode === 'MASK' ? definition.alphaCutoff : 0
                };
                let material;
                if (data.drawMode === 'points') {
                    material = new THREE.PointsMaterial ({ ...settings, size : 3, sizeAttenuation : false });
                } else if (data.drawMode === 'lines') {
                    material = new THREE.LineBasicMaterial (settings);
                } else if (definition?.shading === 'unlit') {
                    material = new THREE.MeshBasicMaterial (settings);
                } else if (definition?.shading === 'pbr') {
                    material = new THREE.MeshStandardMaterial ({ ...settings, metalness : definition.metalness,
                        roughness : definition.roughness, emissive : new THREE.Color ().fromArray (definition.emissive || [0, 0, 0]),
                        emissiveIntensity : definition.emissiveIntensity ?? 1,
                        normalScale : new THREE.Vector2 (definition.normalScale ?? 1, definition.normalScale ?? 1),
                        aoMapIntensity : definition.occlusionStrength ?? 1 });
                } else {
                    material = new THREE.MeshPhongMaterial ({ ...settings, shininess : definition?.shininess || 35 });
                }
                this.materials.set (key, material);
            }
            if (!shared?.mesh) {
                geometry.addGroup (0, indices, 0);
            }
            const material = this.materials.get (key);
            const mesh = data.drawMode === 'points' ? new THREE.Points (geometry, material) : data.drawMode === 'lines' ? new THREE.LineSegments (geometry, material) : new THREE.Mesh (geometry, [material]);
            // The pager already culls with saved world bounds, including affine instances.
            mesh.frustumCulled = false;
            mesh.userData = userData;
            group.add (mesh);
        }
        if (lines > 0) {
            const geometry = shared?.lines || new THREE.BufferGeometry ();
            if (!shared?.lines) {
                geometry.setAttribute ('position', new THREE.BufferAttribute (linePositions, 3));
                setSavedBounds (geometry);
            }
            const material = new THREE.LineBasicMaterial ({ color : new THREE.Color ().fromArray (data.cadAutoColor ? this.CadDisplayColor () : data.lineColor) });
            const line = new THREE.LineSegments (geometry, material);
            line.frustumCulled = false;
            line.userData = userData;
            group.add (line);
        }
        return group;
    }

    CadDisplayColor ()
    {
        const background = this.viewer.renderer.getClearColor (new THREE.Color ());
        const value = background.r * 0.2126 + background.g * 0.7152 + background.b * 0.0722 > 0.35 ? 0.025 : 0.85;
        return [value, value, value];
    }

    UpdateCadColor (object)
    {
        if (!object.userData.nativeObject?.cadAutoColor) { return; }
        const color = this.CadDisplayColor ();
        object.traverse ((child) => {
            for (const material of Array.isArray (child.material) ? child.material : [child.material]) {
                material?.color?.fromArray (color);
            }
        });
    }

    IsVisible (data)
    {
        if (!data.visible || data.definitionMember) {
            return false;
        }
        for (const index of data.visibilityLayers || [data.layerIndex]) {
            let layer = this.layers.get (index);
            const visited = new Set ();
            while (layer && !visited.has (layer.id)) {
                visited.add (layer.id);
                if (!(this.overrides[layer.index] ?? layer.visible ?? true)) {
                    return false;
                }
                layer = this.layerIds.get (layer.parentId);
            }
        }
        return true;
    }

    SetLayers (overrides)
    {
        this.overrides = overrides;
        for (const entry of this.entries.values ()) {
            if (entry.object) {
                const visible = this.IsVisible (entry.data);
                entry.object.traverse ((child) => { child.visible = visible; });
            }
        }
        this.viewer.Render ();
    }

    Frustum ()
    {
        const camera = this.viewer.camera;
        camera.updateMatrixWorld ();
        return new THREE.Frustum ().setFromProjectionMatrix (new THREE.Matrix4 ().multiplyMatrices (camera.projectionMatrix, camera.matrixWorldInverse));
    }

    InView (data, frustum)
    {
        const b = data.bounds;
        return frustum.intersectsBox (new THREE.Box3 (new THREE.Vector3 (b[0], b[1], b[2]), new THREE.Vector3 (b[3], b[4], b[5])));
    }

    Fit (bounds)
    {
        const box = new THREE.Box3 (new THREE.Vector3 (bounds[0], bounds[1], bounds[2]), new THREE.Vector3 (bounds[3], bounds[4], bounds[5]));
        const sphere = box.getBoundingSphere (new THREE.Sphere ());
        if (sphere.radius <= 0) {
            return;
        }
        this.viewer.AdjustClippingPlanesToSphere (sphere);
        this.viewer.FitSphereToWindow (sphere, false);
    }

    FitToWindow ()
    {
        const box = new THREE.Box3 ();
        for (const entry of this.entries.values ()) {
            if (entry.data.available && this.IsVisible (entry.data)) {
                const b = entry.data.bounds;
                box.union (new THREE.Box3 (new THREE.Vector3 (b[0], b[1], b[2]), new THREE.Vector3 (b[3], b[4], b[5])));
            }
        }
        if (!box.isEmpty ()) {
            this.Fit ([box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z]);
        }
    }

    Select (coordinates)
    {
        this.pager.Select (coordinates);
    }
}
