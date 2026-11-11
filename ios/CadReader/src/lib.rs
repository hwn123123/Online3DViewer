//! Local DWG/DXF -> bounded geometry chunks. Source drawings are read-only.
mod text;
mod hatch;
use acadrust::entities::{EntityCommon, Insert, Spline};
use acadrust::io::dwg::dwg_reader::DwgReadOptions;
use acadrust::o3dv_guard as guard;
use acadrust::types::Transparency;
use acadrust::{CadDocument, Color, DwgReader, DxfReader, EntityType, Vector3};
use serde::Serialize;
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    ffi::{c_char, c_void, CStr, CString},
    fs::{self, File},
    io::{BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

type R<T> = Result<T, String>;
type V = [f64; 3];
type M = [f64; 16];
pub type Check = guard::Check;
pub type Event = unsafe extern "C" fn(*mut c_void, *const u8, usize);
pub type Snapshot = unsafe extern "C" fn(*mut c_void, *mut u64);
fn id() -> M {
    [
        1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
    ]
}
fn v(p: Vector3) -> V {
    [p.x, p.y, p.z]
}
fn add(a: V, b: V) -> V {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn sub(a: V, b: V) -> V {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn mul(a: V, s: f64) -> V {
    [a[0] * s, a[1] * s, a[2] * s]
}
fn dot(a: V, b: V) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn length(a: V) -> f64 {
    dot(a, a).sqrt()
}
fn unit(a: V) -> V {
    let l = length(a);
    if l > 0. {
        mul(a, 1. / l)
    } else {
        [0., 0., 1.]
    }
}
fn position(m: &M, p: V) -> V {
    [
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    ]
}
fn product(a: &M, b: &M) -> M {
    let mut c = [0.; 16];
    for col in 0..4 {
        for r in 0..4 {
            for k in 0..4 {
                c[col * 4 + r] += a[k * 4 + r] * b[col * 4 + k];
            }
        }
    }
    c
}
fn ocs(n: V) -> M {
    let n = unit(n);
    let x = unit(if n[0].abs() < 1. / 64. && n[1].abs() < 1. / 64. {
        cross([0., 1., 0.], n)
    } else {
        cross([0., 0., 1.], n)
    });
    let y = cross(n, x);
    [
        x[0], x[1], x[2], 0., y[0], y[1], y[2], 0., n[0], n[1], n[2], 0., 0., 0., 0., 1.,
    ]
}
fn translation(p: V) -> M {
    let mut m = id();
    m[12..15].copy_from_slice(&p);
    m
}
fn insert_matrix(e: &Insert, base: V, row: u16, column: u16) -> M {
    let (s, c) = e.rotation.sin_cos();
    let basis = ocs(v(e.normal));
    let r = [c, s, 0., 0., -s, c, 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.];
    let mut scale = id();
    scale[0] = e.x_scale();
    scale[5] = e.y_scale();
    scale[10] = e.z_scale();
    // INSERT is stored in OCS by DXF/DWG. Array spacing rotates with the
    // reference but does not acquire the block's nonuniform scale.
    let insert = position(&basis, v(e.insert_point));
    product(
        &translation(insert),
        &product(
            &basis,
            &product(
                &r,
                &product(
                    &translation([
                        column as f64 * e.column_spacing,
                        row as f64 * e.row_spacing,
                        0.,
                    ]),
                    &product(&scale, &translation(mul(base, -1.))),
                ),
            ),
        ),
    )
}
#[derive(Clone, Copy)]
struct Box3 {
    lo: V,
    hi: V,
}
impl Box3 {
    fn new() -> Self {
        Self {
            lo: [f64::INFINITY; 3],
            hi: [f64::NEG_INFINITY; 3],
        }
    }
    fn add(&mut self, p: V) -> R<()> {
        for k in 0..3 {
            if !p[k].is_finite() {
                return Err("CAD 包含非有限坐标。".into());
            }
            self.lo[k] = self.lo[k].min(p[k]);
            self.hi[k] = self.hi[k].max(p[k]);
        }
        Ok(())
    }
    fn json(&self) -> [f64; 6] {
        if self.lo[0].is_finite() {
            [
                self.lo[0], self.lo[1], self.lo[2], self.hi[0], self.hi[1], self.hi[2],
            ]
        } else {
            [0.; 6]
        }
    }
}
#[derive(Clone, Serialize)]
struct Layer {
    index: usize,
    id: String,
    name: String,
    visible: bool,
    #[serde(skip)]
    color: Color,
    #[serde(skip)]
    opacity: f64,
}
#[derive(Clone, PartialEq)]
struct Style {
    layer: usize,
    color: [f64; 3],
    auto_color: bool,
    opacity: f64,
    visible: bool,
    visibility_layers: Vec<usize>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Part {
    id: String,
    name: String,
    #[serde(rename = "type")]
    kind: String,
    start: usize,
    end: usize,
    line_start: usize,
    line_end: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    index: usize,
    name: String,
    #[serde(rename = "type")]
    kind: String,
    layer_index: usize,
    material_index: i32,
    color: [f64; 3],
    line_color: [f64; 3],
    cad_auto_color: bool,
    opacity: f64,
    visible: bool,
    definition_member: bool,
    available: bool,
    visibility_layers: Vec<usize>,
    origin: V,
    bounds: [f64; 6],
    url: String,
    bytes: u64,
    vertices: usize,
    triangles: usize,
    line_segments: usize,
    parts: Vec<Part>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    format: &'static str,
    reader: &'static str,
    name: String,
    source_bytes: u64,
    text_objects: u64,
    dimension_objects: u64,
    annotations: Vec<text::Annotation>,
    units: i16,
    unit_scale: f64,
    layers: Vec<Layer>,
    materials: Vec<serde_json::Value>,
    objects: Vec<Entry>,
    unsupported: Vec<serde_json::Value>,
    warnings: Vec<String>,
    missing_files: Vec<String>,
    complete: bool,
    coverage_complete: bool,
    object_count: usize,
    source_object_count: u64,
    geometry_bytes: u64,
    vertices: u64,
    triangles: u64,
    source_triangles: u64,
    line_segments: u64,
    bounds: [f64; 6],
    native_peak_footprint_bytes: u64,
    native_peak_memory_bytes: u64,
}
struct Block {
    base: V,
    entities: Vec<Arc<EntityType>>,
    external: bool,
}
struct Chunk {
    style: Option<Style>,
    origin: V,
    positions: Vec<f32>,
    normals: Vec<f32>,
    indices: Vec<u32>,
    lines: Vec<f32>,
    parts: Vec<Part>,
    bounds: Box3,
}
impl Chunk {
    fn new() -> Self {
        Self {
            style: None,
            origin: [0.; 3],
            positions: guard::capacity(24576 * 3),
            normals: guard::capacity(24576 * 3),
            indices: guard::capacity(24576),
            lines: guard::capacity(24576 * 3),
            parts: Vec::new(),
            bounds: Box3::new(),
        }
    }
    fn empty(&self) -> bool {
        self.indices.is_empty() && self.lines.is_empty()
    }
}
struct Context {
    directory: PathBuf,
    manifest: Manifest,
    blocks: BTreeMap<String, Arc<Block>>,
    layer_ids: BTreeMap<String, usize>,
    unsupported: BTreeMap<String, u64>,
    chunk: Chunk,
    bounds: Box3,
    last: Instant,
    event: Event,
    snapshot: Snapshot,
    read: Arc<AtomicU64>,
    user: *mut c_void,
    scale: f64,
    text_layout: text::Layout,
    text_styles: BTreeMap<String, text::FontStyle>,
    text_labels: BTreeMap<String, String>,
    font_substitutions: BTreeSet<String>,
    text_layout_warnings: BTreeSet<String>,
    dimension_context: CadDocument,
}
impl Context {
    fn event(&self, phase: &str) {
        let value = json!({"phase":phase,"objects":self.manifest.source_object_count,"sourceBytes":self.manifest.source_bytes,"bytesRead":self.read.load(Ordering::Relaxed),"triangles":self.manifest.triangles,"lineSegments":self.manifest.line_segments});
        let data = value.to_string();
        unsafe {
            (self.event)(self.user, data.as_ptr(), data.len());
        }
    }
    fn unsupported(&mut self, kind: &str) {
        *self.unsupported.entry(kind.into()).or_default() += 1;
    }
    fn metadata(&mut self, doc: &CadDocument) -> R<()> {
        if self.manifest.layers.is_empty() {
            self.manifest.units = doc.header.insertion_units;
            self.scale = match doc.header.insertion_units {
                1 => 0.0254,
                2 => 0.3048,
                3 => 1609.344,
                4 => 0.001,
                5 => 0.01,
                6 => 1.,
                7 => 1000.,
                8 => 0.0000000254,
                9 => 0.0000254,
                10 => 0.9144,
                11 => 1e-10,
                12 => 1e-9,
                13 => 1e-6,
                14 => 0.1,
                15 => 10.,
                16 => 100.,
                17 => 1e9,
                18 => 149597870700.,
                19 => 9.4607304725808e15,
                20 => 3.085677581491367e16,
                21 => 1200. / 3937.,
                _ => 1.,
            };
            self.manifest.unit_scale = self.scale;
        }
        for layer in doc.layers.iter() {
            if !self.layer_ids.contains_key(&layer.name) {
                let i = self.manifest.layers.len();
                self.layer_ids.insert(layer.name.clone(), i);
                self.manifest.layers.push(Layer {
                    index: i,
                    id: format!("cad-layer-{i}"),
                    name: layer.name.clone(),
                    visible: !layer.flags.off && !layer.flags.frozen,
                    color: layer.color,
                    opacity: 1. - layer.transparency.alpha() as f64 / 255.,
                });
            }
        }
        self.dimension_context.dim_styles = doc.dim_styles.clone();
        for style in doc.text_styles.iter() {
            self.text_styles
                .entry(style.name.clone())
                .or_insert(text::FontStyle {
                    font: if !style.true_type_font.is_empty() {
                        style.true_type_font.clone()
                    } else {
                        style.font_file.clone()
                    },
                    vertical: style.is_vertical,
                });
        }
        // Retain Arc references to block members, not deep copies of meshes.
        // Later DWG model-space shards can reference the same definitions.
        for block in doc.block_records.iter() {
            guard::checkpoint(0);
            if block.name.starts_with("*Model_Space")
                || block.name.starts_with("*Paper_Space")
                || self.blocks.contains_key(&block.name)
            {
                continue;
            }
            let mut entities = guard::capacity(block.entity_handles.len());
            for handle in &block.entity_handles {
                if let Some(entity) = doc.get_entity_arc(*handle) {
                    if !matches!(
                        &*entity,
                        EntityType::Block(_) | EntityType::BlockEnd(_) | EntityType::Seqend(_)
                    ) {
                        entities.push(entity);
                    }
                }
            }
            self.blocks.insert(
                block.name.clone(),
                Arc::new(Block {
                    base: v(block.base_point),
                    entities,
                    external: block.flags.is_xref || block.flags.is_external,
                }),
            );
        }
        Ok(())
    }
    fn style(&mut self, common: &EntityCommon, parent: &Style) -> Style {
        let layer = if common.layer == "0" {
            parent.layer
        } else {
            *self.layer_ids.get(&common.layer).unwrap_or(&0)
        };
        let definition = &self.manifest.layers[layer];
        let raw = match common.color {
            Color::ByBlock => None,
            Color::ByLayer => Some(definition.color),
            value => Some(value),
        };
        let color = if raw == Some(Color::Index(7)) {
            [0.18; 3]
        } else {
            raw.and_then(|c| c.rgb())
                .map(|(r, g, b)| {
                    [r, g, b].map(|x| {
                        let c = x as f64 / 255.;
                        if c <= 0.04045 {
                            c / 12.92
                        } else {
                            ((c + 0.055) / 1.055).powf(2.4)
                        }
                    })
                })
                .unwrap_or(parent.color)
        };
        let auto_color = if raw.is_none() {
            parent.auto_color
        } else {
            raw == Some(Color::Index(7))
        };
        let opacity = match common.transparency {
            Transparency::ByLayer => definition.opacity,
            Transparency::ByBlock => parent.opacity,
            Transparency::Explicit(a) => 1. - a as f64 / 255.,
        };
        let mut visibility_layers = parent.visibility_layers.clone();
        if !visibility_layers.contains(&layer) {
            visibility_layers.push(layer);
        }
        Style {
            layer,
            color,
            auto_color,
            opacity,
            visible: parent.visible && !common.invisible,
            visibility_layers,
        }
    }
    fn begin(&mut self, style: &Style, key: &str, kind: &str) -> R<()> {
        guard::checkpoint(0);
        if self.chunk.style.as_ref() != Some(style)
            || self.chunk.parts.len() >= 128
            || self.chunk.indices.len() + self.chunk.lines.len() / 3 >= 24000
        {
            self.flush()?;
            self.chunk.style = Some(style.clone());
        }
        if self.chunk.parts.last().map(|p| p.id.as_str()) != Some(key) {
            self.chunk.parts.push(Part {
                id: key.into(),
                name: self
                    .text_labels
                    .get(key)
                    .map(|t| format!("{kind} · {t}"))
                    .unwrap_or_else(|| format!("{kind} {key}")),
                kind: kind.into(),
                start: self.chunk.indices.len(),
                end: self.chunk.indices.len(),
                line_start: self.chunk.lines.len() / 3,
                line_end: self.chunk.lines.len() / 3,
            });
        }
        Ok(())
    }
    fn point(&mut self, p: V) -> R<[f32; 3]> {
        let p = mul(p, self.scale);
        if self.chunk.empty() {
            self.chunk.origin = p;
        }
        self.chunk.bounds.add(p)?;
        self.bounds.add(p)?;
        let local = sub(p, self.chunk.origin);
        let output = local.map(|x| x as f32);
        if output.iter().any(|x| !x.is_finite()) {
            return Err("CAD 坐标范围超出显示精度。".into());
        }
        Ok(output)
    }
    fn line(&mut self, a: V, b: V, m: &M, s: &Style, key: &str, kind: &str) -> R<()> {
        self.begin(s, key, kind)?;
        for p in [position(m, a), position(m, b)] {
            let p = self.point(p)?;
            self.chunk.lines.extend_from_slice(&p);
        }
        if let Some(p) = self.chunk.parts.last_mut() {
            p.line_end = self.chunk.lines.len() / 3;
        }
        self.manifest.line_segments += 1;
        Ok(())
    }
    fn triangle(&mut self, points: [V; 3], m: &M, s: &Style, key: &str, kind: &str) -> R<()> {
        self.begin(s, key, kind)?;
        let points = points.map(|p| position(m, p));
        let n = unit(cross(sub(points[1], points[0]), sub(points[2], points[0]))).map(|x| x as f32);
        for p in points {
            let p = self.point(p)?;
            self.chunk
                .indices
                .push((self.chunk.positions.len() / 3) as u32);
            self.chunk.positions.extend_from_slice(&p);
            self.chunk.normals.extend_from_slice(&n);
        }
        if let Some(p) = self.chunk.parts.last_mut() {
            p.end = self.chunk.indices.len();
        }
        self.manifest.triangles += 1;
        Ok(())
    }
    fn polygon(&mut self, points: &[V], m: &M, s: &Style, key: &str, kind: &str) -> R<()> {
        if points.len() < 3 {
            return Err("CAD 网格面少于三个顶点。".into());
        }
        if points.len() == 3 {
            return self.triangle([points[0], points[1], points[2]], m, s, key, kind);
        }
        // Project to the dominant plane; ear clipping retains concave faces.
        let mut normal = [0.; 3];
        for i in 1..points.len() - 1 {
            normal = add(
                normal,
                cross(sub(points[i], points[0]), sub(points[i + 1], points[0])),
            );
        }
        let drop = (0..3)
            .max_by(|a, b| normal[*a].abs().total_cmp(&normal[*b].abs()))
            .unwrap();
        let mut flat = guard::capacity(points.len() * 2);
        for p in points {
            for k in 0..3 {
                if k != drop {
                    flat.push(p[k]);
                }
            }
        }
        let triangles =
            earcutr::earcut(&flat, &[], 2).map_err(|_| "CAD 网格面无法三角化。".to_string())?;
        if triangles.len() != (points.len() - 2) * 3 {
            // Repeated or collinear corners need fewer nonzero triangles.
            // Verify the authored polygon's oriented area. This accepts
            // redundant corners without removing any nonzero surface area.
            let origin = points[0];
            let expected = (1..points.len() - 1)
                .map(|i| cross(sub(points[i], origin), sub(points[i + 1], origin)))
                .fold([0.; 3], add);
            let actual = triangles
                .chunks_exact(3)
                .map(|t| {
                    cross(
                        sub(points[t[1]], points[t[0]]),
                        sub(points[t[2]], points[t[0]]),
                    )
                })
                .map(|n| {
                    if dot(n, expected) < 0. {
                        mul(n, -1.)
                    } else {
                        n
                    }
                })
                .fold([0.; 3], add);
            if length(expected) > 0. && length(sub(actual, expected)) > length(expected) * 1e-8 {
                return Err("CAD 网格面的边界不能完整三角化。".into());
            }
            if triangles.is_empty() {
                // Exactly degenerate faces have no projected area; keep their
                // source corners and a deterministic fan, including winding.
                if (1..points.len() - 1)
                    .any(|i| length(cross(sub(points[i], origin), sub(points[i + 1], origin))) > 0.)
                {
                    return Err("CAD 网格面的边界自交，无法完整三角化。".into());
                }
                for i in 1..points.len() - 1 {
                    self.triangle([origin, points[i], points[i + 1]], m, s, key, kind)?;
                }
                return Ok(());
            }
        }
        for t in triangles.chunks_exact(3) {
            let mut triangle = [points[t[0]], points[t[1]], points[t[2]]];
            if dot(
                cross(sub(triangle[1], triangle[0]), sub(triangle[2], triangle[0])),
                normal,
            ) < 0.
            {
                triangle.swap(1, 2);
            }
            self.triangle(triangle, m, s, key, kind)?;
        }
        Ok(())
    }
    fn arc<F: Fn(f64) -> V>(
        &mut self,
        start: f64,
        sweep: f64,
        f: F,
        m: &M,
        s: &Style,
        key: &str,
        kind: &str,
    ) -> R<()> {
        if !start.is_finite() || !sweep.is_finite() {
            return Err("CAD 曲线参数无效。".into());
        }
        // Curves have no source triangles to reduce; sample their analytic
        // geometry at <= 0.0001 relative radial chord deviation.
        let steps = (sweep.abs() / 0.028284507).ceil().max(1.) as usize;
        if steps > 1_000_000 {
            return Err("CAD 曲线离散需要过多内存。".into());
        }
        let mut previous = f(start);
        for i in 1..=steps {
            let next = f(start + sweep * i as f64 / steps as f64);
            self.line(previous, next, m, s, key, kind)?;
            previous = next;
        }
        Ok(())
    }
    fn polyline(
        &mut self,
        points: &[(V, f64)],
        closed: bool,
        m: &M,
        s: &Style,
        key: &str,
        kind: &str,
    ) -> R<()> {
        for i in 0..points.len().saturating_sub(if closed { 0 } else { 1 }) {
            let (a, bulge) = points[i];
            let b = points[(i + 1) % points.len()].0;
            if bulge.abs() < 1e-14 {
                self.line(a, b, m, s, key, kind)?;
            } else {
                let d = sub(b, a);
                let center = add(
                    mul(add(a, b), 0.5),
                    mul([-d[1], d[0], 0.], (1. - bulge * bulge) / (4. * bulge)),
                );
                let radius = length(sub(a, center));
                let angle = (a[1] - center[1]).atan2(a[0] - center[0]);
                self.arc(
                    angle,
                    4. * bulge.atan(),
                    |t| add(center, [radius * t.cos(), radius * t.sin(), 0.]),
                    m,
                    s,
                    key,
                    kind,
                )?;
            }
        }
        Ok(())
    }
    fn spline(&mut self, e: &Spline, m: &M, s: &Style, key: &str, kind: &str) -> R<()> {
        let p = usize::try_from(e.degree).map_err(|_| "CAD 样条次数无效。")?;
        let n = e.control_points.len();
        if n <= p
            || p > 32
            || e.knots.len() != n + p + 1
            || e.knots.windows(2).any(|w| !w[0].is_finite() || w[0] > w[1])
            || (!e.weights.is_empty() && e.weights.len() != n)
        {
            self.unsupported("无法求值的样条曲线");
            return Ok(());
        }
        let evaluate = |t: f64| -> R<V> {
            let k = (p..n)
                .rev()
                .find(|&i| e.knots[i] <= t)
                .unwrap_or(p)
                .min(n - 1);
            let mut d = [[0.; 4]; 33];
            for j in 0..=p {
                let i = k - p + j;
                let w = e.weights.get(i).copied().unwrap_or(1.);
                let a = v(e.control_points[i]);
                d[j] = [a[0] * w, a[1] * w, a[2] * w, w];
            }
            for r in 1..=p {
                for j in (r..=p).rev() {
                    let i = k - p + j;
                    let den = e.knots[i + p + 1 - r] - e.knots[i];
                    let a = if den == 0. {
                        0.
                    } else {
                        (t - e.knots[i]) / den
                    };
                    for c in 0..4 {
                        d[j][c] = (1. - a) * d[j - 1][c] + a * d[j][c];
                    }
                }
            }
            if d[p][3].abs() < 1e-30 {
                return Err("CAD 有理样条权重无效。".into());
            }
            Ok([d[p][0] / d[p][3], d[p][1] / d[p][3], d[p][2] / d[p][3]])
        };
        let mut span = 0.;
        for pair in e.control_points.windows(2) {
            span += length(sub(v(pair[1]), v(pair[0])));
        }
        let tolerance = (span * 1e-5).max(1e-7 / self.scale);
        let mut stack = Vec::new();
        for i in p..n {
            let (a, b) = (e.knots[i], e.knots[i + 1]);
            if b > a {
                stack.push((a, b, evaluate(a)?, evaluate(b)?, 0u8));
            }
        }
        while let Some((a, b, pa, pb, depth)) = stack.pop() {
            guard::tick();
            let t = (a + b) * 0.5;
            let mid = evaluate(t)?;
            let q1 = evaluate(a + (b - a) * 0.25)?;
            let q3 = evaluate(a + (b - a) * 0.75)?;
            let error = length(sub(mid, mul(add(pa, pb), 0.5)))
                .max(length(sub(q1, add(mul(pa, 0.75), mul(pb, 0.25)))))
                .max(length(sub(q3, add(mul(pa, 0.25), mul(pb, 0.75)))));
            if error <= tolerance {
                self.line(pa, pb, m, s, key, kind)?;
            } else {
                if depth >= 24 {
                    return Err("CAD 样条无法在显示容差内完成离散。".into());
                }
                stack.push((t, b, mid, pb, depth + 1));
                stack.push((a, t, pa, mid, depth + 1));
            }
        }
        Ok(())
    }
    fn entity(
        &mut self,
        e: &EntityType,
        m: &M,
        parent: &Style,
        path: &str,
        stack: &mut HashSet<String>,
    ) -> R<()> {
        guard::checkpoint(0);
        self.manifest.source_object_count += 1;
        let common = e.common();
        let style = self.style(common, parent);
        let key = if path.is_empty() {
            format!("{:X}", common.handle.value())
        } else {
            format!("{path}/{:X}", common.handle.value())
        };
        let kind = e.as_entity().entity_type();
        match e {
            EntityType::Insert(insert) => {
                if stack.len() >= 64 || !stack.insert(insert.block_name.clone()) {
                    return Err("CAD 块引用循环或嵌套层数过多。".into());
                }
                let block = self
                    .blocks
                    .get(&insert.block_name)
                    .cloned()
                    .ok_or_else(|| format!("缺少 CAD 块定义：{}", insert.block_name))?;
                if block.external && block.entities.is_empty() {
                    self.unsupported("未嵌入的外部参照");
                }
                for row in 0..insert.row_count.max(1) {
                    for col in 0..if block.entities.is_empty() {
                        0
                    } else {
                        insert.column_count.max(1)
                    } {
                        guard::tick();
                        let transform = product(m, &insert_matrix(insert, block.base, row, col));
                        let child_path = format!("{key}[{row},{col}]");
                        for child in &block.entities {
                            self.entity(child, &transform, &style, &child_path, stack)?;
                        }
                        let first = insert_matrix(insert, block.base, 0, 0);
                        let delta = [
                            transform[12] - product(m, &first)[12],
                            transform[13] - product(m, &first)[13],
                            transform[14] - product(m, &first)[14],
                        ];
                        let placed = product(&translation(delta), m);
                        for (index, attribute) in insert.attributes.iter().enumerate() {
                            self.attribute(
                                attribute,
                                &placed,
                                &style,
                                &format!("{child_path}/attribute-{index}"),
                            )?;
                        }
                    }
                }
                stack.remove(&insert.block_name);
            }
            EntityType::Text(text) => self.text(text, m, &style, &key, "TEXT")?,
            EntityType::MText(text) => self.mtext(text, m, &style, &key, "MTEXT")?,
            EntityType::AttributeEntity(attribute) => self.attribute(attribute, m, &style, &key)?,
            EntityType::AttributeDefinition(definition) => {
                self.attribute_definition(definition, m, &style, &key, !path.is_empty())?
            }
            EntityType::Dimension(dimension) => {
                self.manifest.dimension_objects += 1;
                let base = dimension.base();
                if let Some(block) = self
                    .blocks
                    .get(&base.block_name)
                    .cloned()
                    .filter(|b| !b.entities.is_empty())
                {
                    let token = format!("dimension:{}", base.block_name);
                    if !stack.insert(token.clone()) || stack.len() > 64 {
                        return Err("尺寸标注块出现循环引用。".into());
                    }
                    let mut insert = Insert::new(&base.block_name, base.insertion_point);
                    insert.rotation = base.insertion_rotation;
                    insert.set_x_scale(base.insertion_scale.x);
                    insert.set_y_scale(base.insertion_scale.y);
                    insert.set_z_scale(base.insertion_scale.z);
                    let transform = product(m, &insert_matrix(&insert, block.base, 0, 0));
                    for child in &block.entities {
                        self.entity(
                            child,
                            &transform,
                            &style,
                            &format!("{key}/dimension"),
                            stack,
                        )?;
                    }
                    stack.remove(&token);
                } else {
                    let parts = self.dimension_context.explode_entity(e);
                    if parts.is_empty() {
                        self.unsupported(kind);
                    } else {
                        self.text_layout_warnings
                            .insert("部分标注没有保存图形，已按尺寸样式重建".into());
                        for part in parts {
                            self.entity(&part, m, &style, &format!("{key}/generated"), stack)?;
                        }
                    }
                }
            }
            EntityType::Line(line) => {
                self.line(v(line.start), v(line.end), m, &style, &key, kind)?;
                if line.thickness != 0. {
                    self.unsupported("曲线厚度");
                }
            }
            EntityType::Circle(circle) => {
                let transform = product(m, &ocs(v(circle.normal)));
                let center = v(circle.center);
                let radius = circle.radius;
                if radius < 0. || !radius.is_finite() {
                    return Err("CAD 圆半径无效。".into());
                }
                self.arc(
                    0.,
                    std::f64::consts::TAU,
                    |t| add(center, [radius * t.cos(), radius * t.sin(), 0.]),
                    &transform,
                    &style,
                    &key,
                    kind,
                )?;
                if circle.thickness != 0. {
                    self.unsupported("曲线厚度");
                }
            }
            EntityType::Arc(arc) => {
                let transform = product(m, &ocs(v(arc.normal)));
                let center = v(arc.center);
                let r = arc.radius;
                if r < 0. || !r.is_finite() {
                    return Err("CAD 圆弧半径无效。".into());
                }
                let sweep = arc.sweep_angle();
                self.arc(
                    arc.start_angle,
                    sweep,
                    |t| add(center, [r * t.cos(), r * t.sin(), 0.]),
                    &transform,
                    &style,
                    &key,
                    kind,
                )?;
                if arc.thickness != 0. {
                    self.unsupported("曲线厚度");
                }
            }
            EntityType::Ellipse(ellipse) => {
                let center = v(ellipse.center);
                let a = v(ellipse.major_axis);
                let b = mul(cross(unit(v(ellipse.normal)), a), ellipse.minor_axis_ratio);
                let sweep = (ellipse.end_parameter - ellipse.start_parameter)
                    .rem_euclid(std::f64::consts::TAU);
                self.arc(
                    ellipse.start_parameter,
                    if sweep == 0. {
                        std::f64::consts::TAU
                    } else {
                        sweep
                    },
                    |t| add(center, add(mul(a, t.cos()), mul(b, t.sin()))),
                    m,
                    &style,
                    &key,
                    kind,
                )?;
            }
            EntityType::LwPolyline(line) => {
                let transform = product(m, &ocs(v(line.normal)));
                let points: Vec<_> = line
                    .vertices
                    .iter()
                    .map(|p| ([p.location.x, p.location.y, line.elevation], p.bulge))
                    .collect();
                self.polyline(&points, line.is_closed, &transform, &style, &key, kind)?;
                if line.constant_width != 0.
                    || line
                        .vertices
                        .iter()
                        .any(|p| p.start_width != 0. || p.end_width != 0.)
                {
                    self.unsupported("多段线宽度");
                }
                if line.thickness != 0. {
                    self.unsupported("曲线厚度");
                }
            }
            EntityType::Polyline2D(line) => {
                let transform = product(m, &ocs(v(line.normal)));
                let points: Vec<_> = line
                    .vertices
                    .iter()
                    .map(|p| ([p.location.x, p.location.y, line.elevation], p.bulge))
                    .collect();
                self.polyline(
                    &points,
                    line.flags.is_closed(),
                    &transform,
                    &style,
                    &key,
                    kind,
                )?;
                if line.start_width != 0.
                    || line.end_width != 0.
                    || line
                        .vertices
                        .iter()
                        .any(|p| p.start_width != 0. || p.end_width != 0.)
                {
                    self.unsupported("多段线宽度");
                }
                if line.thickness != 0. {
                    self.unsupported("曲线厚度");
                }
            }
            EntityType::Polyline(line) => {
                let points: Vec<_> = line.vertices.iter().map(|p| (v(p.location), 0.)).collect();
                self.polyline(&points, line.flags.is_closed(), m, &style, &key, kind)?;
            }
            EntityType::Polyline3D(line) => {
                let points: Vec<_> = line.vertices.iter().map(|p| (v(p.position), 0.)).collect();
                self.polyline(
                    &points,
                    line.flags.to_bits() & 1 != 0,
                    m,
                    &style,
                    &key,
                    kind,
                )?;
            }
            EntityType::Spline(spline) => self.spline(spline, m, &style, &key, kind)?,
            EntityType::Hatch(fill) => {
                match hatch::generate(fill) {
                    Ok(geometry) => {
                        let transform = product(m, &ocs(v(fill.normal)));
                        let point = |p: [f64; 2]| [p[0], p[1], fill.elevation];
                        for triangle in geometry.triangles {
                            self.triangle(triangle.map(point), &transform, &style, &key, kind)?;
                        }
                        for segment in geometry.lines {
                            self.line(point(segment[0]), point(segment[1]), &transform, &style, &key, kind)?;
                        }
                    }
                    Err(reason) => self.unsupported(reason),
                }
            }
            EntityType::Leader(leader) => {
                use acadrust::entities::leader::LeaderPathType;
                guard::checkpoint(leader.vertices.len().saturating_mul(64));
                let dim = self
                    .dimension_context
                    .dim_styles
                    .get(&leader.dimension_style)
                    .cloned();
                let line_color = dim.as_ref().and_then(|s| {
                    s.dimclrd_true_color.or_else(|| match s.dimclrd {
                        0 if !matches!(leader.override_color, Color::ByLayer | Color::ByBlock) => {
                            Some(leader.override_color)
                        }
                        0 => None,
                        value => Some(Color::from_index(value)),
                    })
                });
                let leader_style = if let Some(color) = line_color {
                    let mut common = leader.common.clone();
                    common.color = color;
                    self.style(&common, parent)
                } else {
                    style.clone()
                };
                if leader.vertices.len() < 2 {
                    self.unsupported("引线顶点不足");
                } else {
                    let mut points = leader.vertices.clone();
                    if leader.arrow_enabled {
                        let custom = dim
                            .as_ref()
                            .is_some_and(|s| !s.dimldrblk.is_null() || !s.dimblk_name.is_empty());
                        if custom {
                            self.unsupported("自定义引线箭头");
                        } else {
                            let tip = v(points[0]);
                            let delta = sub(v(points[1]), tip);
                            let distance = length(delta);
                            let normal = unit(v(leader.normal));
                            let side = cross(normal, delta);
                            let size = if leader.arrow_size > 0. {
                                leader.arrow_size
                            } else {
                                dim.as_ref()
                                    .map(|s| s.dimasz * s.dimscale.abs())
                                    .filter(|s| *s > 0.)
                                    .unwrap_or(0.18)
                            };
                            if distance > 1e-12 && length(side) > 1e-12 && size.is_finite() {
                                let size = size.min(distance);
                                let base = add(tip, mul(delta, size / distance));
                                let half = mul(unit(side), size / 6.);
                                self.triangle(
                                    [tip, add(base, half), sub(base, half)],
                                    m,
                                    &leader_style,
                                    &key,
                                    kind,
                                )?;
                                points[0] = Vector3::new(base[0], base[1], base[2]);
                            } else {
                                self.unsupported("无效的引线箭头");
                            }
                        }
                    }
                    if leader.path_type == LeaderPathType::Spline && points.len() >= 3 {
                        self.text_layout_warnings
                            .insert("样条引线采用控制点重建，曲线形状可能与原图不同".into());
                        let spline =
                            Spline::from_control_points((points.len().min(4) - 1) as i32, points);
                        self.spline(&spline, m, &leader_style, &key, kind)?;
                    } else {
                        for pair in points.windows(2) {
                            guard::tick();
                            self.line(v(pair[0]), v(pair[1]), m, &leader_style, &key, kind)?;
                        }
                    }
                }
            }
            EntityType::Face3D(face) => {
                let points = [
                    v(face.first_corner),
                    v(face.second_corner),
                    v(face.third_corner),
                    v(face.fourth_corner),
                ];
                self.triangle([points[0], points[1], points[2]], m, &style, &key, kind)?;
                if points[3] != points[2] && points[3] != points[0] {
                    self.triangle([points[0], points[2], points[3]], m, &style, &key, kind)?;
                }
            }
            EntityType::Solid(solid) => {
                let transform = product(m, &ocs(v(solid.normal)));
                let points = solid.corners().into_iter().map(v).collect::<Vec<_>>();
                self.triangle(
                    [points[0], points[1], points[2]],
                    &transform,
                    &style,
                    &key,
                    kind,
                )?;
                if !solid.is_triangle() {
                    self.triangle(
                        [points[1], points[3], points[2]],
                        &transform,
                        &style,
                        &key,
                        kind,
                    )?;
                }
                if solid.thickness != 0. {
                    self.unsupported("填充面厚度");
                }
            }
            EntityType::Mesh(mesh) => {
                if mesh.subdivision_level > 0 {
                    self.unsupported("细分曲面的平滑设置");
                }
                for face in &mesh.faces {
                    let mut points = guard::capacity(face.vertices.len());
                    for &index in &face.vertices {
                        points.push(v(*mesh
                            .vertices
                            .get(index)
                            .ok_or("CAD 网格顶点索引越界。")?));
                    }
                    self.polygon(&points, m, &style, &key, kind)?;
                }
            }
            EntityType::PolyfaceMesh(mesh) => {
                for face in &mesh.faces {
                    let mut points = Vec::new();
                    for i in [face.index1, face.index2, face.index3, face.index4] {
                        if i != 0 {
                            let i = (i as i32).unsigned_abs() as usize;
                            points.push(v(mesh
                                .vertices
                                .get(i - 1)
                                .ok_or("CAD 多面网格索引越界。")?
                                .location));
                        }
                    }
                    self.polygon(&points, m, &style, &key, kind)?;
                }
            }
            EntityType::PolygonMesh(mesh) => {
                let (rows, cols) = (mesh.m_vertex_count as usize, mesh.n_vertex_count as usize);
                if rows.checked_mul(cols) != Some(mesh.vertices.len()) {
                    return Err("CAD 多边形网格尺寸无效。".into());
                }
                let closed_m = mesh.flags.bits() & 1 != 0;
                let closed_n = mesh.flags.bits() & 32 != 0;
                for i in 0..rows.saturating_sub(if closed_m { 0 } else { 1 }) {
                    for j in 0..cols.saturating_sub(if closed_n { 0 } else { 1 }) {
                        let points = [
                            (i, j),
                            ((i + 1) % rows, j),
                            ((i + 1) % rows, (j + 1) % cols),
                            (i, (j + 1) % cols),
                        ]
                        .map(|(r, c)| v(mesh.vertices[r * cols + c].location));
                        self.polygon(&points, m, &style, &key, kind)?;
                    }
                }
            }
            EntityType::Block(_)
            | EntityType::BlockEnd(_)
            | EntityType::Seqend(_)
            | EntityType::Viewport(_) => {}
            _ => self.unsupported(kind),
        }
        if self.last.elapsed() > Duration::from_millis(250) {
            self.publish(false)?;
            self.event("building");
            self.last = Instant::now();
        }
        Ok(())
    }
    fn flush(&mut self) -> R<()> {
        if self.chunk.empty() {
            self.chunk.style = None;
            self.chunk.parts.clear();
            return Ok(());
        }
        guard::checkpoint(0);
        let index = self.manifest.objects.len();
        let name = format!("object-{index:06}.bin");
        let path = self.directory.join(&name);
        let mut file = BufWriter::new(File::create(path).map_err(|e| e.to_string())?);
        let header = [
            0x3144334fu32,
            3,
            (self.chunk.positions.len() / 3) as u32,
            self.chunk.indices.len() as u32,
            (self.chunk.lines.len() / 3) as u32,
            0,
            0,
            0,
        ];
        for x in header {
            file.write_all(&x.to_le_bytes())
                .map_err(|e| e.to_string())?;
        }
        for data in [&self.chunk.positions, &self.chunk.normals] {
            for x in data {
                file.write_all(&x.to_le_bytes())
                    .map_err(|e| e.to_string())?;
            }
        }
        for x in &self.chunk.indices {
            file.write_all(&x.to_le_bytes())
                .map_err(|e| e.to_string())?;
        }
        for x in &self.chunk.lines {
            file.write_all(&x.to_le_bytes())
                .map_err(|e| e.to_string())?;
        }
        file.flush().map_err(|e| e.to_string())?;
        let bytes = 32
            + ((self.chunk.positions.len()
                + self.chunk.normals.len()
                + self.chunk.indices.len()
                + self.chunk.lines.len())
                * 4) as u64;
        let s = self.chunk.style.take().unwrap();
        let vertices = self.chunk.positions.len() / 3;
        let triangles = self.chunk.indices.len() / 3;
        let lines = self.chunk.lines.len() / 6;
        if self.manifest.objects.len() == self.manifest.objects.capacity() {
            guard::checkpoint(
                (self.manifest.objects.len() + 128).saturating_mul(std::mem::size_of::<Entry>()),
            );
            self.manifest
                .objects
                .try_reserve_exact(128)
                .map_err(|_| "CAD 缓存索引内存不足。")?;
        }
        self.manifest.objects.push(Entry {
            id: format!("cad-chunk-{index}"),
            index,
            name: format!("{} · {}", self.manifest.layers[s.layer].name, index + 1),
            kind: "CAD".into(),
            layer_index: s.layer,
            material_index: -1,
            color: s.color,
            line_color: s.color,
            cad_auto_color: s.auto_color,
            opacity: s.opacity,
            visible: s.visible,
            definition_member: false,
            available: true,
            visibility_layers: s.visibility_layers,
            origin: self.chunk.origin,
            bounds: self.chunk.bounds.json(),
            url: name,
            bytes,
            vertices,
            triangles,
            line_segments: lines,
            parts: std::mem::take(&mut self.chunk.parts),
        });
        self.manifest.geometry_bytes += bytes;
        self.manifest.vertices += vertices as u64;
        self.chunk.positions.clear();
        self.chunk.normals.clear();
        self.chunk.indices.clear();
        self.chunk.lines.clear();
        self.chunk.bounds = Box3::new();
        if index == 0 {
            self.publish(false)?;
            self.event("ready");
        }
        Ok(())
    }
    fn publish(&mut self, complete: bool) -> R<()> {
        guard::checkpoint(0);
        let mut memory = [0u64; 2];
        unsafe {
            (self.snapshot)(self.user, memory.as_mut_ptr());
        }
        self.manifest.native_peak_footprint_bytes = memory[0];
        self.manifest.native_peak_memory_bytes = memory[1];
        self.manifest.object_count = self.manifest.objects.len();
        self.manifest.bounds = self.bounds.json();
        self.manifest.complete = complete;
        self.manifest.source_triangles = self.manifest.triangles;
        self.manifest.coverage_complete = self.unsupported.is_empty();
        self.manifest.unsupported=self.unsupported.iter().map(|(kind,count)|json!({"id":format!("unsupported-{kind}"),"type":kind,"count":count,"reason":"尚未显示该类内容"})).collect();
        self.manifest.warnings = if self.unsupported.is_empty() {
            Vec::new()
        } else {
            vec![format!(
                "当前 CAD 显示尚未覆盖：{}。原图未修改，画面可能缺少这些内容。",
                self.unsupported
                    .iter()
                    .map(|(k, n)| format!("{k}（{n}）"))
                    .collect::<Vec<_>>()
                    .join("、")
            )]
        };
        if self.manifest.units == 0 && !self.manifest.warnings.iter().any(|s| s.contains("单位"))
        {
            self.manifest
                .warnings
                .push("源图未指定单位，坐标按原始数值显示。".into());
        }
        if !self.font_substitutions.is_empty() {
            self.manifest.warnings.push(format!(
                "部分文字使用系统替代字体：{}；字形和宽度可能与原字体不同。",
                self.font_substitutions
                    .iter()
                    .take(12)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("、")
            ));
        }
        self.manifest
            .warnings
            .extend(self.text_layout_warnings.iter().cloned());
        let pending = self.directory.join("manifest.pending");
        let mut file = BufWriter::new(File::create(&pending).map_err(|e| e.to_string())?);
        serde_json::to_writer(&mut file, &self.manifest).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(pending, self.directory.join("manifest.json")).map_err(|e| e.to_string())?;
        Ok(())
    }
    fn document(&mut self, outcome: acadrust::io::read::ReadOutcome) -> R<()> {
        if outcome.stats.diagnostics.iter().any(|d| {
            d.code == "objects-extract-failed"
                && (d.message.contains("budget")
                    || d.message.contains("outside the accepted range"))
        }) {
            // The section was rejected before allocation. Preserve that as a
            // resource failure rather than publishing an empty model.
            std::panic::panic_any(guard::Stop(2));
        }
        if !outcome.stats.record_stream_read || !outcome.stats.stream_completed {
            return Err("CAD 对象数据未完整读取，已停止显示。".into());
        }
        if outcome.stats.recovered_errors > 0 || outcome.stats.skipped_source_records > 0 {
            return Err(format!(
                "CAD 有 {} 条记录未能完整解析，已停止读取。",
                outcome.stats.recovered_errors + outcome.stats.skipped_source_records
            ));
        }
        self.metadata(&outcome.document)?;
        let layer = *self.layer_ids.get("0").unwrap_or(&0);
        let parent = Style {
            layer,
            color: [0.75, 0.75, 0.75],
            auto_color: true,
            opacity: 1.,
            visible: true,
            visibility_layers: Vec::new(),
        };
        let mut stack = HashSet::new();
        for entity in outcome.document.model_space_entities() {
            self.entity(entity, &id(), &parent, "", &mut stack)?;
        }
        Ok(())
    }
}
struct Input(File, Arc<AtomicU64>);
impl Read for Input {
    fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> {
        guard::checkpoint(0);
        let n = self.0.read(b)?;
        self.1.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}
impl Seek for Input {
    fn seek(&mut self, p: SeekFrom) -> std::io::Result<u64> {
        guard::checkpoint(0);
        self.0.seek(p)
    }
}
fn convert(
    source: &Path,
    directory: &Path,
    event: Event,
    snapshot: Snapshot,
    text_layout: text::Layout,
    user: *mut c_void,
    decompress: usize,
) -> R<()> {
    guard::checkpoint(0);
    fs::create_dir_all(directory).map_err(|e| e.to_string())?;
    let bytes = fs::metadata(source).map_err(|e| e.to_string())?.len();
    let manifest = Manifest {
        format: "o3dv-stream-1",
        reader: "cad-stream-4",
        text_objects: 0,
        dimension_objects: 0,
        annotations: Vec::new(),
        name: source
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        source_bytes: bytes,
        units: 0,
        unit_scale: 1.,
        layers: Vec::new(),
        materials: Vec::new(),
        objects: Vec::new(),
        unsupported: Vec::new(),
        warnings: Vec::new(),
        missing_files: Vec::new(),
        complete: false,
        coverage_complete: true,
        object_count: 0,
        source_object_count: 0,
        geometry_bytes: 0,
        vertices: 0,
        triangles: 0,
        source_triangles: 0,
        line_segments: 0,
        bounds: [0.; 6],
        native_peak_footprint_bytes: 0,
        native_peak_memory_bytes: 0,
    };
    let read = Arc::new(AtomicU64::new(0));
    let mut context = Context {
        directory: directory.into(),
        manifest,
        blocks: BTreeMap::new(),
        layer_ids: BTreeMap::new(),
        unsupported: BTreeMap::new(),
        chunk: Chunk::new(),
        bounds: Box3::new(),
        last: Instant::now(),
        event,
        snapshot,
        read: read.clone(),
        user,
        scale: 1.,
        text_layout,
        text_styles: BTreeMap::new(),
        text_labels: BTreeMap::new(),
        font_substitutions: BTreeSet::new(),
        text_layout_warnings: BTreeSet::new(),
        dimension_context: CadDocument::default(),
    };
    context.event("decoding");
    let file = Input(File::open(source).map_err(|e| e.to_string())?, read);
    if source
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("dxf"))
    {
        context.document(
            DxfReader::from_reader(file)
                .map_err(|e| e.to_string())?
                .read_with_stats()
                .map_err(|e| e.to_string())?,
        )?;
    } else {
        let options = DwgReadOptions::default()
            .with_unlimited_mesh()
            .with_max_decompressed_bytes(decompress)
            .with_deferred_solid_reference_point()
            .without_roundtrip_data();
        let mut reader = DwgReader::from_stream_with_options(file, options);
        reader
            .read_sharded(5000, |doc| {
                context
                    .document(doc)
                    .map_err(acadrust::DxfError::InvalidFormat)
            })
            .map_err(|e| e.to_string())?;
    }
    guard::checkpoint(0);
    context.flush()?;
    if context.manifest.objects.is_empty() {
        return Err("CAD 文件没有当前可显示的几何；可能仅含未适配实体或图纸布局。".into());
    }
    context.publish(true)?;
    context.event("complete");
    Ok(())
}
/// All panics remain inside Rust. C callbacks return codes, never exceptions.
#[no_mangle]
pub unsafe extern "C" fn o3dv_cad_convert(
    source: *const c_char,
    directory: *const c_char,
    check: Check,
    event: Event,
    snapshot: Snapshot,
    text_layout: text::Layout,
    user: *mut c_void,
    decompress: usize,
    error: *mut *mut c_char,
) -> i32 {
    if source.is_null() || directory.is_null() || error.is_null() {
        return 1;
    }
    *error = std::ptr::null_mut();
    static HOOK: std::sync::Once = std::sync::Once::new();
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !info.payload().is::<guard::Stop>() {
                previous(info);
            }
        }));
    });
    let scope = guard::Scope::enter(check, user);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let source = PathBuf::from(
            CStr::from_ptr(source)
                .to_str()
                .map_err(|_| "文件路径不是有效 UTF-8。")?,
        );
        let directory = PathBuf::from(
            CStr::from_ptr(directory)
                .to_str()
                .map_err(|_| "缓存路径不是有效 UTF-8。")?,
        );
        convert(
            &source,
            &directory,
            event,
            snapshot,
            text_layout,
            user,
            decompress,
        )
    }));
    let mut failure = guard::failure();
    if failure == 0 {
        if let Err(payload) = &result {
            if let Some(stop) = payload.downcast_ref::<guard::Stop>() {
                failure = stop.0;
            }
        }
    }
    drop(scope);
    let message = match result {
        Ok(Ok(())) if failure == 0 => return 0,
        Ok(Err(e)) => e,
        _ => "CAD 读取器已安全停止。".into(),
    };
    *error = CString::new(message.replace('\0', " ")).unwrap().into_raw();
    if failure != 0 {
        failure
    } else {
        1
    }
}
#[no_mangle]
pub unsafe extern "C" fn o3dv_cad_free(message: *mut c_char) {
    if !message.is_null() {
        drop(CString::from_raw(message));
    }
}
