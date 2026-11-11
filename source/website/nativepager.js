import * as THREE from 'three';
import { NativeGeometryReader } from './nativegeometryreader.js';
import { GetLineSegmentsProjectedDistance } from '../engine/threejs/threeutils.js';
import { CameraIsEqual3D } from '../engine/viewer/camera.js';

const Pause = () => new Promise ((resolve) => setTimeout (resolve, 0));
const IsBlend = (data) => data.alphaMode ? data.alphaMode === 'BLEND' : data.opacity < 1;
const TextureRequests = (definition) => [['map', definition.texture, true], ['normalMap', definition.normalTexture, false],
    ['bumpMap', definition.bumpTexture, false], ['metalnessMap', definition.metallicRoughnessTexture, false],
    ['roughnessMap', definition.metallicRoughnessTexture, false], ['aoMap', definition.occlusionTexture, false],
    ['emissiveMap', definition.emissiveTexture, true]];

export class NativePager
{
    constructor (stream)
    {
        this.stream = stream;
        this.viewer = stream.viewer;
        this.policy = { geometryBytes : 64 * 1024 * 1024, textureBytes : 24 * 1024 * 1024, framePixels : 3500000 };
        this.cache = new Map ();
        this.resources = new Map ();
        this.pinned = new Set ();
        this.pinnedNodes = new Set ();
        this.readSlots = new Map ();
        this.inflight = new Set ();
        this.pendingReadBytes = 0;
        this.readEpoch = 0;
        this.textures = new Map ();
        this.resident = 0;
        this.textureBytes = 0;
        this.peakResident = 0;
        this.peakTextures = 0;
        this.serial = 0;
        this.worker = null;
        this.deferredPolicy = null;
        this.active = false;
        this.renderHook = () => this.Request (true);
    }

    InstallListeners ()
    {
        this.viewer.canvas.addEventListener ('webglcontextlost', (event) => {
            if (this.active) {
                event.preventDefault ();
                this.contextLost = true;
                this.restoreClearColor = this.viewer.renderer.getClearColor (new THREE.Color ()).clone ();
                this.restoreClearAlpha = this.viewer.renderer.getClearAlpha ();
                this.serial += 1;
                this.abort?.abort ();
                this.pending = false;
                this.stream.Notify ({ type : 'stream_render_paused', name : '图形资源正在恢复' });
            }
        });
        this.viewer.canvas.addEventListener ('webglcontextrestored', () => {
            if (this.active) {
                this.contextLost = false;
                this.viewer.renderer.setClearColor (this.restoreClearColor, this.restoreClearAlpha);
                this.ClearTextures ();
                this.DisposeTargets ();
                this.Request (true);
            }
        });
    }

    Start (url)
    {
        if (!this.listening) {
            this.InstallListeners ();
            this.listening = true;
        }
        this.active = true;
        this.reader = new NativeGeometryReader (url);
        this.manifest = null;
        this.frame = null;
        this.deferredPolicy = null;
        this.notified = false;
        this.peakResident = 0;
        this.peakTextures = 0;
        this.peakWorking = 0;
        this.peakPrefetch = 0;
        this.sharedHits = 0;
        this.viewer.renderOverride = this.renderHook;
    }

    Stop ()
    {
        this.active = false;
        this.serial += 1;
        this.abort?.abort ();
        this.CancelSlots ();
        this.readEpoch += 1;
        this.ReleasePins ();
        if (this.viewer.renderOverride === this.renderHook) {
            this.viewer.renderOverride = null;
        }
        for (const key of [...this.cache.keys ()]) {
            this.Evict (key);
        }
        for (const key of [...this.resources.keys ()]) {
            this.EvictResource (key);
        }
        this.ClearTextures ();
        this.DisposeTargets ();
        this.presentGeometry?.dispose ();
        this.presentMaterial?.dispose ();
        this.presentGeometry = null;
        this.presentMaterial = null;
        this.frame = null;
        this.deferredPolicy = null;
    }

    SetPolicy (policy)
    {
        const next = { geometryBytes : Math.max (256 * 1024, policy.geometryBytes || this.policy.geometryBytes),
            textureBytes : Math.max (1024 * 1024, policy.textureBytes || this.policy.textureBytes),
            framePixels : Math.max (65536, policy.framePixels || this.policy.framePixels) };
        if (JSON.stringify (next) !== JSON.stringify (this.policy)) {
            // An increase does not require interrupting the frame already being
            // drawn. Apply it as soon as that work yields, then warm the cache.
            const onlyIncreases = Object.keys (next).every ((key) => next[key] >= this.policy[key]);
            if (this.active && this.worker && onlyIncreases) {
                this.deferredPolicy = next;
                return;
            }
            this.deferredPolicy = null;
            const texturesChanged = next.textureBytes !== this.policy.textureBytes;
            this.policy = next;
            this.Trim (0);
            if (texturesChanged) {
                this.ClearTextures ();
            }
            this.Request (true);
        } else {
            // A later sample may revoke an earlier deferred increase.
            this.deferredPolicy = null;
        }
    }

    FinishWorker ()
    {
        this.worker = null;
        if (this.active && this.deferredPolicy) {
            const next = this.deferredPolicy;
            this.deferredPolicy = null;
            this.SetPolicy (next);
        } else if (this.active && this.pending && this.manifest) {
            this.Request (false);
        }
    }

    SetForeground (value)
    {
        this.suspended = !value;
        if (this.suspended) {
            this.serial += 1;
            this.abort?.abort ();
            this.CancelSlots ();
            this.pending = false;
        } else {
            this.Request (true);
        }
    }

    Update (manifest)
    {
        const final = manifest.complete && !this.manifest?.complete;
        this.manifest = manifest;
        this.revision = (this.revision || 0) + 1;
        this.Request (final);
    }

    Request (reset)
    {
        if (!this.active || this.contextLost || this.suspended) {
            return;
        }
        if (reset) {
            this.requestedAt = performance.now ();
            this.serial += 1;
            this.abort?.abort ();
            this.CancelSlots ();
        }
        if (!this.worker && this.manifest?.complete && this.FastRender ()) {
            return;
        }
        this.pending = true;
        if (!this.manifest) {
            return;
        }
        if (!this.worker) {
            this.worker = this.Run ().finally (() => this.FinishWorker ());
        }
    }

    async Fence ()
    {
        const gl = this.viewer.renderer.getContext ();
        if (gl.isContextLost ()) {
            throw new DOMException ('Graphics context lost', 'AbortError');
        }
        if (!gl.fenceSync) {
            gl.finish ();
            return;
        }
        const fence = gl.fenceSync (gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
        gl.flush ();
        for (;;) {
            if (!this.active || this.suspended) {
                gl.deleteSync (fence);
                throw new DOMException ('Render suspended', 'AbortError');
            }
            const status = gl.clientWaitSync (fence, 0, 0);
            if ([gl.ALREADY_SIGNALED, gl.CONDITION_SATISFIED, gl.WAIT_FAILED].includes (status)) {
                break;
            }
            await Pause ();
        }
        gl.deleteSync (fence);
    }

    PlacementLimit ()
    {
        return Math.max (8, Math.min (4096, Math.floor (this.policy.geometryBytes / 16384)));
    }

    ReleasePins ()
    {
        this.pinned.clear ();
        this.pinnedNodes.clear ();
    }

    Evict (key)
    {
        const item = this.cache.get (key);
        if (!item) {
            return;
        }
        this.stream.root?.remove (item.object);
        item.object.traverse ((child) => {
            if (child.isLineSegments) {
                child.material.dispose ();
            }
        });
        this.resources.get (item.resourceKey)?.users.delete (key);
        this.cache.delete (key);
    }

    EvictResource (key)
    {
        const resource = this.resources.get (key);
        if (!resource) {
            return;
        }
        for (const node of [...resource.users]) {
            this.Evict (node);
        }
        for (const geometry of Object.values (resource.shared)) {
            geometry.dispose ();
        }
        resource.buffer = null;
        this.resident -= resource.bytes;
        this.resources.delete (key);
        this.viewer.renderer.renderLists.dispose ();
    }

    Trim (needed)
    {
        for (const key of this.resources.keys ()) {
            if (this.resident + this.pendingReadBytes + needed <= this.policy.geometryBytes) {
                break;
            }
            if (!this.pinned.has (key)) {
                this.EvictResource (key);
            }
        }
    }

    TrimNodes (needed)
    {
        for (const key of this.cache.keys ()) {
            if (this.cache.size + needed <= this.PlacementLimit ()) {
                break;
            }
            if (!this.pinnedNodes.has (key)) {
                this.Evict (key);
            }
        }
    }

    ReleaseReservation (slot)
    {
        if (slot.reserved) {
            this.pendingReadBytes -= slot.reserved;
            slot.reserved = 0;
        }
    }

    RecordWorkingPeak ()
    {
        const bytes = this.resident + this.pendingReadBytes;
        if (bytes > this.peakWorking) {
            this.peakWorking = bytes;
            this.peakWorkingBudget = this.policy.geometryBytes;
        }
    }

    CancelSlots ()
    {
        for (const slot of this.readSlots.values ()) {
            slot.cancelled = true;
            slot.controller.abort ();
            if (slot.ready) {
                slot.decoded = null;
                this.ReleaseReservation (slot);
            }
        }
        this.readSlots.clear ();
    }

    QueueRead (part, signal)
    {
        const key = this.reader.ResourceKey (part);
        if (this.resources.has (key)) {
            return null;
        }
        if (this.readSlots.has (key)) {
            return this.readSlots.get (key);
        }
        if (this.readSlots.size >= 2) {
            return null;
        }
        this.Trim (part.estimate);
        if (this.resident + this.pendingReadBytes + part.estimate > this.policy.geometryBytes) {
            return null;
        }
        const epoch = this.readEpoch;
        const reader = this.reader;
        const controller = new AbortController ();
        const abort = () => controller.abort ();
        signal.addEventListener ('abort', abort, { once : true });
        if (signal.aborted) {
            controller.abort ();
        }
        const slot = { key, controller, reserved : part.estimate, ready : false, cancelled : false };
        this.pendingReadBytes += slot.reserved;
        this.peakPrefetch = Math.max (this.peakPrefetch, this.pendingReadBytes);
        this.RecordWorkingPeak ();
        this.readSlots.set (key, slot);
        slot.promise = reader.Read (part, controller.signal).then ((decoded) => {
            slot.ready = true;
            if (slot.cancelled || controller.signal.aborted || epoch !== this.readEpoch || !this.active) {
                slot.cancelled = true;
                return slot;
            }
            if (decoded.buffer.byteLength > part.estimate) {
                throw new Error ('模型分块超过预留的读取预算。');
            }
            slot.decoded = decoded;
            return slot;
        }).catch ((error) => {
            slot.ready = true;
            slot.error = error;
            this.ReleaseReservation (slot);
            return slot;
        }).finally (() => {
            signal.removeEventListener ('abort', abort);
            this.inflight.delete (slot.promise);
            if (slot.cancelled) {
                slot.decoded = null;
                this.ReleaseReservation (slot);
                if (this.readSlots.get (key) === slot) {
                    this.readSlots.delete (key);
                }
            }
        });
        this.inflight.add (slot.promise);
        return slot;
    }

    ClearTextures ()
    {
        for (const entry of this.textures.values ()) {
            entry.texture.dispose ();
            entry.texture.image?.close?.();
            entry.texture.image = null;
        }
        this.textures.clear ();
        this.textureBytes = 0;
        for (const material of this.stream.materials.values ()) {
            for (const [slot] of TextureRequests ({})) {
                material[slot] = null;
            }
            material.needsUpdate = true;
        }
    }

    TexturePlan (definition)
    {
        const requests = TextureRequests (definition || {});
        const textureCount = Math.max (1, requests.filter ((r) => r[1]?.url).length);
        const edge = Math.max (64, Math.min (1024, 2 ** Math.floor (Math.log2 (Math.sqrt (this.policy.textureBytes / (textureCount * 8))))));
        const keys = new Set (requests.filter ((r) => r[1]?.url).map ((r) => JSON.stringify ([r[1], r[2], edge])));
        return { requests, edge, keys };
    }

    TexturesFit (plan, protectedKeys)
    {
        let bytes = 0;
        for (const key of new Set ([...protectedKeys, ...plan.keys])) {
            bytes += this.textures.get (key)?.bytes || (plan.keys.has (key) ? plan.edge * plan.edge * 8 : 0);
        }
        return bytes <= this.policy.textureBytes;
    }

    async PrepareMaterial (object, signal, protectedKeys)
    {
        const definition = this.stream.materialDefinitions.get (object.userData?.nativeObject?.materialIndex);
        // Geometry lives below a group; materials share a definition across blocks.
        const meshes = [];
        object.traverse ((child) => { if (child.geometry && (child.geometry.hasAttribute ('uv') || child.geometry.hasAttribute ('uv1'))) { meshes.push (child); } });
        if (!meshes.length || !definition) {
            return [];
        }
        const { requests, edge, keys } = this.TexturePlan (definition);
        const reserve = [...keys].filter ((key) => !this.textures.has (key)).length * edge * edge * 8;
        if (reserve > this.policy.textureBytes) {
            throw new Error ('当前贴图显示预算不足。');
        }
        for (const [key, value] of this.textures) {
            if (this.textureBytes + reserve <= this.policy.textureBytes) {
                break;
            }
            if (!keys.has (key) && !protectedKeys.has (key)) {
                value.texture.dispose ();
                value.texture.image?.close?.();
                value.texture.image = null;
                this.textureBytes -= value.bytes;
                this.textures.delete (key);
            }
        }
        if (this.textureBytes + reserve > this.policy.textureBytes) {
            throw new Error ('当前批次的贴图超过显示预算。');
        }
        for (const [slot, data, color] of requests) {
            let texture = null;
            if (data?.url) {
                const key = JSON.stringify ([data, color, edge]);
                let cached = this.textures.get (key);
                if (!cached) {
                    const url = new URL (data.url, this.stream.manifestUrl);
                    url.searchParams.set ('o3dvTextureEdge', edge);
                    const response = await fetch (url.href, { signal });
                    if (!response.ok) {
                        throw new Error ('贴图无法生成显示缓存：' + data.url);
                    }
                    const blob = await response.blob ();
                    let bitmap;
                    if (typeof createImageBitmap === 'function') {
                        bitmap = await createImageBitmap (blob, { imageOrientation : data.flipY === false ? 'none' : 'flipY', premultiplyAlpha : 'none', colorSpaceConversion : 'none' });
                    } else {
                        bitmap = await new Promise ((resolve, reject) => {
                            const img = new Image ();
                            const local = URL.createObjectURL (blob);
                            img.onload = () => { URL.revokeObjectURL (local); resolve (img); };
                            img.onerror = () => { URL.revokeObjectURL (local); reject (new Error ('贴图解码失败')); };
                            img.src = local;
                        });
                    }
                    if (bitmap.width > edge || bitmap.height > edge) {
                        bitmap.close?.();
                        throw new Error ('贴图显示缓存超过像素预算。');
                    }
                    if (signal.aborted || !this.active) {
                        bitmap.close?.();
                        throw new DOMException ('Aborted', 'AbortError');
                    }
                    texture = new THREE.Texture (bitmap);
                    texture.flipY = data.flipY !== false && typeof bitmap.close !== 'function';
                    texture.colorSpace = color ? THREE.SRGBColorSpace : THREE.NoColorSpace;
                    const wrap = (value, repeat) => value === 33648 ? THREE.MirroredRepeatWrapping : value === 10497 || (value === undefined && repeat) ? THREE.RepeatWrapping : THREE.ClampToEdgeWrapping;
                    texture.wrapS = wrap (data.wrapS, data.wrapU);
                    texture.wrapT = wrap (data.wrapT, data.wrapV);
                    texture.channel = data.channel || 0;
                    texture.generateMipmaps = false;
                    texture.magFilter = data.magFilter === 9728 ? THREE.NearestFilter : THREE.LinearFilter;
                    texture.minFilter = [9728, 9984, 9986].includes (data.minFilter) ? THREE.NearestFilter : THREE.LinearFilter;
                    texture.matrixAutoUpdate = false;
                    texture.matrix.fromArray (data.matrix);
                    texture.needsUpdate = true;
                    cached = { texture, bytes : bitmap.width * bitmap.height * 8 };
                    this.textures.set (key, cached);
                    this.textureBytes += cached.bytes;
                    this.peakTextures = Math.max (this.peakTextures, this.textureBytes);
                }
                texture = cached.texture;
            }
            for (const mesh of meshes) {
                const material = Array.isArray (mesh.material) ? mesh.material[0] : mesh.material;
                if (slot in material && material[slot] !== texture) {
                    material[slot] = texture;
                    material.needsUpdate = true;
                }
            }
        }
        return keys;
    }

    async Acquire (part, signal)
    {
        const resourceKey = this.reader.ResourceKey (part);
        if (this.cache.has (part.key)) {
            const item = this.cache.get (part.key);
            this.cache.delete (part.key);
            this.cache.set (part.key, item);
            const resource = this.resources.get (resourceKey);
            this.resources.delete (resourceKey);
            this.resources.set (resourceKey, resource);
            this.pinned.add (resourceKey);
            this.pinnedNodes.add (part.key);
            this.sharedHits += 1;
            return item;
        }
        this.TrimNodes (1);
        if (this.cache.size + 1 > this.PlacementLimit ()) {
            return null;
        }
        let resource = this.resources.get (resourceKey);
        let object;
        if (!resource) {
            const slot = this.readSlots.get (resourceKey) || this.QueueRead (part, signal);
            if (!slot) {
                return null;
            }
            await slot.promise;
            if (signal.aborted || !this.active || slot.cancelled) {
                throw new DOMException ('Aborted', 'AbortError');
            }
            if (slot.error) {
                throw slot.error;
            }
            const decoded = slot.decoded;
            if (!decoded) {
                throw new DOMException ('Aborted', 'AbortError');
            }
            this.ReleaseReservation (slot);
            this.readSlots.delete (resourceKey);
            slot.decoded = null;
            object = this.stream.Decode (this.reader.Data (part), decoded.buffer);
            const shared = {};
            object.traverse ((child) => {
                if (child.isMesh || (child.geometry && child.userData?.nativeObject?.drawMode)) {
                    shared.mesh = child.geometry;
                } else if (child.isLineSegments) {
                    shared.lines = child.geometry;
                }
            });
            resource = { buffer : decoded.buffer, shared, bytes : decoded.buffer.byteLength, users : new Set () };
            this.resources.set (resourceKey, resource);
            this.resident += resource.bytes;
            this.peakResident = Math.max (this.peakResident, this.resident);
            this.RecordWorkingPeak ();
        } else {
            this.sharedHits += 1;
            this.resources.delete (resourceKey);
            this.resources.set (resourceKey, resource);
            object = this.stream.Decode (this.reader.Data (part), resource.buffer, resource.shared);
        }
        object.userData = { nativeObject : this.reader.Data (part) };
        this.stream.root.add (object);
        const item = { object, bytes : resource.bytes, part, resourceKey };
        this.cache.set (part.key, item);
        resource.users.add (part.key);
        this.pinned.add (resourceKey);
        this.pinnedNodes.add (part.key);
        return item;
    }

    DisposeTargets ()
    {
        for (const target of new Set ([this.target, this.completeTarget, this.spareTarget])) {
            target?.dispose ();
        }
        this.target = null;
        this.completeTarget = null;
        this.spareTarget = null;
    }

    Present (target)
    {
        if (this.presentMaterial.map !== target.texture) {
            this.presentMaterial.map = target.texture;
            this.presentMaterial.needsUpdate = true;
        }
        const renderer = this.viewer.renderer;
        renderer.setRenderTarget (null);
        renderer.clear (true, true, true);
        renderer.render (this.presentScene, this.presentCamera);
    }

    BeginFrame (preservePrevious = true)
    {
        const size = this.viewer.renderer.getDrawingBufferSize (new THREE.Vector2 ());
        const scale = Math.min (1, Math.sqrt (this.policy.framePixels / (size.x * size.y)));
        const width = Math.max (1, Math.floor (size.x * scale)), height = Math.max (1, Math.floor (size.y * scale));
        if (!this.target || this.target.width !== width || this.target.height !== height) {
            this.DisposeTargets ();
            this.target = new THREE.WebGLRenderTarget (width, height, { depthBuffer : true, stencilBuffer : false });
            if (!this.presentGeometry) {
                this.presentGeometry = new THREE.PlaneGeometry (2, 2);
                this.presentMaterial = new THREE.MeshBasicMaterial ({ depthTest : false, depthWrite : false, toneMapped : false });
                this.presentScene = new THREE.Scene ();
                this.presentScene.add (new THREE.Mesh (this.presentGeometry, this.presentMaterial));
                this.presentCamera = new THREE.Camera ();
            }
        } else if (preservePrevious && this.completeTarget === this.target) {
            this.target = this.spareTarget || new THREE.WebGLRenderTarget (width, height, { depthBuffer : true, stencilBuffer : false });
            this.spareTarget = null;
        } else if (!preservePrevious && this.completeTarget) {
            if (this.target !== this.completeTarget) {
                this.target?.dispose ();
            }
            this.target = this.completeTarget;
            this.spareTarget?.dispose ();
            this.spareTarget = null;
        }
        this.presentMaterial.map = (this.completeTarget || this.target).texture;
        this.presentMaterial.needsUpdate = true;
        this.frame = { serial : this.serial, painted : new Set (), parents : new Set (), clear : true,
            startedAt : this.requestedAt || performance.now (), readRequests : this.reader.readRequests, readBytes : this.reader.readBytes, batches : 0 };
    }

    Draw (object, sort = false)
    {
        const renderer = this.viewer.renderer;
        const autoClear = renderer.autoClear;
        const background = this.viewer.scene.background;
        const sortObjects = renderer.sortObjects;
        const root = this.stream.root;
        const children = root.children;
        const visible = object instanceof Set ? [...object] : object ? [object] : [];
        root.children = visible;
        for (const child of visible) {
            this.stream.UpdateCadColor?.(child);
            child.visible = true;
        }
        try {
            renderer.sortObjects = sort;
            renderer.autoClear = false;
            renderer.setRenderTarget (this.target);
            if (this.frame.clear) {
                renderer.clear (true, true, true);
            } else {
                this.viewer.scene.background = null;
            }
            renderer.render (this.viewer.scene, this.viewer.camera);
            this.frame.clear = false;
            this.Present (this.completeTarget || this.target);
            this.frame.batches += 1;
        } finally {
            renderer.setRenderTarget (null);
            renderer.autoClear = autoClear;
            renderer.sortObjects = sortObjects;
            root.children = children;
            this.viewer.scene.background = background;
        }
    }

    VisibleEntries ()
    {
        const frustum = this.stream.Frustum ();
        const entries = [...this.stream.entries.values ()].filter ((e) => e.data.available && this.stream.IsVisible (e.data) && this.stream.InView (e.data, frustum));
        const distances = new Map ();
        const textureGroups = new Map ();
        const groups = new Map ();
        for (const entry of entries) {
            distances.set (entry, new THREE.Vector3 ().fromArray (entry.data.bounds).add (new THREE.Vector3 ().fromArray (entry.data.bounds, 3)).multiplyScalar (0.5).distanceToSquared (this.viewer.camera.position));
            const index = entry.data.materialIndex;
            if (!textureGroups.has (index)) {
                const definition = this.stream.materialDefinitions.get (index) || {};
                const maps = TextureRequests (definition).map ((request) => request[1]);
                const key = maps.some ((map) => map?.url) ? JSON.stringify (maps) : '';
                if (!groups.has (key)) {
                    groups.set (key, groups.size);
                }
                textureGroups.set (index, groups.get (key));
            }
        }
        entries.sort ((a, b) => {
            const ta = IsBlend (a.data), tb = IsBlend (b.data);
            if (ta !== tb) {
                return Number (ta) - Number (tb);
            }
            // Opaque depth writes allow texture grouping without losing surfaces.
            // Blended surfaces retain their far-to-near order across all batches.
            if (!ta) {
                const group = textureGroups.get (a.data.materialIndex) - textureGroups.get (b.data.materialIndex);
                if (group) {
                    return group;
                }
            }
            return ta ? distances.get (b) - distances.get (a) : distances.get (a) - distances.get (b);
        });
        return entries;
    }

    CachedPlan (entry)
    {
        const whole = { key : entry.data.id, entry, estimate : entry.data.bytes };
        if (entry.data.bytes <= this.policy.geometryBytes && this.resources.has (this.reader.ResourceKey (whole))) {
            return [whole];
        }
        return this.reader.CachedParts (entry, this.policy.geometryBytes);
    }

    async Run ()
    {
        while (this.active && !this.suspended && this.pending && this.manifest) {
            this.pending = false;
            const serial = this.serial;
            const revision = this.revision;
            this.abort = new AbortController ();
            const signal = this.abort.signal;
            let batch = [];
            let batchBytes = 0;
            const batchTextureKeys = new Set ();
            const remaining = new Map ();
            const batchResources = new Set ();
            let batchStart = performance.now ();
            const current = () => this.active && serial === this.serial && !signal.aborted;
            const flush = async () => {
                if (!batch.length || !current ()) {
                    return;
                }
                this.Draw (new Set (batch.map ((job) => job.item.object)));
                await this.Fence ();
                if (!current ()) {
                    return;
                }
                for (const job of batch) {
                    this.frame.painted.add (job.part.key);
                    const id = job.part.entry.data.id;
                    remaining.set (id, remaining.get (id) - 1);
                    if (remaining.get (id) === 0) {
                        this.frame.parents.add (id);
                    }
                }
                batch = [];
                batchBytes = 0;
                batchTextureKeys.clear ();
                batchResources.clear ();
                this.ReleasePins ();
                this.Report (false);
                batchStart = performance.now ();
                await Pause ();
            };
            try {
                if (!this.frame || this.frame.serial !== serial) {
                    await Promise.all ([this.Fence (), ...this.inflight]);
                    if (!current ()) {
                        continue;
                    }
                    this.ReleasePins ();
                    this.Trim (0);
                    this.TrimNodes (0);
                    this.BeginFrame ();
                }
                const jobs = [];
                const plans = [];
                const visibleEntries = this.VisibleEntries ();
                this.frame.visibleTotal = visibleEntries.length;
                if (this.notified) {
                    this.Report (false);
                }
                for (const entry of visibleEntries) {
                    const parts = this.CachedPlan (entry) || await this.reader.Parts (entry, this.policy.geometryBytes, signal);
                    if (!current ()) {
                        break;
                    }
                    plans.push ({ entry, parts });
                    remaining.set (entry.data.id, parts.filter ((p) => !this.frame.painted.has (p.key)).length);
                    for (const part of parts) {
                        if (!this.frame.painted.has (part.key)) {
                            jobs.push (part);
                        }
                    }
                }
                for (let index = 0; index < jobs.length && current (); index++) {
                    const part = jobs[index];
                    const key = this.reader.ResourceKey (part);
                    const definition = this.stream.materialDefinitions.get (part.entry.data.materialIndex);
                    const texturePlan = this.TexturePlan (definition);
                    // A queued batch pins its textures until the GPU fence completes.
                    // Keep transparent order while admitting every map that fits.
                    if (batch.length && !this.TexturesFit (texturePlan, batchTextureKeys)) {
                        await flush ();
                        if (!current ()) {
                            break;
                        }
                    }
                    if (this.resources.has (key)) {
                        this.pinned.add (key);
                        if (this.cache.has (part.key)) {
                            this.pinnedNodes.add (part.key);
                        }
                    }
                    if (!this.resources.has (key) && !this.QueueRead (part, signal)) {
                        await flush ();
                        if (!current ()) {
                            break;
                        }
                    }
                    // At most one future part is held alongside the current read.
                    if (jobs[index + 1]) {
                        this.QueueRead (jobs[index + 1], signal);
                    }
                    let item = await this.Acquire (part, signal);
                    if (!item) {
                        await flush ();
                        if (!current ()) {
                            break;
                        }
                        item = await this.Acquire (part, signal);
                    }
                    if (!item) {
                        this.CancelSlots ();
                        await Promise.all ([...this.inflight]);
                        if (!current ()) {
                            break;
                        }
                        item = await this.Acquire (part, signal);
                        if (!item) {
                            throw new Error ('模型块超过当前显示和预读预算。');
                        }
                    }
                    const usedTextures = await this.PrepareMaterial (item.object, signal, batchTextureKeys);
                    if (!current ()) {
                        break;
                    }
                    batch.push ({ part, item });
                    for (const texture of usedTextures) {
                        batchTextureKeys.add (texture);
                    }
                    if (!batchResources.has (key)) {
                        batchResources.add (key);
                        batchBytes += item.bytes;
                    }
                    if (batch.length >= 32 || batchBytes >= Math.min (8 * 1024 * 1024, this.policy.geometryBytes / 2)) {
                        await flush ();
                    } else if (performance.now () - batchStart >= 12) {
                        // I/O already yields while a bounded batch is prepared.
                        // Yield for input without submitting a tiny GPU batch.
                        await Pause ();
                        batchStart = performance.now ();
                    }
                }
                await flush ();
                if (current ()) {
                    for (const { entry, parts } of plans) {
                        if (parts.every ((p) => this.frame.painted.has (p.key))) {
                            this.frame.parents.add (entry.data.id);
                        }
                    }
                }
                if (current () && revision === this.revision) {
                    if (this.frame.clear) {
                        this.Draw (null);
                        await this.Fence ();
                    }
                    this.frame.complete = !!this.manifest.complete;
                    if (this.frame.complete) {
                        this.spareTarget = this.completeTarget !== this.target ? this.completeTarget : this.spareTarget;
                        this.completeTarget = this.target;
                        this.Present (this.completeTarget);
                    }
                    this.Report (this.frame.complete);
                }
            } catch (error) {
                if (error.name !== 'AbortError' && this.active && serial === this.serial) {
                    this.stream.Notify ({ type : 'javascript_error', name : String (error), stack : error.stack || '' });
                    this.active = false;
                    this.CancelSlots ();
                }
            } finally {
                this.ReleasePins ();
            }
        }
    }

    Thumbnail ()
    {
        if (!this.target || (!this.completeTarget && this.frame?.clear)) {
            return null;
        }
        const renderer = this.viewer.renderer;
        renderer.setRenderTarget (null);
        renderer.render (this.presentScene, this.presentCamera);
        const source = this.viewer.canvas;
        const canvas = document.createElement ('canvas');
        canvas.width = 360;
        canvas.height = 360;
        const context = canvas.getContext ('2d');
        context.fillStyle = '#' + renderer.getClearColor (new THREE.Color ()).getHexString ();
        context.fillRect (0, 0, 360, 360);
        const scale = Math.min (360 / source.width, 360 / source.height);
        context.drawImage (source, (360 - source.width * scale) / 2, (360 - source.height * scale) / 2, source.width * scale, source.height * scale);
        return canvas.toDataURL ();
    }

    async Select (coordinates)
    {
        if (!this.active || this.contextLost) {
            return;
        }
        this.serial += 1;
        const serial = this.serial;
        this.abort?.abort ();
        this.pending = false;
        this.CancelSlots ();
        await this.worker;
        await Promise.all ([...this.inflight]);
        if (!this.active || serial !== this.serial) {
            return;
        }
        this.abort = new AbortController ();
        const signal = this.abort.signal;
        this.worker = (async () => {
            try {
                const size = this.viewer.GetCanvasSize ();
                const raycaster = new THREE.Raycaster ();
                raycaster.setFromCamera (new THREE.Vector2 (coordinates.x / size.width * 2 - 1, 1 - coordinates.y / size.height * 2), this.viewer.camera);
                const camera = this.viewer.camera;
                const center = this.viewer.GetCamera ().center;
                const distance = camera.position.distanceTo (new THREE.Vector3 (center.x, center.y, center.z));
                const lineThreshold = camera.isPerspectiveCamera ? 20 * distance * Math.tan (camera.fov * Math.PI / 360) / size.height : 10 * (camera.top - camera.bottom) / size.height;
                raycaster.params.Line.threshold = lineThreshold;
                raycaster.params.Points.threshold = lineThreshold;
                const candidates = [];
                for (const entry of this.stream.entries.values ()) {
                    if (!entry.data.available || !this.stream.IsVisible (entry.data)) {
                        continue;
                    }
                    const b = entry.data.bounds;
                    const box = new THREE.Box3 (new THREE.Vector3 (b[0], b[1], b[2]), new THREE.Vector3 (b[3], b[4], b[5]));
                    if (entry.data.lineSegments > 0 || entry.data.drawMode === 'points') {
                        box.expandByScalar (lineThreshold);
                    }
                    const point = raycaster.ray.intersectBox (box, new THREE.Vector3 ());
                    if (point) {
                        candidates.push ({ entry, distance : box.containsPoint (raycaster.ray.origin) ? 0 : point.distanceTo (raycaster.ray.origin) });
                    }
                }
                candidates.sort ((a, b) => a.distance - b.distance);
                let nearest = null;
                await this.Fence ();
                for (const candidate of candidates) {
                    if (nearest && candidate.distance > nearest.distance) {
                        break;
                    }
                    for (const part of await this.reader.Parts (candidate.entry, this.policy.geometryBytes, signal)) {
                        this.ReleasePins ();
                        const item = await this.Acquire (part, signal);
                        if (!item) {
                            throw new Error ('拾取所需分块超过当前预算。');
                        }
                        item.object.updateMatrixWorld (true);
                        item.object.traverse ((child) => {
                            const geometry = child.geometry;
                            if (geometry && !geometry.userData.nativePickSphere) {
                                if (!geometry.boundingSphere) {
                                    geometry.computeBoundingSphere ();
                                }
                                // sqrt(3) keeps the broad phase conservative for shear matrices.
                                geometry.boundingSphere.radius *= Math.sqrt (3);
                                geometry.userData.nativePickSphere = true;
                            }
                        });
                        const hit = raycaster.intersectObject (item.object, true).find ((candidate) => !candidate.object.isLineSegments ||
                            GetLineSegmentsProjectedDistance (camera, size.width, size.height, candidate.object, coordinates) <= 10);
                        if (hit && (!nearest || hit.distance < nearest.distance)) {
                            nearest = { distance : hit.distance, data : hit.object.userData.nativeObject,
                                index : hit.object.isMesh ? hit.faceIndex * 3 : hit.index, mesh : hit.object.isMesh || !!hit.object.userData.nativeObject.drawMode };
                        }
                        await Pause ();
                    }
                }
                if (nearest && this.active && serial === this.serial) {
                    const data = nearest.data;
                    const index = nearest.index + (nearest.mesh ? data.indexBase || 0 : data.lineBase || 0);
                    const selected = data.parts?.find ((p) => nearest.mesh ? index >= p.start && index < p.end : index >= p.lineStart && index < p.lineEnd) || data;
                    this.stream.Notify ({ type : 'stream_selection', object : { id : selected.id, name : selected.name, type : selected.type,
                        layer : this.stream.layers.get (data.layerIndex)?.name || '', material : String (data.materialIndex) } });
                }
            } catch (error) {
                if (error.name !== 'AbortError' && this.active && serial === this.serial) {
                    this.stream.Notify ({ type : 'stream_selection_error', name : String (error) });
                }
            }
        }) ().finally (() => {
            this.ReleasePins ();
            this.worker = null;
            if (this.active && serial === this.serial) {
                if (this.deferredPolicy) {
                    const next = this.deferredPolicy;
                    this.deferredPolicy = null;
                    this.SetPolicy (next);
                } else {
                    this.Request (true);
                }
            } else if (this.active && this.pending) {
                this.FinishWorker ();
            }
        });
        await this.worker;
    }

    FastRender ()
    {
        if (this.pendingReadBytes || this.resident > this.policy.geometryBytes || this.cache.size > this.PlacementLimit ()) {
            return false;
        }
        const objects = new Set ();
        for (const entry of this.VisibleEntries ()) {
            const whole = this.cache.get (entry.data.id);
            const parts = whole ? [whole.part] : this.CachedPlan (entry);
            if (!parts) {
                return false;
            }
            for (const part of parts) {
                const cached = this.cache.get (part.key);
                if (!cached) {
                    return false;
                }
                let valid = true;
                cached.object.traverse ((child) => {
                    if (!child.geometry || (!child.geometry.hasAttribute ('uv') && !child.geometry.hasAttribute ('uv1'))) {
                        return;
                    }
                    const definition = this.stream.materialDefinitions.get (entry.data.materialIndex);
                    const material = Array.isArray (child.material) ? child.material[0] : child.material;
                    for (const [slot, data] of TextureRequests (definition || {})) {
                        if (data?.url && slot in material && !material[slot]?.image) {
                            valid = false;
                        }
                    }
                });
                if (!valid) {
                    return false;
                }
                objects.add (cached.object);
            }
        }
        this.pending = false;
        this.BeginFrame (false);
        this.Draw (objects, [...objects].every ((object) => !IsBlend (object.userData.nativeObject)));
        const serial = this.serial;
        // Keep one submitted view in flight; new input replaces the pending view.
        this.worker = this.Fence ().then (() => {
            if (this.active && serial === this.serial) {
                this.frame.complete = true;
                this.completeTarget = this.target;
                this.Present (this.completeTarget);
                this.Report (true);
            }
        }).catch ((error) => {
            if (error.name !== 'AbortError' && this.active && serial === this.serial) {
                this.stream.Notify ({ type : 'javascript_error', name : String (error) });
                this.active = false;
            }
        }).finally (() => this.FinishWorker ());
        return true;
    }

    Report (complete)
    {
        if (!complete && performance.now () - (this.lastReport || 0) < 250) {
            return;
        }
        this.lastReport = performance.now ();
        const m = this.manifest;
        const state = { stream : true, name : m.name, manifestUrl : this.stream.manifestUrl, displayed : complete ? m.objects.filter ((o) => o.available).length : this.frame.parents.size,
            total : m.objects.length, visibleDone : this.frame.parents.size, visibleTotal : this.frame.visibleTotal,
            previousFrameVisible : !!this.completeTarget,
            complete, gpuComplete : complete, residentBytes : this.resident, residentPeakBytes : this.peakResident,
            geometryResourceCount : this.resources.size, placementCount : this.cache.size, placementLimit : this.PlacementLimit (),
            pendingReadBytes : this.pendingReadBytes, peakWorkingBytes : this.peakWorking, peakWorkingBudgetBytes : this.peakWorkingBudget,
            peakPrefetchBytes : this.peakPrefetch, geometryReuseCount : this.sharedHits,
            geometryBudgetBytes : this.policy.geometryBytes, textureBytes : this.textureBytes, texturePeakBytes : this.peakTextures,
            textureBudgetBytes : this.policy.textureBytes,
            frameBufferBytes : this.target.width * this.target.height * 8 * new Set ([this.target, this.completeTarget, this.spareTarget].filter (Boolean)).size,
            geometryBytes : m.geometryBytes, nativePeakMemoryBytes : m.nativePeakMemoryBytes,
            nativePeakFootprintBytes : m.nativePeakFootprintBytes, parserLogicalPeakBytes : m.parserLogicalPeakBytes,
            parserWorkspaceDiskBytes : m.parserWorkspaceDiskBytes, unsupportedCount : m.unsupported.length,
            frameSerial : this.serial,
            frameElapsedMs : Math.round ((performance.now () - this.frame.startedAt) * 10) / 10,
            frameReadRequests : this.reader.readRequests - this.frame.readRequests,
            frameReadBytes : this.reader.readBytes - this.frame.readBytes,
            frameBatches : this.frame.batches,
            sourceObjectCount : m.sourceObjectCount, triangles : m.triangles, vertices : m.vertices, points : m.points,
            warnings : m.warnings || [], coverageComplete : m.coverageComplete,
            textObjects : m.textObjects, dimensionObjects : m.dimensionObjects,
            dracoDecodedPrimitiveCount : m.dracoDecodedPrimitiveCount,
            dracoPeakAllocationBytes : m.dracoPeakAllocationBytes, dracoDecoderBudgetBytes : m.dracoDecoderBudgetBytes,
            dracoWorkspaceDiskBytes : m.dracoWorkspaceDiskBytes,
            skpPeakAllocationBytes : m.skpPeakAllocationBytes, skpWorkspaceDiskBytes : m.skpWorkspaceDiskBytes,
            sketchupVersion : m.sketchupVersion,
            instanceReferenceCount : m.instanceReferenceCount, instanceLeafCount : m.instanceLeafCount,
            objectCount : m.objectCount, layerCount : m.layers.length, lineSegments : m.lineSegments,
            missingFiles : m.missingFiles || [], unsupportedObjects : m.unsupported,
            trimmedSurfaceCount : m.trimmedSurfaceCount, displayedTrimmedSurfaceCount : m.displayedTrimmedSurfaceCount,
            materialCount : m.materials.length, reader : m.reader || 'opennurbs', navigationMode : this.viewer.GetNavigationMode () };
        this.lastStats = state;
        this.stream.Notify ({ ...state, type : this.notified ? 'stream_view_progress' : 'stream_progress' });
        if (complete && !this.notified) {
            this.notified = true;
            this.stream.Notify ({ ...state, type : 'model_loaded' });
        }
    }

    async BenchmarkNavigation ()
    {
        const original = this.viewer.GetCamera ().Clone ();
        const results = [];
        for (const [yaw, pitch] of [[0.12, 0.04], [-0.12, -0.05], [0, 0]]) {
            const camera = original.Clone ();
            const offset = new THREE.Vector3 (camera.eye.x - camera.center.x, camera.eye.y - camera.center.y, camera.eye.z - camera.center.z);
            const up = new THREE.Vector3 (camera.up.x, camera.up.y, camera.up.z).normalize ();
            offset.applyAxisAngle (up, yaw);
            const right = new THREE.Vector3 ().crossVectors (offset, up).normalize ();
            offset.applyAxisAngle (right, pitch);
            up.applyAxisAngle (right, pitch);
            for (const axis of ['x', 'y', 'z']) {
                camera.eye[axis] = camera.center[axis] + offset[axis];
                camera.up[axis] = up[axis];
            }
            const start = performance.now ();
            const expectedCamera = camera.Clone ();
            this.viewer.SetCamera (camera);
            let serial = this.serial;
            while (this.active) {
                if (serial !== this.serial) {
                    // A resize may replace the requested frame without changing the camera.
                    // Actual navigation must interrupt the benchmark immediately.
                    if (!CameraIsEqual3D (expectedCamera, this.viewer.GetCamera ())) {
                        throw new Error ('Navigation benchmark interrupted');
                    }
                    serial = this.serial;
                }
                if (this.lastStats?.complete && this.lastStats.frameSerial === serial) {
                    break;
                }
                if (performance.now () - start > 180000) {
                    throw new Error ('Navigation benchmark timed out');
                }
                await Pause ();
            }
            if (!this.active || serial !== this.serial) {
                throw new Error ('Navigation benchmark interrupted');
            }
            if (!this.lastStats.gpuComplete) {
                await this.Fence ();
            }
            results.push ({ ...this.lastStats, gpuComplete : true, elapsedMs : Math.round ((performance.now () - start) * 10) / 10 });
            await new Promise ((resolve) => setTimeout (resolve, 100));
        }
        this.stream.Notify ({ type : 'navigation_benchmark_complete', name : this.manifest.name, results });
        return results;
    }
}
